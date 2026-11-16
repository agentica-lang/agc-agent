## The HTTP calls of the protocol to a server, with its token. A failed one is an error whose `kind` is the server's
## and whose `code` is the HTTP status.

import HTTP from "std/http"
import Protocol from "pkg/protocol/protocol"

CALL_TIMEOUT_MS = 10_000
PROBE_TIMEOUT_MS = 2_000
# The protocol has no heartbeat: a session can be quiet for as long as the model thinks.
EVENTS_TIMEOUT_MS = 86_400_000
ERROR_BODY_BYTES = 65_536
KIND_UNREACHABLE = "tui.unreachable"

struct Server
  url: String
  token: String
end

def health(server: Server) -> Result[Protocol.Health]
  Protocol.decode_health(try call_within(server, "GET", Protocol.HEALTH_PATH, "", PROBE_TIMEOUT_MS))
end

def create_session(server: Server, request: Protocol.NewSession) -> Result[String]
  body = try call(server, "POST", Protocol.SESSIONS_PATH, Protocol.encode_new_session(request))
  created = try Protocol.decode_session_created(body)
  ok(created.id)
end

def session(server: Server, id: String) -> Result[Protocol.Session]
  Protocol.decode_session(try call(server, "GET", Protocol.session_path(id), ""))
end

def send_message(server: Server, id: String, text: String) -> Result[Void]
  _ = try call(
    server,
    "POST",
    Protocol.messages_path(id),
    Protocol.encode_send_message(Protocol.SendMessage(text: text)),
  )

  ok()
end

def stop(server: Server, id: String) -> Result[Void]
  _ = try call(server, "POST", Protocol.stop_path(id), "")
  ok()
end

## The event stream of a session from the event after `last_event_id`.
def open_events(server: Server, id: String, last_event_id: Int) -> Result[HTTP.Stream]
  headers = (
    headers(server, "")
      .push(HTTP.Header(name: "Accept", value: "text/event-stream"))
      .push(HTTP.Header(name: Protocol.LAST_EVENT_ID_HEADER, value: Protocol.format_event_id(last_event_id)))
  )

  options = HTTP.ClientOptions(timeout_ms: EVENTS_TIMEOUT_MS, idle_timeout_ms: EVENTS_TIMEOUT_MS)
  http = try network(HTTP.open("GET", "#{server.url}#{Protocol.events_path(id)}", "".bytes, headers, options))
  return ok(http) if http.status >= 200 and http.status < 300

  rejected: Result[HTTP.Stream] = failure(http.status, http.headers, drain(http))
  Task.cancel(http.done)
  _ = Task.await(http.done)
  rejected
end

private

def call(server: Server, method: String, path: String, body: String) -> Result[String]
  call_within(server, method, path, body, CALL_TIMEOUT_MS)
end

def call_within(server: Server, method: String, path: String, body: String, timeout_ms: Int) -> Result[String]
  client = try network(HTTP.client(HTTP.ClientOptions(timeout_ms: timeout_ms)))
  result = HTTP.request(client, method, "#{server.url}#{path}", body.bytes, headers(server, body))
  HTTP.close_client(client)
  response = try network(result)
  return network(HTTP.text(response.body, response.headers)) if response.status >= 200 and response.status < 300

  failure(response.status, response.headers, response.body)
end

def headers(server: Server, body: String) -> List[HTTP.Header]
  auth = HTTP.Header(name: "Authorization", value: "Bearer #{server.token}")
  return [auth] if body == ""

  [auth, HTTP.Header(name: "Content-Type", value: "application/json")]
end

def network[T](result: Result[T]) -> Result[T]
  case result
    ok(value) -> ok(value)
    error(e) -> error("cannot reach the server: #{e.message}", kind: KIND_UNREACHABLE, cause: e)
  end
end

def failure[T](status: Int, headers: List[HTTP.Header], body: Bytes) -> Result[T]
  text = HTTP.text(body, headers).unwrap_or("")
  case Protocol.decode_failure(text)
    ok(wire) -> error(wire.message, kind: wire.kind, code: status)
    error(_) -> error("the server answered HTTP #{status}", kind: "tui.http", code: status)
  end
end

def drain(http: HTTP.Stream) -> Bytes
  body = "".bytes
  while body.size < ERROR_BODY_BYTES
    case http.body.recv(CALL_TIMEOUT_MS)
      ok(piece) -> body = Bytes.concat([body, piece])
      error(_) -> break
    end
  end

  body
end
