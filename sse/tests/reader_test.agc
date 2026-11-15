import SSE from "../sse"

# Every line end (CRLF, LF, CR), a BOM, comments, an unknown field, multi-line data, a name, an id that carries over,
# an id with a NUL (ignored), `retry:` (ignored), a field with no colon, a value without its space, and characters of 2
# and 4 bytes.
STREAM = (
  String.from_code(65_279) +
  "data: first\r\n: a comment\r\n\r\n" +
  "event: delta\nid: 7\ndata:{\"a\": \"é\"}\ndata:  two\nfoo: bar\nretry: 3000\nid: 8" +
  String.from_code(0) +
  "\n\n" +
  "event: crlf\r\ndata: 😀\r\rdata\r\n\r\n" +
  "id\nevent: empty\n\n" +
  "data: cut"
)

EVENTS = [
  SSE.Event(data: "first"),
  SSE.Event(name: "delta", data: "{\"a\": \"é\"}\n two", id: "7"),
  SSE.Event(name: "crlf", data: "😀", id: "7"),
  SSE.Event(data: "", id: "7"),
]

def test_parses_a_stream_in_one_piece() -> Result[Void] = Test.eq(parse([STREAM.bytes]), ok(EVENTS))

def test_parses_a_stream_split_at_every_byte() -> Result[Void]
  bytes = STREAM.bytes
  Test.eq(parse((0...bytes.size).map { |i| bytes.slice(i, 1) }), ok(EVENTS))
end

def test_parses_a_stream_cut_in_two_anywhere() -> Result[Void]
  bytes = STREAM.bytes
  for i in 0..bytes.size
    try Test.eq(parse([bytes.take(i), bytes.drop(i)]), ok(EVENTS))
  end

  ok()
end

def test_empty_pieces_keep_a_cr_and_lf_together() -> Result[Void]
  try Test.eq(parse(["data: x\r".bytes, "".bytes, "\n".bytes]), ok([]))
  Test.eq(parse(["data: x\r".bytes, "".bytes, "\n".bytes, "".bytes, "\r\n".bytes]), ok([SSE.Event(data: "x")]))
end

# The same stream, cut at random points with empty pieces between some cuts, gives the same events. The seed is
# printed when the run fails.
def test_random_cuts_and_empty_pieces_give_the_same_events() -> Result[Void]
  bytes = STREAM.bytes
  for _round in 1..200
    try Test.eq(parse(random_pieces(bytes)), ok(EVENTS))
  end

  ok()
end

def test_an_event_over_the_limit_fails() -> Result[Void]
  fed = SSE.feed(SSE.parser(max_event_bytes: 8), "data: 12345\ndata: 6789".bytes)
  Test.assert(kind?(fed, "sse.too_large"), "expected sse.too_large")
end

def test_a_line_that_is_not_utf8_fails() -> Result[Void]
  fed = SSE.feed(SSE.parser(), Bytes.concat(["data: ".bytes, Bytes.from_list([255]).unwrap!, "\n".bytes]))
  Test.assert(kind?(fed, "sse.encoding"), "expected sse.encoding")
end

def test_the_writer_round_trips() -> Result[Void]
  events = [
    SSE.Event(data: "{\"type\": \"text_delta\"}", id: "1"),
    SSE.Event(name: "usage", data: "a\n\n b\r\nc", id: "2"),
    SSE.Event(name: "empty", id: "3"),
  ]

  text = events.map { |e| SSE.encode(e).unwrap! }
  try Test.eq(text[1], "event: usage\nid: 2\ndata: a\ndata: \ndata:  b\ndata: c\n\n")
  Test.eq(parse([text.join("").bytes]), ok(events.map { |e| e.with(data: e.data.replace("\r\n", "\n")) }))
end

def test_the_writer_refuses_a_line_end_in_a_field() -> Result[Void]
  try Test.error?(SSE.encode(SSE.Event(name: "a\nb", data: "x")))
  try Test.error?(SSE.encode(SSE.Event(data: "x", id: "1\r")))
  Test.error?(SSE.encode(SSE.Event(data: "x", id: "1" + String.from_code(0))))
end

private

def parse(pieces: List[Bytes]) -> Result[List[SSE.Event]]
  state = SSE.parser()
  events: List[SSE.Event] = []
  for piece in pieces
    fed = try SSE.feed(state, piece)
    state = fed.parser
    events = events + fed.events
  end

  ok(events)
end

def random_pieces(bytes: Bytes) -> List[Bytes]
  pieces: List[Bytes] = []
  start = 0
  while start < bytes.size
    if Random.int(0, 3) == 0
      pieces = pieces.push("".bytes)
    end

    length = Random.int(1, 8)
    pieces = pieces.push(bytes.drop(start).take(length))
    start = start + length
  end

  pieces
end

def kind?(fed: Result[SSE.Fed], kind: String) -> Bool
  case fed
    ok(_) -> false
    error(e) -> e.kind == kind
  end
end
