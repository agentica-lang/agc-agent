## The HTTP side that every provider shares: the streamed `POST`, its retry, the task that reads the SSE stream and
## folds it with the provider's wire functions, and `GET /models`.

import HTTP from "std/http"
import Client from "pkg/http-client/http_client"
import SSE from "pkg/sse/sse"
import Api from "api"
import Errors from "errors"
import Types from "types"

ERROR_BODY_BYTES = 65_536
EVENTS_CAPACITY = 64
TAIL_WAIT_MS = 250
UNBOUNDED_IDLE_MS = 31_536_000_000

## How a provider talks to its API.
struct Options
  transport: Optional[Transport] = none
  ## The longest wait for the API to answer: the connect and the head (and a whole call, such as `GET /models`).
  timeout_ms: Int = 120_000
  ## The longest wait for the next piece of a stream: a stream silent for longer fails.
  read_timeout_ms: Int = 120_000
  ## Tries of a request that fails before its stream starts (429, 5xx, network), with waits from `retry_base_ms`,
  ## doubled each time, at most `retry_max_ms`, or what `Retry-After` asks when it asks for longer.
  tries: Int = 3
  retry_base_ms: Int = 500
  retry_max_ms: Int = 30_000
  ## The longest `Retry-After` that is waited for; a longer one gives its error at once.
  retry_after_max_ms: Int = 120_000
end

struct Transport
  private

  client: Client.Client
end

## Where an API is and how to reach it.
struct Config
  base_url: String
  api_key: String
  options: Options
end

## The wire format of a provider, pure: the request body, and the fold of the stream's `data` into a state `S` and
## events.
struct Wire[S]
  path: String
  ## The provider's own headers (its auth, a version) for an API key.
  headers: Fn[String, List[HTTP.Header]]
  body: Fn[Types.Request, Result[String]]
  begin: Fn[S]
  take: Fn[S, String, Result[Types.Fold[S]]]
  ## The stream said it ended.
  ended: Fn[S, Bool]
  finish: Fn[S, Result[Types.Response]]
  models_path: String = "/models"
  ## The models of a `GET` of `models_path`, when the API lists them in another shape than `{"data": [...]}`.
  models_of: Optional[Fn[String, Result[List[Types.Model]]]] = none
end

def transport(pool_size: Int = 10) -> Result[Transport]
  ok(
    Transport(
      client: try Client.new(
        pool_size: pool_size,
        pool_timeout_ms: UNBOUNDED_IDLE_MS,
        max_body_bytes: 1_048_576,
        max_retries: 0,
        max_redirects: 0,
      ),
    ),
  )
end

def close_transport(transport: Transport) -> Void
  Client.close(transport.client)
end

## `Authorization: Bearer KEY`, or nothing for an empty key.
def bearer(api_key: String) -> List[HTTP.Header]
  return [] if api_key.empty?

  [HTTP.Header(name: "Authorization", value: "Bearer #{api_key}")]
end

## A provider on `wire` at the API of `config`.
def provider[S](name: String, config: Config, wire: Wire[S]) -> Api.Provider
  Api.Provider(
    name: name,
    stream: ->(request) { start_stream(config, wire, request) },
    models: -> { list_models(config, wire) },
  )
end

private

struct Job[S]
  config: Config
  wire: Wire[S]
  http: Client.Stream
  events: Channel[Types.Event]
end

struct Exchange
  http: Client.Stream
  task: Task[Result[Void]]
  released: Channel[Bool]
end

struct ModelList
  data: List[WireModel]
end

struct WireModel
  id: String
  context_length: Optional[Int]
  max_input_tokens: Optional[Int]
  meta: Optional[ModelMeta]
end

struct ModelMeta
  n_ctx: Optional[Int]
end

def start_stream[S](config: Config, wire: Wire[S], request: Types.Request) -> Result[Api.Stream]
  body = (try wire.body.call(request)).bytes
  events: Channel[Types.Event] = Channel.new(EVENTS_CAPACITY)
  ready: Channel[Result[Void]] = Channel.new(1)
  reader = Task.spawn do run_stream(config, wire, body, request.headers, events, ready) end
  Task.monitor(reader, ready) do |_down| error("llm: the stream task stopped before opening", kind: "llm.network") end
  opened = await_ready(ready)
  ready.close
  try opened

  ok(Api.Stream(events: events, done: reader, stop: -> { stop(reader, events) }))
end

def await_ready[T](ready: Channel[Result[T]]) -> Result[T]
  while true
    case ready.recv(5000)
      ok(opened) -> return opened
      error(e) -> return error(e) if ready.closed?
    end
  end

  error("llm: the stream task stopped before opening", kind: "llm.network")
end

def stop(reader: Task[Result[Types.Response]], events: Channel[Types.Event]) -> Void
  Task.cancel(reader)
  events.close
  _ = Task.await(reader)
end

def run_stream[S](
  config: Config,
  wire: Wire[S],
  body: Bytes,
  headers: Map[String, String],
  events: Channel[Types.Event],
  ready: Channel[Result[Void]],
) -> Result[Types.Response]
  result = with_client(config, ->(client) { stream_on(client, config, wire, body, headers, events, ready) })
  case result
    error(e) -> _ = ready.send(error(e), 0)
    ok(_) -> nil
  end

  events.close
  result
end

def stream_on[S](
  client: Client.Client,
  config: Config,
  wire: Wire[S],
  body: Bytes,
  headers: Map[String, String],
  events: Channel[Types.Event],
  ready: Channel[Result[Void]],
) -> Result[Types.Response]
  attempt = try Errors.with_retry(retry(config), -> { open(client, config, wire, body, headers) })
  try ready.send(ok(), 0)
  result = read_events(Job(config: config, wire: wire, http: attempt.http, events: events))
  events.close
  if result.ok?
    _ = drain(attempt.http, TAIL_WAIT_MS)
  end

  release(attempt)
  result
end

def start_exchange(client: Client.Client, url: String, body: Bytes, headers: List[HTTP.Header]) -> Result[Exchange]
  opened: Channel[Result[Client.Stream]] = Channel.new(1)
  released: Channel[Bool] = Channel.new(1)
  exchange = Task.spawn do exchange_on(client, url, body, headers, opened, released) end
  Task.monitor(exchange, opened) do |_down| error("llm: the HTTP task stopped before opening", kind: "llm.network") end
  result = await_ready(opened)
  opened.close
  case result
    ok(http) -> ok(Exchange(http: http, task: exchange, released: released))
    error(e) ->
      released.close
      _ = Task.await(exchange)
      error(e)
  end
end

def exchange_on(
  client: Client.Client,
  url: String,
  body: Bytes,
  headers: List[HTTP.Header],
  opened: Channel[Result[Client.Stream]],
  released: Channel[Bool],
) -> Result[Void]
  result = network(Client.stream(client, "POST", url, body: some(body), headers: headers))
  try opened.send(result, 0)
  if result.ok?
    while not released.closed?
      _ = released.recv(5000)
    end
  end

  ok()
end

def release(attempt: Exchange) -> Void
  if not attempt.http.body.closed?
    Task.cancel(attempt.task)
  end

  attempt.http.body.close
  attempt.released.close
  _ = Task.await(attempt.task)
end

# A 2xx answer comes back with its body unread; any other is read whole and becomes its error.
def open[S](
  client: Client.Client,
  config: Config,
  wire: Wire[S],
  body: Bytes,
  extra: Map[String, String],
) -> Result[Exchange]
  own = [
    HTTP.Header(name: "Content-Type", value: "application/json"),
    HTTP.Header(name: "Accept", value: "text/event-stream"),
  ]

  headers = merge_headers(own + wire.headers.call(config.api_key), extra)
  url = "#{config.base_url}#{wire.path}"
  attempt = try start_exchange(client, url, body, headers)
  http = attempt.http
  return ok(attempt) if http.status >= 200 and http.status < 300

  read_ms = config.options.read_timeout_ms
  error_wait = 5000
  if read_ms > 0
    error_wait = [error_wait, read_ms].min.unwrap!
  end

  bytes = drain(http, error_wait)
  release(attempt)
  Errors.from_status(http.status, http.headers, bytes)
end

def read_events[S](job: Job[S]) -> Result[Types.Response]
  parser = SSE.parser()
  state = job.wire.begin.call()
  read_ms = job.config.options.read_timeout_ms
  wait_ms = read_ms
  if read_ms == 0
    wait_ms = UNBOUNDED_IDLE_MS
  end

  while not job.wire.ended.call(state)
    case job.http.body.recv(wait_ms)
      ok(read) ->
        piece = try cut(read, job.config.options.read_timeout_ms)
        fed = try sse_error(SSE.feed(parser, piece))
        parser = fed.parser
        for event in fed.events
          fold = try job.wire.take.call(state, event.data)
          state = fold.state
          for e in fold.events
            try send(job, e)
          end
        end

      error(e) ->
        break if job.http.body.closed? and job.http.body.empty?

        return silent(read_ms, e) if read_ms != 0
    end
  end

  response = try job.wire.finish.call(state)
  try send(job, Types.Event.Stop(response.stop_reason))
  ok(response)
end

def send[S](job: Job[S], event: Types.Event) -> Result[Void]
  case job.events.send(event, job.config.options.timeout_ms)
    ok(_) -> ok()
    error(e) ->
      message = "llm: the events were not read for #{job.config.options.timeout_ms} ms"
      error(message, kind: "llm.slow_reader", cause: e)
  end
end

def list_models[S](config: Config, wire: Wire[S]) -> Result[List[Types.Model]]
  response = try with_client(
    config,
    ->(client) { Errors.with_retry(retry(config), -> { get_models(client, config, wire) }) },
  )

  text = try protocol_text(response.body)
  for parse in option_list(wire.models_of)
    return parse.call(text)
  end

  models(text)
end

def get_models[S](client: Client.Client, config: Config, wire: Wire[S]) -> Result[Client.Response]
  url = "#{config.base_url}#{wire.models_path}"
  response = try network(Client.get(client, url, headers: wire.headers.call(config.api_key)))
  return ok(response) if response.status >= 200 and response.status < 300

  Errors.from_status(response.status, response.headers, response.body)
end

def retry(config: Config) -> Errors.Retry
  options = config.options
  Errors.Retry(
    tries: options.tries,
    base_ms: options.retry_base_ms,
    max_ms: options.retry_max_ms,
    retry_after_max_ms: options.retry_after_max_ms,
  )
end

# A header of the caller replaces the provider's header of the same name, without regard to case; `anthropic-beta`
# values add up, joined by commas, so a caller's beta keeps the provider's.
def merge_headers(own: List[HTTP.Header], extra: Map[String, String]) -> List[HTTP.Header]
  by_name: Map[String, HTTP.Header] = {}
  for header in own
    by_name = by_name.put(header.name.downcase, header)
  end

  for name in extra.keys
    value = extra[name]
    key = name.downcase
    case by_name.get(key)
      some(old) if key == "anthropic-beta" -> value = "#{old.value},#{value}"
      _ -> nil
    end

    by_name = by_name.put(key, HTTP.Header(name: name, value: value))
  end

  by_name.values
end

def with_client[T](config: Config, call: Fn[Client.Client, Result[T]]) -> Result[T]
  for shared in option_list(config.options.transport)
    return call.call(timed(shared.client, config))
  end

  local = try network(transport())
  result = call.call(timed(local.client, config))
  close_transport(local)
  result
end

def timed(client: Client.Client, config: Config) -> Client.Client
  timeout = config.options.timeout_ms
  read_timeout = [timeout, config.options.read_timeout_ms].max.unwrap!
  if config.options.read_timeout_ms == 0
    read_timeout = UNBOUNDED_IDLE_MS
  end

  client.with(timeout_ms: timeout, read_timeout_ms: read_timeout)
end

# The body of an error answer, up to a limit: only its message is used.
def drain(http: Client.Stream, wait_ms: Int) -> Bytes
  pieces: List[Bytes] = []
  size = 0
  deadline = Time.monotonic_ms() + wait_ms
  while size < ERROR_BODY_BYTES
    left = deadline - Time.monotonic_ms()
    break if left <= 0

    case http.body.recv(left)
      ok(ok(piece)) ->
        pieces = pieces.push(piece)
        size = size + piece.size
      ok(error(_)) -> break
      error(_) -> break
    end
  end

  Bytes.concat(pieces).take(ERROR_BODY_BYTES)
end

def network[T](result: Result[T]) -> Result[T]
  case result
    ok(value) -> ok(value)
    error(e) -> error("llm: #{e.message}", kind: "llm.network", cause: e)
  end
end

# A stream that the API left silent for `read_ms` is a network failure; any other cut is the API's.
def cut(result: Result[Bytes], read_ms: Int) -> Result[Bytes]
  case result
    ok(piece) -> ok(piece)
    error(e) if e.kind == "http_client.timeout.read" -> silent(read_ms, e)
    error(e) -> error("llm: the stream was cut: #{e.message}", kind: "llm.protocol", cause: e)
  end
end

def silent[T](read_ms: Int, cause: Error) -> Result[T]
  error("llm: the API sent nothing for #{read_ms} ms", kind: "llm.network", cause: cause)
end

def sse_error[T](result: Result[T]) -> Result[T]
  case result
    ok(value) -> ok(value)
    error(e) -> error("llm: bad SSE from the API: #{e.message}", kind: "llm.protocol", cause: e)
  end
end

def protocol_text(body: Bytes) -> Result[String]
  case String.from_bytes(body)
    ok(text) -> ok(text)
    error(e) -> error("llm: the API answer is not UTF-8", kind: "llm.protocol", cause: e)
  end
end

# The models of `GET /models`, with the context of llama.cpp (`meta.n_ctx`), `context_length` or Anthropic's
# `max_input_tokens` when given.
def models(body: String) -> Result[List[Types.Model]]
  list = try decoded(JSON.decode(body, ModelList))
  ok(list.data.map { |m| Types.Model(id: m.id, context: context_of(m)) })
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end

def decoded[T](result: Result[T]) -> Result[T]
  case result
    ok(value) -> ok(value)
    error(e) -> error("llm: bad JSON from the API: #{e.message}", kind: "llm.protocol", cause: e)
  end
end

def context_of(model: WireModel) -> Optional[Int]
  for n in [model.context_length, model.max_input_tokens]
    return n if n.some?
  end

  model.meta.map { |meta| meta.n_ctx }.unwrap_or(none)
end
