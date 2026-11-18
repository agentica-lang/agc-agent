## A fake Finn Agent server on 127.0.0.1, port 0. It checks the token of every request, answers each route with the next
## of its replies, keeps the requests it got, and streams recorded SSE fixtures on the events route: the ones a reply
## names, then the ones a test or a later reply pushes.

import HTTP from "std/http"
import Protocol from "pkg/protocol/protocol"
import Fixtures from "fixtures"

TOKEN = "test-token"
VERSION = "0.0.1"
HEALTH = "GET /v1/health"
LOGS = "GET #{Protocol.LOGS_PATH}"
WAIT_MS = 5000
POLL_MS = 100
PIECE_BYTES = 13

## One answer of a route.
struct Reply
  status: Int = 200
  body: String = ""
  ## An `.sse` fixture: the replayed events of the events route.
  fixture: String = ""
  ## A `session_*.json` fixture served as the body instead of `body`.
  session: String = ""
  ## The answer waits this long first.
  delay_ms: Int = 0
  ## Fixtures put on the held event stream after this answer.
  push: List[String] = []
  ## The events route only: the stream stays open for pushes.
  hold: Bool = false
end

## The replies of one route, one per request.
struct Route
  method: String
  path: String
  replies: List[Reply]
end

## A request the fake got.
struct Seen
  method: String
  path: String
  headers: List[HTTP.Header]
  body: String
end

## A running fake. `seen` has one channel per route (and the health check), `stray` the requests of no route.
struct Fake
  server: HTTP.Server
  port: Int
  seen: Map[String, Channel[Seen]]
  stray: Channel[Seen]
  bus: Channel[Bytes]
end

## Starts a fake with `routes`; `GET /v1/health` and `GET /v1/logs` (an empty log) are always there, and a route of one
## replaces the answer.
def start(routes: List[Route]) -> Result[Fake]
  queues: Map[String, Channel[Reply]] = {}
  seen: Map[String, Channel[Seen]] = {HEALTH: Channel.new(16), LOGS: Channel.new(16)}
  for route in routes
    key = key_of(route.method, route.path)
    replies: Channel[Reply] = Channel.new(route.replies.size + 1)
    for reply in route.replies
      try replies.send(reply, 0)
    end

    queues = queues.put(key, replies)
    seen = seen.put(key, Channel.new(route.replies.size + 16))
  end

  stray: Channel[Seen] = Channel.new(16)
  bus: Channel[Bytes] = Channel.new(64)
  newest: Channel[Int] = Channel.new(1)
  try newest.send(0, 0)
  script = Script(queues: queues, seen: seen, stray: stray, bus: bus, newest: newest)
  server = try HTTP.serve("127.0.0.1", 0, ->(request, body) { answer(script, request, body) })
  ok(Fake(server: server, port: HTTP.local_port(server), seen: seen, stray: stray, bus: bus))
end

## Stops the fake and its connections.
def stop(fake: Fake) -> Result[Void]
  HTTP.close_server(fake.server)
  HTTP.wait(fake.server)
end

## The `server.json` text of the fake, with `token`.
def server_file(fake: Fake, token: String) -> String
  Protocol.encode_server_info(Protocol.ServerInfo(port: fake.port, token: token, pid: System.pid()))
end

## The next request the fake got on a route.
def request(fake: Fake, method: String, path: String) -> Result[Seen]
  case fake.seen.get(key_of(method, path))
    some(channel) -> channel.recv(WAIT_MS)
    none -> error("no route #{method} #{path}")
  end
end

## The requests the fake got on a route that nobody has read yet, in order.
def unread_requests(fake: Fake, method: String, path: String) -> List[Seen]
  case fake.seen.get(key_of(method, path))
    some(channel) -> drained(channel)
    none -> []
  end
end

## How many requests the fake got on a route that nobody has read yet.
def unread(fake: Fake, method: String, path: String) -> Int = unread_requests(fake, method, path).size

## How many requests of no route the fake got.
def strays(fake: Fake) -> Int = drained(fake.stray).size

## Puts a fixture on the held event stream.
def push(fake: Fake, name: String) -> Result[Void]
  body = try Fixtures.stream(name)
  fake.bus.send(body, WAIT_MS)
end

## Writes a file only its owner can read, as the server does with `server.json`.
def write_private(path: String, text: String) -> Result[Void]
  File.open(path, "create_private") do |file| File.write(file, text) end
end

private

struct Script
  queues: Map[String, Channel[Reply]]
  seen: Map[String, Channel[Seen]]
  stray: Channel[Seen]
  bus: Channel[Bytes]
  ## Holds the number of the newest event request: only its stream takes pushes from the bus.
  newest: Channel[Int]
end

struct Held
  out: Channel[Bytes]
  first: Bytes
  hold: Bool
  bus: Channel[Bytes]
  newest: Channel[Int]
  number: Int
end

def key_of(method: String, path: String) -> String = "#{method} #{path}"

def drained(channel: Channel[Seen]) -> List[Seen]
  all: List[Seen] = []
  while true
    case channel.recv(0)
      ok(seen) -> all = all.push(seen)
      error(_) -> break
    end
  end

  all
end

def answer(script: Script, request: HTTP.Request, body: HTTP.RequestBody) -> Result[HTTP.Answer]
  bytes = try HTTP.read_all(body, 1_048_576)
  text = try String.from_bytes(bytes)
  seen = Seen(method: request.method, path: request.path, headers: request.headers, body: text)
  key = key_of(request.method, request.path)
  number = claim(script, request)
  case script.seen.get(key)
    some(channel) -> try channel.send(seen, WAIT_MS)
    none -> try script.stray.send(seen, WAIT_MS)
  end

  return refuse(401, Protocol.KIND_UNAUTHORIZED, "the token is missing or wrong") if not authorized?(request)
  if key == HEALTH and not script.queues.has_key?(key)
    return json(200, Protocol.encode_health(Protocol.Health(version: VERSION, wire: some(Protocol.wire_digest()))))
  end

  if key == LOGS and not script.queues.has_key?(key)
    return json(200, Protocol.encode_server_log(Protocol.ServerLog(lines: [], warnings: [], warning_count: 0)))
  end

  case script.queues.get(key)
    some(replies) -> reply_with(script, replies.recv(0).unwrap_or(Reply(status: 500)), request, number)
    none -> refuse(404, Protocol.KIND_SESSION_NOT_FOUND, "no route #{key}")
  end
end

def authorized?(request: HTTP.Request) -> Bool
  HTTP.header_values(request.headers, "authorization") == ["Bearer #{TOKEN}"]
end

def reply_with(script: Script, reply: Reply, request: HTTP.Request, number: Int) -> Result[HTTP.Answer]
  if reply.delay_ms > 0
    Task.sleep(reply.delay_ms)
  end

  if request.path.end_with?("/events") and reply.status == 200
    first = "".bytes
    if reply.fixture != ""
      first = try Fixtures.stream(reply.fixture)
    end

    held = Held(
      out: Channel.new(8),
      first: first,
      hold: reply.hold,
      bus: script.bus,
      newest: script.newest,
      number: number,
    )

    return stream(held)
  end

  for name in reply.push
    try script.bus.send(try Fixtures.stream(name), WAIT_MS)
  end

  body = reply.body.bytes
  if reply.session != ""
    body = try Fixtures.session_body(reply.session)
  end

  headers = [HTTP.Header(name: "Content-Type", value: "application/json")]
  ok(HTTP.Answer.Whole(HTTP.Response(status: reply.status, headers: headers, body: body)))
end

def json(status: Int, body: String) -> Result[HTTP.Answer]
  headers = [HTTP.Header(name: "Content-Type", value: "application/json")]
  ok(HTTP.Answer.Whole(HTTP.Response(status: status, headers: headers, body: body.bytes)))
end

def refuse(status: Int, kind: String, message: String) -> Result[HTTP.Answer]
  json(status, Protocol.encode_failure(Protocol.Failure(kind: kind, message: message)))
end

# An event request makes its stream the newest, before the test can see the request, so a push never goes to a stream
# the client has already left.
def claim(script: Script, request: HTTP.Request) -> Int
  return 0 if not request.path.end_with?("/events")

  number = script.newest.recv(WAIT_MS).unwrap_or(0) + 1
  _ = script.newest.send(number, WAIT_MS)
  number
end

def newest?(held: Held) -> Bool
  case held.newest.recv(WAIT_MS)
    ok(number) ->
      _ = held.newest.send(number, WAIT_MS)
      number == held.number
    error(_) -> false
  end
end

def stream(held: Held) -> Result[HTTP.Answer]
  Task.spawn(&produce, held)
  headers = [HTTP.Header(name: "Content-Type", value: "text/event-stream")]
  ok(HTTP.Answer.Stream(HTTP.StreamResponse(status: 200, headers: headers, body: held.out)))
end

def produce(held: Held) -> Void
  if relay(held, held.first)
    while held.hold and not held.out.closed?
      if newest?(held)
        case held.bus.recv(POLL_MS)
          ok(piece) ->
            # A newer stream may have claimed the bus while this one waited for the piece: it gets it back.
            if not newest?(held)
              _ = held.bus.send(piece, WAIT_MS)
              break
            end

            break if not relay(held, piece)

          error(_) -> next
        end
      else
        Task.sleep(POLL_MS)
      end
    end
  end

  held.out.close
end

# Sends the bytes in small pieces, so the client sees an event cut anywhere; false when the client left.
def relay(held: Held, bytes: Bytes) -> Bool
  start = 0
  while start < bytes.size
    return false if not held.out.send(bytes.drop(start).take(PIECE_BYTES), WAIT_MS).ok?

    start = start + PIECE_BYTES
  end

  true
end
