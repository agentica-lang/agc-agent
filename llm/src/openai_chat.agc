## The `openai_chat` provider: `POST BASE/chat/completions` with `stream: true`, as llama.cpp's `llama-server`,
## Fireworks, OpenRouter and OpenAI serve it.

import HTTP from "std/http"
import SSE from "pkg/sse/sse"
import Errors from "errors"
import Wire from "openai_chat_wire"
import Api from "api"
import Types from "types"

ERROR_BODY_BYTES = 65_536
EVENTS_CAPACITY = 64

## How the provider talks to the API.
struct OpenAIChatOptions
  ## The longest wait for the API: the connect, the head, and each piece of the stream.
  timeout_ms: Int = 120_000
  ## Tries of a request that fails before its stream starts (429, 5xx, network), with waits from `retry_base_ms`,
  ## doubled each time, at most `retry_max_ms`, or what `Retry-After` asks when it asks for longer.
  tries: Int = 3
  retry_base_ms: Int = 500
  retry_max_ms: Int = 30_000
  ## The longest `Retry-After` that is waited for; a longer one gives its error at once.
  retry_after_max_ms: Int = 120_000
end

## The provider for an API at `base_url` (such as `http://127.0.0.1:8080/v1`). An empty `api_key` sends no
## `Authorization` header.
def openai_chat(
  base_url: String,
  api_key: String = "",
  options: OpenAIChatOptions = OpenAIChatOptions(),
) -> Api.Provider
  config = Config(base_url: base_url.strip, api_key: api_key, options: options)
  Api.Provider(
    name: "openai_chat",
    stream: ->(request) { start_stream(config, request) },
    models: -> { list_models(config) },
  )
end

private

struct Config
  base_url: String
  api_key: String
  options: OpenAIChatOptions
end

struct Job
  config: Config
  http: HTTP.Stream
  events: Channel[Types.Event]
end

def start_stream(config: Config, request: Types.Request) -> Result[Api.Stream]
  body = (try Wire.request_body(request)).bytes
  http = try Errors.with_retry(retry(config), -> { open(config, body, request.headers) })
  events: Channel[Types.Event] = Channel.new(EVENTS_CAPACITY)
  reader = Task.spawn(&read, Job(config: config, http: http, events: events))
  ok(Api.Stream(events: events, done: reader, stop: -> { stop(http, reader, events) }))
end

def stop(http: HTTP.Stream, reader: Task[Result[Types.Response]], events: Channel[Types.Event]) -> Void
  Task.cancel(reader)
  end_http(http)
  events.close
end

# The connection task is the caller's: it is stopped and waited for, so no task outlives the call.
def end_http(http: HTTP.Stream) -> Void
  Task.cancel(http.done)
  _ = Task.await(http.done)
end

# A 2xx answer comes back with its body unread; any other is read whole and becomes its error.
def open(config: Config, body: Bytes, extra: Map[String, String]) -> Result[HTTP.Stream]
  own = [
    HTTP.Header(name: "Content-Type", value: "application/json"),
    HTTP.Header(name: "Accept", value: "text/event-stream"),
  ]

  headers = merge_headers(own + auth(config), extra)
  url = "#{config.base_url}/chat/completions"
  http = try network(HTTP.open("POST", url, body, headers, client_options(config)))
  return ok(http) if http.status >= 200 and http.status < 300

  Errors.from_status(http.status, http.headers, drain(http))
end

def read(job: Job) -> Result[Types.Response]
  result = read_events(job)
  job.events.close
  end_http(job.http)
  result
end

def read_events(job: Job) -> Result[Types.Response]
  parser = SSE.parser()
  turn = Wire.new_turn()
  while not turn.done
    case job.http.body.recv(job.config.options.timeout_ms)
      ok(piece) ->
        fed = try sse_error(SSE.feed(parser, piece))
        parser = fed.parser
        for event in fed.events
          step = try Wire.take(turn, event.data)
          turn = step.turn
          for e in step.events
            try send(job, e)
          end
        end

      error(_) -> break if job.http.body.closed? and job.http.body.empty?
    end
  end

  if not turn.done
    try cut(Task.await(job.http.done))
  end

  response = try Wire.finish(turn)
  try send(job, Types.Event.Stop(response.stop_reason))
  ok(response)
end

def send(job: Job, event: Types.Event) -> Result[Void]
  case job.events.send(event, job.config.options.timeout_ms)
    ok(_) -> ok()
    error(e) ->
      message = "llm: the events were not read for #{job.config.options.timeout_ms} ms"
      error(message, kind: "llm.slow_reader", cause: e)
  end
end

def list_models(config: Config) -> Result[List[Types.Model]]
  response = try Errors.with_retry(retry(config), -> { get_models(config) })
  Wire.models(try protocol_text(response.body))
end

def get_models(config: Config) -> Result[HTTP.Response]
  client = try network(HTTP.client(client_options(config)))
  result = network(HTTP.request(client, "GET", "#{config.base_url}/models", "".bytes, auth(config)))
  HTTP.close_client(client)
  response = try result
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

# A header of the caller replaces the provider's header of the same name, without regard to case.
def merge_headers(own: List[HTTP.Header], extra: Map[String, String]) -> List[HTTP.Header]
  by_name: Map[String, HTTP.Header] = {}
  for header in own
    by_name = by_name.put(header.name.downcase, header)
  end

  for name in extra.keys
    by_name = by_name.put(name.downcase, HTTP.Header(name: name, value: extra[name]))
  end

  by_name.values
end

def auth(config: Config) -> List[HTTP.Header]
  return [] if config.api_key.empty?

  [HTTP.Header(name: "Authorization", value: "Bearer #{config.api_key}")]
end

def client_options(config: Config) -> HTTP.ClientOptions
  HTTP.ClientOptions(timeout_ms: config.options.timeout_ms, idle_timeout_ms: config.options.timeout_ms)
end

# The body of an error answer, up to a limit: only its message is used.
def drain(http: HTTP.Stream) -> Bytes
  pieces: List[Bytes] = []
  size = 0
  while size < ERROR_BODY_BYTES
    case http.body.recv(5000)
      ok(piece) ->
        pieces = pieces.push(piece)
        size = size + piece.size
      error(_) -> break
    end
  end

  http.body.close
  _ = Task.await(http.done)
  Bytes.concat(pieces)
end

def network[T](result: Result[T]) -> Result[T]
  case result
    ok(value) -> ok(value)
    error(e) -> error("llm: #{e.message}", kind: "llm.network", cause: e)
  end
end

def cut(result: Result[Void]) -> Result[Void]
  case result
    ok(_) -> ok()
    error(e) -> error("llm: the stream was cut: #{e.message}", kind: "llm.protocol", cause: e)
  end
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
