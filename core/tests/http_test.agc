import HTTP from "std/http"
import Testing from "pkg/bond/testing"
import Protocol from "pkg/protocol/protocol"
import SSE from "pkg/sse/sse"
import Server from "../src/http/server"
import H from "support/harness"

def header(token: String, host: String = "127.0.0.1:1") -> List[HTTP.Header]
  [HTTP.Header(name: "Host", value: host), HTTP.Header(name: "Authorization", value: "Bearer #{token}")]
end

def failure_kind(response: HTTP.Response) -> Result[String]
  ok((try Protocol.decode_failure(try text(response))).kind)
end

def text(response: HTTP.Response) -> Result[String] = String.from_bytes(response.body)

# The checks in front of every route, and the answers for a path or a method that has no route, with no socket.
def test_the_app_checks_every_request_and_answers_the_protocol_failures() -> Result[Void]
  H.using(H.Setup(replies: [])) do |h|
    app = Server.app(h.token, h.server.sessions, h.server.control)
    health = Protocol.HEALTH_PATH
    good = header(h.token)
    ok_health = Testing.request(app, "GET", health, good)
    try Test.eq(ok_health.status, 200)
    try Test.eq(HTTP.header_values(ok_health.headers, "content-type"), ["application/json"])
    try Test.eq(Testing.request(app, "GET", health, [good[0]]).status, 401)
    try Test.eq(failure_kind(Testing.request(app, "GET", health, header("nope"))), ok(Protocol.KIND_UNAUTHORIZED))
    foreign = good.push(HTTP.Header(name: "Origin", value: "http://evil.example"))
    try Test.eq(failure_kind(Testing.request(app, "GET", health, foreign)), ok(Protocol.KIND_FORBIDDEN))
    own = good.push(HTTP.Header(name: "Origin", value: "http://127.0.0.1:1"))
    try Test.eq(Testing.request(app, "GET", health, own).status, 200)
    try Test.eq(Testing.request(app, "GET", health, header(h.token, "evil.example:1")).status, 403)
    try Test.eq(Testing.request(app, "GET", health, header(h.token, "localhost")).status, 200)

    missing = Testing.request(app, "GET", "/v2/sessions", good)
    try Test.eq(missing.status, 404)
    try Test.eq(failure_kind(missing), ok("not_found"))
    wrong_method = Testing.request(app, "POST", health, good)
    try Test.eq(wrong_method.status, 404)
    try Test.eq(failure_kind(wrong_method), ok("not_found"))
    try Test.eq(Testing.request(app, "GET", "#{Protocol.SESSIONS_PATH}/nope", good).status, 404)
    try Test.eq(
      failure_kind(Testing.request(app, "GET", "#{Protocol.SESSIONS_PATH}/nope", good)),
      ok(Protocol.KIND_SESSION_NOT_FOUND),
    )

    bad_body = Testing.request(app, "POST", Protocol.SESSIONS_PATH, good, "{")
    try Test.eq(bad_body.status, 400)
    try Test.eq(failure_kind(bad_body), ok(Protocol.KIND_INVALID))
    Test.eq(Testing.request(app, "GET", Protocol.SESSIONS_PATH, good).status, 200)
  end
end

# `GET /v1/server` counts the sessions; `POST /v1/server/stop` only asks: the task that owns the server stops it.
def test_the_server_status_and_its_stop_request() -> Result[Void]
  H.using(H.Setup(replies: [])) do |h|
    app = Server.app(h.token, h.server.sessions, h.server.control)
    good = header(h.token)
    _ = try H.new_session(h)
    status = Testing.request(app, "GET", Protocol.SERVER_PATH, good)
    try Test.eq(status.status, 200)
    decoded = try Protocol.decode_server_status(try text(status))
    try Test.eq([decoded.pid, decoded.sessions, decoded.running_turns], [System.pid, 1, 0])
    try Test.eq(Testing.request(app, "GET", Protocol.SERVER_PATH, [good[0]]).status, 401)
    try Test.eq(Testing.request(app, "POST", Protocol.SERVER_STOP_PATH, [good[0]], "{\"now\": true}").status, 401)
    try Test.error?(h.server.control.stopping.recv(0))
    try Test.eq(Testing.request(app, "POST", Protocol.SERVER_STOP_PATH, good, "{").status, 400)
    stop = Testing.request(app, "POST", Protocol.SERVER_STOP_PATH, good, "{\"now\": true}")
    try Test.eq(stop.status, 200)
    Test.eq(h.server.control.stopping.recv(0), ok(true))
  end
end

# Bond reads the body after the filters: a request without the token that says it has a body, and never sends it, is
# refused at once and does not wait for the body.
def test_a_request_without_the_token_is_refused_before_its_body_arrives() -> Result[Void]
  H.using(H.Setup(replies: [])) do |h|
    socket = try TCP.connect("127.0.0.1", h.server.port, 2000)
    head = "POST #{Protocol.SESSIONS_PATH} HTTP/1.1\r\nHost: 127.0.0.1:#{h.server.port}\r\nContent-Length: 100\r\n\r\n"
    wrote = TCP.write(socket, head, 2000)
    line = TCP.read_line(socket, 2000)
    TCP.close(socket)
    try wrote
    try Test.assert((try line).include?("401"), "the answer: #{line}")
    ok()
  end
end

# The event stream carries the id of each event, and a `Last-Event-ID` resumes after it (0 is from the first event).
def test_the_event_stream_has_ids_and_resumes_after_last_event_id() -> Result[Void]
  H.using(H.Setup(replies: ["text.sse"])) do |h|
    app = Server.app(h.token, h.server.sessions, h.server.control)
    id = try H.new_session(h)
    _ = try H.send(h, id, "Hello.")
    last = (try H.idle(h, id)).last_event_id
    good = header(h.token)
    path = Protocol.events_path(id)

    from_start = good.push(HTTP.Header(name: Protocol.LAST_EVENT_ID_HEADER, value: "0"))
    first = Testing.request(app, "GET", path, from_start, max_pieces: 1)
    try Test.eq(first.status, 200)
    try Test.eq(HTTP.header_values(first.headers, "content-type"), ["text/event-stream"])
    try Test.eq(HTTP.header_values(first.headers, "cache-control"), ["no-cache"])

    try Test.eq(try event_ids(first), ["1"])

    resume = good.push(HTTP.Header(name: Protocol.LAST_EVENT_ID_HEADER, value: Protocol.format_event_id(last - 1)))
    try Test.eq(
      try event_ids(Testing.request(app, "GET", path, resume, max_pieces: 1)),
      [Protocol.format_event_id(last)],
    )

    bad = good.push(HTTP.Header(name: Protocol.LAST_EVENT_ID_HEADER, value: "x"))
    try Test.eq(failure_kind(Testing.request(app, "GET", path, bad)), ok(Protocol.KIND_INVALID))
    gone = Testing.request(app, "GET", Protocol.events_path("nope"), good)
    Test.eq(failure_kind(gone), ok(Protocol.KIND_SESSION_NOT_FOUND))
  end
end

def event_ids(response: HTTP.Response) -> Result[List[String]]
  fed = try SSE.feed(SSE.parser(), response.body)
  ok(fed.events.map { |event| event.id })
end
