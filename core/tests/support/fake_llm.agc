## A fake LLM API on 127.0.0.1, port 0: it answers each request with the next of its replies and keeps the requests
## it got, so a test checks both what the provider sent and what it made of the answer.

import HTTP from "std/http"

# The fixtures, from the package folder (`make unit`) or from the repository root.
FIXTURE_DIRS = ["tests/fixtures", "core/tests/fixtures"]
WAIT_MS = 5000

## One answer of the fake.
struct Reply
  status: Int
  body: Bytes
  headers: List[HTTP.Header] = []
  ## The body goes out in pieces of this many bytes (0: whole), so the client sees an event cut anywhere.
  piece_bytes: Int = 0
  ## Announces a longer body than it sends, then closes: a cut connection.
  cut: Bool = false
end

## A request the fake got.
struct Seen
  method: String
  path: String
  headers: List[HTTP.Header]
  body: String
end

## A running fake. `url` is the base URL a provider takes. `left` gets one value each time a client left a streamed
## answer before its end.
struct Fake
  server: HTTP.Server
  url: String
  seen: Channel[Seen]
  left: Channel[Bool]
end

## Starts a fake that gives `replies` in order, then 500.
def start(replies: List[Reply]) -> Result[Fake]
  script: Channel[Reply] = Channel.new(replies.size + 1)
  for reply in replies
    try script.send(reply, 0)
  end

  seen: Channel[Seen] = Channel.new(replies.size + 1)
  left: Channel[Bool] = Channel.new(replies.size + 1)
  server = try HTTP.serve(
    "127.0.0.1",
    0,
    ->(request, body) { answer(Script(replies: script, seen: seen, left: left), request, body) },
  )

  ok(Fake(server: server, url: "http://127.0.0.1:#{HTTP.local_port(server)}/v1", seen: seen, left: left))
end

## Stops the fake and its connections.
def stop(fake: Fake) -> Result[Void]
  HTTP.close_server(fake.server)
  HTTP.wait(fake.server)
end

## The next request the fake got.
def next_request(fake: Fake) -> Result[Seen] = fake.seen.recv(WAIT_MS)

## A 200 event stream of the fixture `name` (a path under `tests/fixtures`), in pieces of `piece_bytes`.
def sse(name: String, piece_bytes: Int = 7) -> Result[Reply]
  body = try fixture(name)
  ok(Reply(status: 200, body: body, headers: [content_type("text/event-stream")], piece_bytes: piece_bytes))
end

## A JSON answer with the fixture `name`.
def json(status: Int, name: String, headers: List[HTTP.Header] = []) -> Result[Reply]
  body = try fixture(name)
  ok(Reply(status: status, body: body, headers: headers.push(content_type("application/json"))))
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
  replies: Channel[Reply]
  seen: Channel[Seen]
  left: Channel[Bool]
end

struct Pieces
  channel: Channel[Bytes]
  reply: Reply
  left: Channel[Bool]
end

def content_type(value: String) -> HTTP.Header = HTTP.Header(name: "Content-Type", value: value)

def answer(script: Script, request: HTTP.Request, body: HTTP.RequestBody) -> Result[HTTP.Answer]
  bytes = try HTTP.read_all(body, 1_048_576)
  text = try String.from_bytes(bytes)
  try script.seen.send(Seen(method: request.method, path: request.path, headers: request.headers, body: text), WAIT_MS)
  reply = script.replies.recv(0).unwrap_or(Reply(status: 500, body: "{\"error\": \"no reply left\"}".bytes))
  if reply.piece_bytes == 0 and not reply.cut
    return ok(HTTP.Answer.Whole(HTTP.Response(status: reply.status, headers: reply.headers, body: reply.body)))
  end

  pieces: Channel[Bytes] = Channel.new(8)
  Task.spawn(&produce, Pieces(channel: pieces, reply: reply, left: script.left))
  length: Optional[Int] = none
  if reply.cut
    length = some(reply.body.size + 1)
  end

  ok(
    HTTP.Answer.Stream(
      HTTP.StreamResponse(status: reply.status, headers: reply.headers, body: pieces, length: length),
    ),
  )
end

def produce(job: Pieces) -> Void
  size = [job.reply.piece_bytes, 1].max.unwrap!
  start = 0
  while start < job.reply.body.size
    if not job.channel.send(job.reply.body.drop(start).take(size), WAIT_MS).ok?
      _ = job.left.send(true, 0)
      break
    end

    start = start + size
  end

  job.channel.close
end
