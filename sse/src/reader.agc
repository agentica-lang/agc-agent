## The parser of the WHATWG `text/event-stream` format, fed the pieces of a stream as they arrive.

MAX_EVENT_BYTES = 16_777_216
CR = 13
LF = 10
BOM = [239, 187, 191]

## One dispatched event.
struct Event
  ## The `event:` field; `message` when the event has none.
  name: String = "message"
  ## The `data:` lines, joined with `\n`.
  data: String = ""
  ## The last `id:` of the stream, which carries over to the events after it.
  id: String = ""
end

## The state between two pieces of a stream.
struct Parser
  max_event_bytes: Int = MAX_EVENT_BYTES

  private

  line: List[Bytes] = []
  line_bytes: Int = 0
  after_cr: Bool = false
  started: Bool = false
  name: String = ""
  data: List[String] = []
  data_bytes: Int = 0
  id: String = ""
end

## What one piece gave: the next state and the events it finished.
struct Fed
  parser: Parser
  events: List[Event]
end

## A parser at the start of a stream. An event (its data and the line being read) over `max_event_bytes` is an error.
def parser(max_event_bytes: Int = MAX_EVENT_BYTES) -> Parser = Parser(max_event_bytes: max_event_bytes)

## Feeds the next piece. A line may end with CRLF, LF or CR, and a piece may end anywhere, even inside a UTF-8
## character. Errors: `sse.encoding` (a line is not UTF-8), `sse.too_large`.
def feed(parser: Parser, piece: Bytes) -> Result[Fed]
  state = parser
  events: List[Event] = []
  size = piece.size
  i = 0
  return ok(Fed(parser: state, events: [])) if size == 0

  # A CRLF may be cut between two pieces: the LF that starts this piece ends no line.
  if state.after_cr and piece[0] == LF
    i = 1
  end

  start = i
  state = state.with(after_cr: false)
  while i < size
    byte = piece[i]
    if byte == LF or byte == CR
      taken = try take_line(state, Bytes.concat(state.line.push(piece.slice(start, i - start))))
      state = taken.parser
      events = events + taken.events
      if byte == CR
        if i + 1 == size
          state = state.with(after_cr: true)
        elsif piece[i + 1] == LF
          i = i + 1
        end
      end

      start = i + 1
    end

    i = i + 1
  end

  rest = size - start
  return ok(Fed(parser: state, events: events)) if rest <= 0

  line_bytes = state.line_bytes + rest
  try check_size(state, line_bytes)
  ok(Fed(parser: state.with(line: state.line.push(piece.slice(start, rest)), line_bytes: line_bytes), events: events))
end

private

def check_size(state: Parser, line_bytes: Int) -> Result[Void]
  limit = state.max_event_bytes
  return error("sse: event over #{limit} bytes", kind: "sse.too_large") if line_bytes > limit - state.data_bytes

  ok()
end

def take_line(parser: Parser, raw: Bytes) -> Result[Fed]
  try check_size(parser, raw.size)
  bytes = raw
  if not parser.started and bom?(raw)
    bytes = raw.drop(BOM.size)
  end

  state = parser.with(line: [], line_bytes: 0, started: true)
  text = try decode(bytes)

  return ok(dispatch(state)) if text.empty?
  return ok(Fed(parser: state, events: [])) if text.start_with?(":")

  ok(Fed(parser: take_field(state, text), events: []))
end

def decode(bytes: Bytes) -> Result[String]
  case String.from_bytes(bytes)
    ok(text) -> ok(text)
    error(e) -> error("sse: a line is not UTF-8: #{e.message}", kind: "sse.encoding")
  end
end

def bom?(raw: Bytes) -> Bool = raw.size >= BOM.size and raw.take(BOM.size).to_a == BOM

def take_field(state: Parser, text: String) -> Parser
  field = text
  value = ""
  case text.index_of(":")
    some(colon) ->
      field = text.slice(0, colon)
      value = text.slice(colon + 1, text.length - colon - 1)
      if value.start_with?(" ")
        value = value.slice(1, value.length - 1)
      end

    none -> value = ""
  end

  case field
    "event" -> state.with(name: value)
    "data" -> state.with(data: state.data.push(value), data_bytes: state.data_bytes + value.bytesize + 1)
    "id" if not value.include?(String.from_code(0)) -> state.with(id: value)
    _ -> state
  end
end

def dispatch(state: Parser) -> Fed
  reset = state.with(name: "", data: [], data_bytes: 0)
  return Fed(parser: reset, events: []) if state.data.empty?

  event = Event(data: state.data.join("\n"), id: state.id)
  Fed(parser: reset, events: [if_named(event, state.name)])
end

def if_named(event: Event, name: String) -> Event
  return event if name.empty?

  event.with(name: name)
end
# proof
