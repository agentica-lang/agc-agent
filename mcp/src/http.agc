## MCP on streamable HTTP (revision 2025-06-18): each message is a POST to the endpoint, answered with JSON or an SSE
## stream. The session id that `initialize` gives goes on every later request, a stream cut before its answer is
## resumed with a GET and `Last-Event-ID`, and the session ends with a DELETE.
##
## Header values are sent and never shown: no error names them.

import HTTP from "std/http"
import SSE from "pkg/sse/sse"
import Rpc from "rpc"

UNAVAILABLE = "mcp.unavailable"
## The server ended the session (404): a new one starts with `initialize`.
EXPIRED = "mcp.expired"
MAX_RESUMES = 3
MAX_SESSION_ID = 1024
DELETE_MS = 2000

## A session with one server.
struct Link
  url: String
  headers: List[HTTP.Header]
  ## The largest JSON answer or SSE event.
  max_bytes: Int
  session: String = ""
  version: String = ""
end

## Sends `initialize` and `notifications/initialized`, and gives the session.
def open(
  url: String,
  headers: Map[String, String],
  max_bytes: Int,
  id: Int,
  params: JSON.Value,
  deadline: Int,
) -> Result[Link]
  given = headers.keys.sort.map { |name| HTTP.Header(name: name, value: headers[name]) }
  link = Link(url: url, headers: given, max_bytes: max_bytes)
  http = try post(link, Rpc.request(id, "initialize", params), "initialize", deadline)
  session = header(http, "mcp-session-id")
  if not session_id?(session)
    finish(http)
    return error("mcp: the server gave a bad session id", kind: UNAVAILABLE)
  end

  result = try answer(link, http, id, "initialize", deadline)
  version = Rpc.version(result)
  if version.empty?
    version = Rpc.PROTOCOL_VERSION
  end

  ready = link.with(session: session, version: version)
  finish(try post(ready, Rpc.notification("notifications/initialized"), "initialized", deadline))
  ok(ready)
end

## Sends a request and gives its answer.
def exchange(link: Link, id: Int, method: String, params: JSON.Value, deadline: Int) -> Result[JSON.Value]
  answer(link, try post(link, Rpc.request(id, method, params), method, deadline), id, method, deadline)
end

## Ends the session, if the server gave one; a failure is ignored.
def close(link: Link) -> Void
  return if link.session.empty?

  case HTTP.open("DELETE", link.url, "".bytes, link.headers + own(link, "*/*"), options(DELETE_MS))
    ok(http) -> finish(http)
    error(_) -> nil
  end
end

private

enum Read
  Answer(Rpc.Incoming)
  # The stream ended; the last event id it gave.
  Ended(String)
end

def own(link: Link, accept: String) -> List[HTTP.Header]
  headers = [HTTP.Header(name: "Accept", value: accept)]
  if not link.session.empty?
    headers = headers.push(HTTP.Header(name: "Mcp-Session-Id", value: link.session))
  end

  if not link.version.empty?
    headers = headers.push(HTTP.Header(name: "MCP-Protocol-Version", value: link.version))
  end

  headers
end

def post(link: Link, body: String, method: String, deadline: Int) -> Result[HTTP.Stream]
  headers = link.headers + own(link, "application/json, text/event-stream")
  headers = headers.push(HTTP.Header(name: "Content-Type", value: "application/json"))
  opened(link, HTTP.open("POST", link.url, body.bytes, headers, options(try left(deadline, method))), method)
end

# A GET that resumes the stream after the event `last`.
def resume(link: Link, last: String, method: String, deadline: Int) -> Result[HTTP.Stream]
  headers = link.headers + own(link, "text/event-stream")
  headers = headers.push(HTTP.Header(name: "Last-Event-ID", value: last))
  opened(link, HTTP.open("GET", link.url, "".bytes, headers, options(try left(deadline, method))), method)
end

def opened(link: Link, result: Result[HTTP.Stream], method: String) -> Result[HTTP.Stream]
  http = try down(result, method)
  status = http.status
  return ok(http) if status >= 200 and status < 300

  finish(http)
  return error("mcp: the session ended (#{method})", kind: EXPIRED) if status == 404 and not link.session.empty?

  error("mcp: the server answered HTTP #{status} (#{method})", kind: UNAVAILABLE)
end

def answer(link: Link, http: HTTP.Stream, id: Int, method: String, deadline: Int) -> Result[JSON.Value]
  kind = header(http, "content-type").split(";")[0].strip.downcase
  case kind
    "application/json" -> json_answer(link, http, id, method, deadline)
    "text/event-stream" -> events_answer(link, http, id, method, deadline)
    _ ->
      finish(http)
      error("mcp: the server answered #{method} with #{kind.inspect}", kind: UNAVAILABLE)
  end
end

def json_answer(link: Link, http: HTTP.Stream, id: Int, method: String, deadline: Int) -> Result[JSON.Value]
  pieces: List[Bytes] = []
  size = 0
  while true
    case try next_piece(http, method, deadline)
      some(piece) ->
        size = size + piece.size
        if size > link.max_bytes
          finish(http)
          return error("mcp: the answer to #{method} is over #{link.max_bytes} bytes", kind: UNAVAILABLE)
        end

        pieces = pieces.push(piece)
      none -> break
    end
  end

  finish(http)
  text = try protocol(String.from_bytes(Bytes.concat(pieces)), method)
  incoming = try protocol(Rpc.parse(text), method)
  return Rpc.outcome(incoming) if Rpc.answers?(incoming, id)

  error("mcp: the server answered #{method} with another message", kind: UNAVAILABLE)
end

# Reads events up to the answer. A stream that ends first is resumed after its last event id, if it has one.
def events_answer(link: Link, http: HTTP.Stream, id: Int, method: String, deadline: Int) -> Result[JSON.Value]
  stream = http
  last = ""
  for resumes in 0..MAX_RESUMES
    if resumes > 0
      stream = try resume(link, last, method, deadline)
    end

    read = read_events(link, stream, id, method, deadline)
    finish(stream)
    case try read
      Read.Answer(incoming) -> return Rpc.outcome(incoming)
      Read.Ended(id_seen) if not id_seen.empty? -> last = id_seen
      Read.Ended(_) -> break
    end
  end

  error("mcp: the stream of #{method} ended before its answer", kind: UNAVAILABLE)
end

# One stream up to the answer or its end: a request of the server gets its answer in a POST of its own, and a
# notification is skipped.
def read_events(link: Link, http: HTTP.Stream, id: Int, method: String, deadline: Int) -> Result[Read]
  parser = SSE.parser(link.max_bytes)
  last = ""
  while true
    piece = try next_piece(http, method, deadline)
    return ok(Read.Ended(last)) if piece.none?

    fed = try protocol(SSE.feed(parser, piece.unwrap!), method)
    parser = fed.parser
    for event in fed.events
      last = event.id
      case Rpc.parse(event.data)
        ok(incoming) if Rpc.answers?(incoming, id) -> return ok(Read.Answer(incoming))
        ok(incoming) if not incoming.method.empty? and incoming.id.some? -> try reply(link, incoming, method, deadline)
        _ -> nil
      end
    end
  end

  ok(Read.Ended(last))
end

def reply(link: Link, incoming: Rpc.Incoming, method: String, deadline: Int) -> Result[Void]
  finish(try post(link, Rpc.answer(incoming.id.unwrap!, incoming.method), method, deadline))
  ok()
end

# The next piece of the body, or none at its end, whole or cut.
def next_piece(http: HTTP.Stream, method: String, deadline: Int) -> Result[Optional[Bytes]]
  while true
    wait = try left(deadline, method)
    case http.body.recv(wait)
      ok(piece) -> return ok(some(piece))
      error(_) if http.body.closed? and http.body.empty? -> return ok(none)
      error(_) -> nil
    end
  end

  ok(none)
end

def header(http: HTTP.Stream, name: String) -> String
  values = HTTP.header_values(http.headers, name)
  return "" if values.empty?

  values[0]
end

def finish(http: HTTP.Stream) -> Void
  http.body.close
  Task.cancel(http.done)
  _ = Task.await(http.done)
end

def left(deadline: Int, method: String) -> Result[Int]
  wait = deadline - Time.monotonic_ms()
  return error("mcp: no answer to #{method} in time", kind: UNAVAILABLE) if wait <= 0

  ok(wait)
end

def options(wait: Int) -> HTTP.ClientOptions = HTTP.ClientOptions(timeout_ms: wait, idle_timeout_ms: wait)

# Visible ASCII only, as the spec asks, or none at all.
def session_id?(session: String) -> Bool
  return false if session.bytesize > MAX_SESSION_ID

  session.bytes.to_a.all? { |b| b >= 33 and b <= 126 }
end

def down[T](result: Result[T], method: String) -> Result[T]
  case result
    ok(value) -> ok(value)
    error(e) -> error("mcp: the server cannot be reached (#{method}): #{e.message}", kind: UNAVAILABLE, cause: e)
  end
end

def protocol[T](result: Result[T], method: String) -> Result[T]
  case result
    ok(value) -> ok(value)
    error(e) -> error("mcp: a bad answer to #{method}: #{e.message}", kind: UNAVAILABLE, cause: e)
  end
end
