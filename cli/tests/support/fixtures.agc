## The recorded data of the tests, read through the protocol's own codecs: a fixture that no longer decodes (a field
## the protocol renamed) fails here instead of being served to the client as it is.

import Protocol from "pkg/protocol/protocol"
import SSE from "pkg/sse/sse"

DIRS = ["tests/fixtures", "cli/tests/fixtures"]

## The names of the fixtures that start with `prefix` and end with `suffix`.
def names(prefix: String, suffix: String) -> Result[List[String]]
  dir = try folder()
  files = try Dir.list(dir)
  ok(files.select { |file| file.start_with?(prefix) and file.end_with?(suffix) })
end

## A `session_*.json` fixture.
def session(name: String) -> Result[Protocol.Session] = Protocol.decode_session(try text(name))

## The body the fake serves for a session fixture, written by the protocol's encoder.
def session_body(name: String) -> Result[Bytes] = ok(Protocol.encode_session(try session(name)).bytes)

## The events of an `.sse` fixture, each decoded by the protocol.
def events(name: String) -> Result[List[Protocol.Event]]
  fed = try SSE.feed(SSE.parser(), (try text(name)).bytes)
  decoded: List[Protocol.Event] = []
  for sse in fed.events
    decoded = decoded.push(try Protocol.decode_event(sse.name, sse.data))
  end

  return error("fixture #{name} has no event") if decoded.empty?

  ok(decoded)
end

## The bytes of an `.sse` fixture, once every event of it decodes.
def stream(name: String) -> Result[Bytes]
  _ = try events(name)
  ok((try text(name)).bytes)
end

private

def folder() -> Result[String]
  found = DIRS.find { |dir| File.stat(dir).ok? }
  case found
    ok(dir) -> ok(dir)
    error(_) -> error("none of #{DIRS.join(", ")} exists: run the tests from the repository root or the package")
  end
end

def text(name: String) -> Result[String] = File.read_text("#{try folder()}/#{name}")
