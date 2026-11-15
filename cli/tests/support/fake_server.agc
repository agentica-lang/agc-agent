## A fake agc-agent server on 127.0.0.1, port 0. It checks the token of every request, answers each route with the next
## of its replies, keeps the requests it got, and streams recorded SSE fixtures on the events route: the ones a reply
## names, then the ones a test or a later reply pushes.

import HTTP from "std/http"
import Protocol from "pkg/protocol/protocol"

TOKEN = "test-token"
VERSION = "0.0.1"
HEALTH = "GET /v1/health"
FIXTURE_DIRS = ["tests/fixtures", "cli/tests/fixtures"]
WAIT_MS = 5000
POLL_MS = 100
PIECE_BYTES = 13

## One answer of a route.
struct Reply
  status: Int = 200
  body: String = ""
  ## A fixture served as the body instead of `body`: the replayed events of the events route.
  fixture: String = ""
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

## Starts a fake with `routes`; `GET /v1/health` is always there.
def start(routes: List[Route]) -> Result[Fake]
  queues: Map[String, Channel[Reply]] = {}
  seen: Map[String, Channel[Seen]] = {HEALTH: Channel.new(16)}
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
  script = Script(queues: queues, seen: seen, stray: stray, bus: bus)
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
  "{\"port\": #{fake.port}, \"token\": \"#{token}\", \"pid\": #{System.pid()}}"
end

## The next request the fake got on a route.
def request(fake: Fake, method: String, path: String) -> Result[Seen]
  case fake.seen.get(key_of(method, path))
    some(channel) -> channel.recv(WAIT_MS)
    none -> error("no route #{method} #{path}")
  end
end

## How many requests the fake got on a route that nobody has read yet.
def unread(fake: Fake, method: String, path: String) -> Int
  case fake.seen.get(key_of(method, path))
    some(channel) -> drained(channel)
    none -> 0
  end
end

## How many requests of no route the fake got.
def strays(fake: Fake) -> Int = drained(fake.stray)

## Puts a fixture on the held event stream.
def push(fake: Fake, name: String) -> Result[Void]
  body = try fixture(name)
  fake.bus.send(body, WAIT_MS)
end

## The bytes of a fixture file.
def fixture(name: String) -> Result[Bytes]
  for dir in FIXTURE_DIRS
    path = "#{dir}/#{name}"
    if File.stat(path).ok?
      text = try File.read_text(path)
      return ok(text.bytes)
    end
  end

  error("no fixture #{name} in #{FIXTURE_DIRS.join(", ")}")
end

private

struct Script
  queues: Map[String, Channel[Reply]]
  seen: Map[String, Channel[Seen]]
  stray: Channel[Seen]
  bus: Channel[Bytes]
end

struct Held
  out: Channel[Bytes]
  first: Bytes
  hold: Bool
  bus: Channel[Bytes]
end

def key_of(method: String, path: String) -> String = "#{method} #{path}"

def drained(channel: Channel[Seen]) -> Int
  count = 0
  while channel.recv(0).ok?
    count = count + 1
  end

  count
end

def answer(script: Script, request: HTTP.Request, body: HTTP.RequestBody) -> Result[HTTP.Answer]
  bytes = try HTTP.read_all(body, 1_048_576)
  text = try String.from_bytes(bytes)
  seen = Seen(method: request.method, path: request.path, headers: request.headers, body: text)
  key = key_of(request.method, request.path)
  case script.seen.get(key)
    some(channel) -> try channel.send(seen, WAIT_MS)
    none -> try script.stray.send(seen, WAIT_MS)
  end

  return refuse(401, Protocol.KIND_UNAUTHORIZED, "the token is missing or wrong") if not authorized?(request)
  return json(200, "{\"version\": \"#{VERSION}\"}") if key == HEALTH

  case script.queues.get(key)
    some(replies) -> reply_with(script, replies.recv(0).unwrap_or(Reply(status: 500)), request)
    none -> refuse(404, Protocol.KIND_SESSION_NOT_FOUND, "no route #{key}")
  end
end

def authorized?(request: HTTP.Request) -> Bool
  HTTP.header_values(request.headers, "authorization") == ["Bearer #{TOKEN}"]
end

def reply_with(script: Script, reply: Reply, request: HTTP.Request) -> Result[HTTP.Answer]
  first = "".bytes
  if reply.fixture != ""
    first = try fixture(reply.fixture)
  end

  if request.path.end_with?("/events")
    return stream(Held(out: Channel.new(8), first: first, hold: reply.hold, bus: script.bus))
  end

  for name in reply.push
    try script.bus.send(try fixture(name), WAIT_MS)
  end

  headers = [HTTP.Header(name: "Content-Type", value: "application/json")]
  ok(HTTP.Answer.Whole(HTTP.Response(status: reply.status, headers: headers, body: body_of(reply, first))))
end

def body_of(reply: Reply, first: Bytes) -> Bytes
  return first if reply.fixture != ""

  reply.body.bytes
end

def json(status: Int, body: String) -> Result[HTTP.Answer]
  headers = [HTTP.Header(name: "Content-Type", value: "application/json")]
  ok(HTTP.Answer.Whole(HTTP.Response(status: status, headers: headers, body: body.bytes)))
end

def refuse(status: Int, kind: String, message: String) -> Result[HTTP.Answer]
  json(status, Protocol.encode_failure(Protocol.Failure(kind: kind, message: message)))
end

def stream(held: Held) -> Result[HTTP.Answer]
  Task.spawn(&produce, held)
  headers = [HTTP.Header(name: "Content-Type", value: "text/event-stream")]
  ok(HTTP.Answer.Stream(HTTP.StreamResponse(status: 200, headers: headers, body: held.out)))
end

def produce(held: Held) -> Void
  if relay(held, held.first)
    while held.hold and not held.out.closed?
      case held.bus.recv(POLL_MS)
        ok(piece) -> break if not relay(held, piece)
        error(_) -> next
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
