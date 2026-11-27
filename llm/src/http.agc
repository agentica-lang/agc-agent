## The HTTP side that every provider shares: the streamed `POST`, its retry, the task that reads the SSE stream and
## folds it with the provider's wire functions, and `GET /models`.

import HTTP from "std/http"
import Client from "pkg/http-client/http_client"
import SSE from "pkg/sse/sse"
import Api from "api"
import Errors from "errors"
import Types from "types"

ERROR_BODY_BYTES = 65_536
MAX_REQUEST_BYTES = 1_048_576
KIND_REQUEST_TOO_LARGE = "llm.request_too_large"
EVENTS_CAPACITY = 64
TAIL_WAIT_MS = 250
POOL_WAIT_MS = 31_536_000_000
BODY_POLL_MS = 120_000

## How a provider talks to its API.
struct Options
  transport: Optional[Transport] = none
  ## HTTP/2 to an `https://` API, which negotiates `h2` with ALPN; a plain `http://` API keeps HTTP/1.1, whose peer
  ## would have to take the HTTP/2 connection preface with no negotiation (`FINN_HTTP2=0` keeps HTTP/1.1 to both).
  http2: Bool = true
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

## The clients of the APIs: HTTP/1.1, and HTTP/2 for an `https://` one, which picks its transport by ALPN. An origin
## whose peer does not negotiate `h2` is kept on HTTP/1.1 (`no_h2`).
struct Transport
  private

  http1: Client.Client
  http2: Client.Client
  no_h2: ATS[String, Bool]
end

## The client of a call, and the HTTP/1.1 one to fall back to when an `https://` peer refuses `h2`.
struct Clients
  main: Client.Client
  fallback: Optional[Client.Client] = none
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
  http1 = try client(pool_size, Client.Protocol.Http1)
  case client(pool_size, Client.Protocol.Http2)
    ok(http2) -> ok(Transport(http1: http1, http2: http2, no_h2: ATS.new()))
    error(e) ->
      Client.close(http1)
      error(e)
  end
end

def client(pool_size: Int, protocol: Client.Protocol) -> Result[Client.Client]
  Client.new(
    pool_size: pool_size,
    pool_timeout_ms: POOL_WAIT_MS,
    max_body_bytes: 1_048_576,
    max_retries: 0,
    max_redirects: 0,
    protocol: protocol,
  )
end

def close_transport(transport: Transport) -> Void
  Client.close(transport.http1)
  Client.close(transport.http2)
end

## The clients of `url`: HTTP/2 with an HTTP/1.1 fallback when it is on and the API is `https://` (`h2?`); else
## HTTP/1.1 alone.
def clients_for(transport: Transport, url: String, http2: Bool) -> Clients
  return Clients(main: transport.http2, fallback: some(transport.http1)) if h2?(transport, url, http2)

  Clients(main: transport.http1)
end

## A plain `http://` API keeps HTTP/1.1, since its peer would have to take the HTTP/2 connection preface with no
## negotiation, and an origin whose ALPN gave no `h2` before stays on HTTP/1.1.
def h2?(transport: Transport, url: String, http2: Bool) -> Bool
  return false if not http2 or not url.start_with?("https://")

  case transport.no_h2.get(url)
    ok(blocked) -> not blocked
    error(_) -> true
  end
end

## The origin of `url` (`scheme://host`, with an explicit port kept as written): the key of `no_h2`, so the
## path of a `base_url` never splits an origin. The scheme and the host read lowercased.
def origin_of(url: String) -> String
  at = url.index_of("://").unwrap_or(-1)
  return url if at < 0

  scheme = url.slice(0, at).downcase
  rest = url.slice(at + 3, url.length - at - 3)
  stop = first_mark(rest, ["/", "?", "#"]).unwrap_or(rest.length)
  "#{scheme}://#{authority_of(rest.slice(0, stop))}"
end

## The authority with its host lowercased and an explicit port kept as written.
def authority_of(authority: String) -> String
  if authority.start_with?("[")
    case authority.index_of("]")
      some(close) ->
        host = authority.slice(0, close + 1).downcase
        return "#{host}#{authority.slice(close + 1, authority.length - close - 1)}"
      none -> return authority.downcase
    end
  end

  case authority.index_of(":")
    some(colon) ->
      host = authority.slice(0, colon).downcase
      "#{host}#{authority.slice(colon, authority.length - colon)}"
    none -> authority.downcase
  end
end

## The first position of any of `marks` in `text`.
def first_mark(text: String, marks: List[String]) -> Optional[Int]
  found = marks.map { |mark| text.index_of(mark) }.select { |at| at.some? }.map { |at| at.unwrap! }
  found.min
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

struct Lease
  transport: Transport
  clients: Clients
  url: String
  owned: Bool = false
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
  if body.size > MAX_REQUEST_BYTES
    return error(
      "llm: the request body exceeds #{MAX_REQUEST_BYTES} bytes",
      kind: KIND_REQUEST_TOO_LARGE,
      details: {"bytes": body.size.to_s, "limit": MAX_REQUEST_BYTES.to_s},
    )
  end

  lease = try acquire(config)
  case Errors.with_retry(retry(config), -> { open(lease, config, wire, body, request.headers) })
    error(e) ->
      close_lease(lease)
      error(e)
    ok(http) ->
      events: Channel[Types.Event] = Channel.new(EVENTS_CAPACITY)
      job = Job(config: config, wire: wire, http: http, events: events)
      reader = Task.spawn do read(job, lease) end
      ok(Api.Stream(events: events, done: reader, stop: -> { stop(job, lease, reader) }))
  end
end

def stop[S](job: Job[S], lease: Lease, reader: Task[Result[Types.Response]]) -> Void
  Task.cancel(reader)
  Client.cancel(job.http)
  job.events.close
  _ = Task.await(reader)
  close_lease(lease)
end

def read[S](job: Job[S], lease: Lease) -> Result[Types.Response]
  result = read_events(job)
  job.events.close
  if result.ok?
    _ = drain(job.http, TAIL_WAIT_MS)
  end

  cancel_unread(job.http)
  close_lease(lease)
  result
end

def cancel_unread(http: Client.Stream) -> Void
  if not http.body.closed?
    Client.cancel(http)
  end
end

# A 2xx answer comes back with its body unread; any other is read whole and becomes its error.
def open[S](
  lease: Lease,
  config: Config,
  wire: Wire[S],
  body: Bytes,
  extra: Map[String, String],
) -> Result[Client.Stream]
  own = [
    HTTP.Header(name: "Content-Type", value: "application/json"),
    HTTP.Header(name: "Accept", value: "text/event-stream"),
  ]

  headers = merge_headers(own + wire.headers.call(config.api_key), extra)
  url = "#{config.base_url}#{wire.path}"
  stream = ->(client: Client.Client) { Client.stream(client, "POST", url, body: some(body), headers: headers) }
  http = try network(over_http1(lease, stream))
  return ok(http) if http.status >= 200 and http.status < 300

  read_ms = config.options.read_timeout_ms
  error_wait = 5000
  if read_ms > 0
    error_wait = [error_wait, read_ms].min.unwrap!
  end

  bytes = drain(http, error_wait)
  cancel_unread(http)
  Errors.from_status(http.status, http.headers, bytes)
end

def read_events[S](job: Job[S]) -> Result[Types.Response]
  parser = SSE.parser()
  state = job.wire.begin.call()
  while not job.wire.ended.call(state)
    case job.http.body.recv(BODY_POLL_MS)
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

      error(_) -> break if job.http.body.closed? and job.http.body.empty?
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
  lease = try acquire(config)
  result = Errors.with_retry(retry(config), -> { get_models(lease, config, wire) })
  close_lease(lease)
  response = try result
  text = try protocol_text(response.body)
  for parse in option_list(wire.models_of)
    return parse.call(text)
  end

  models(text)
end

def get_models[S](lease: Lease, config: Config, wire: Wire[S]) -> Result[Client.Response]
  url = "#{config.base_url}#{wire.models_path}"
  get = ->(client: Client.Client) { Client.get(client, url, headers: wire.headers.call(config.api_key)) }
  response = try network(over_http1(lease, get))
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

def acquire(config: Config) -> Result[Lease]
  options = config.options
  for shared in option_list(options.transport)
    return ok(leased(shared, config.base_url, options, false))
  end

  local = try network(transport())
  ok(leased(local, config.base_url, options, true))
end

def leased(transport: Transport, url: String, options: Options, owned: Bool) -> Lease
  origin = origin_of(url)
  found = clients_for(transport, origin, options.http2)
  clients = Clients(main: timed(found.main, options), fallback: found.fallback.map { |client| timed(client, options) })
  Lease(transport: transport, clients: clients, url: origin, owned: owned)
end

## The call, and over HTTP/1.1 when an `https://` peer refused the `h2` of ALPN: it then keeps HTTP/1.1.
def over_http1[T](lease: Lease, call: Fn[Client.Client, Result[T]]) -> Result[T]
  origin = origin_of(lease.url)
  case lease.transport.no_h2.get(origin)
    ok(true) if lease.clients.fallback.some? -> return call.call(lease.clients.fallback.unwrap!)
    _ -> nil
  end

  result = call.call(lease.clients.main)
  case result
    error(e) if e.is_a?("http_client.http2.alpn") and lease.clients.fallback.some? ->
      lease.transport.no_h2.put(origin, true)
      call.call(lease.clients.fallback.unwrap!)
    _ -> result
  end
end

def close_lease(lease: Lease) -> Void
  if lease.owned
    close_transport(lease.transport)
  end
end

def timed(client: Client.Client, options: Options) -> Client.Client
  client.with(
    timeout_ms: options.timeout_ms,
    read_timeout_ms: options.timeout_ms,
    body_idle_ms: some(options.read_timeout_ms),
  )
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
