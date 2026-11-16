## The messages of `monty.proto` (monty.v1, protocol 8) that a host of plain functions needs: `Configure` with its
## first `Feed`, `ResumeCall`, `ResumeNameLookup`, `AbortFeed` and `Shutdown` out, every `WorkerEvent` in. Values
## cross as an arena of nodes; what comes back is read as JSON.

import Proto from "proto"

PROTOCOL_VERSION = 8

struct Limits
  max_memory_bytes: Int
  max_recursion_depth: Int
  max_feed_ms: Int
  max_suspensions: Int
end

## A call of a host function by the script: `kwargs` keys are strings.
struct Call
  call_id: Int
  name: String
  args: List[JSON.Value]
  kwargs: Map[String, JSON.Value]
  ## The receiver is a host object, which this host never gives.
  method: Bool
end

enum Event
  Print(String)
  Call(Call)
  OsCall(Int)
  NameLookup(String)
  ## Every task waits for futures, which this host never gives.
  Futures
  Complete(JSON.Value)
  ## The script raised: the exception as Python prints its last line, with the line.
  Raised(String)
  ## The worker cannot go on, or refused the session.
  Fatal(String)
  Ack
  Other(Int)
end

## `Configure` with its first `Feed`: `code` with each of `functions` defined as a host function.
def start(script_name: String, monty_version: String, limits: Limits, code: String, functions: List[String]) -> Bytes
  nodes = functions.map { |name| node(25, Proto.string_field(1, name)) }
  inputs = (0...functions.size).map { |i| Proto.bytes_field(2, named_ref(functions[i], i)) }
  feed = Bytes.concat([Proto.string_field(1, code)] + inputs + [Proto.bytes_field(3, arena(nodes))])
  configure = Bytes.concat([
    Proto.string_field(1, script_name),
    Proto.bytes_field(2, resource_limits(limits)),
    Proto.string_field(5, monty_version),
    Proto.varint_field(9, PROTOCOL_VERSION),
    Proto.bytes_field(15, feed),
  ])

  Proto.bytes_field(1, configure)
end

## Answers a call with a string.
def returned(call_id: Int, text: String) -> Bytes
  resume(call_id, Proto.varint_field(1, 0), arena([Proto.string_field(8, text)]))
end

## Answers a call by raising `exc_type` with `message` where it was made.
def raised(call_id: Int, exc_type: String, message: String) -> Bytes
  resume(call_id, Proto.bytes_field(2, exception(exc_type, message)), arena([]))
end

## Answers an OS call (a file, the clock, the environment) with its no-handler default, a PermissionError or a
## RuntimeError.
def not_handled(call_id: Int) -> Bytes = resume(call_id, Proto.bytes_field(5, "".bytes), arena([]))

## Answers a name lookup: the name is not defined.
def undefined() -> Bytes
  lookup = Bytes.concat([Proto.bytes_field(1, arena([])), Proto.bytes_field(3, "".bytes)])
  Proto.bytes_field(5, lookup)
end

## Stops a suspended feed by raising `exc_type` at its site.
def abort(exc_type: String, message: String) -> Bytes
  Proto.bytes_field(11, Proto.bytes_field(1, exception(exc_type, message)))
end

def shutdown() -> Bytes = Proto.bytes_field(10, "".bytes)

def decode(data: Bytes) -> Result[Event]
  fields = try Proto.fields(data)
  for field in (fields.select { |f| f.wire == Proto.WIRE_LEN and f.number <= 19 })
    return event(field.number, field.data)
  end

  ok(Event.Other(0))
end

private

def event(number: Int, data: Bytes) -> Result[Event]
  fields = try Proto.fields(data)
  case number
    1 -> ok(Event.Print(Proto.all_data(fields, 1).map { |segment| segment_text(segment) }.join("")))
    2 -> ok(Event.Call(try call(fields)))
    3 -> ok(Event.OsCall(Proto.uint(fields, 1)))
    4 -> ok(Event.NameLookup(Proto.text(fields, 1)))
    5 -> ok(Event.Futures)
    6 ->
      values = try nodes(Proto.data(fields, 2))
      index = Proto.uint(fields, 1)
      return error("monty: the result is not in its arena") if index >= values.size

      ok(Event.Complete(values[index]))
    7 -> ok(Event.Raised(raised_text(Proto.data(fields, 1))))
    8 -> ok(Event.Raised("TypingError: #{Proto.text(fields, 1)}"))
    10 -> ok(Event.Ack)
    11 -> ok(Event.Fatal(Proto.text(fields, 1)))
    14 -> ok(Event.Fatal("the session was refused: #{Proto.text(fields, 1)}"))
    _ -> ok(Event.Other(number))
  end
end

def call(fields: List[Proto.Field]) -> Result[Call]
  values = try nodes(Proto.data(fields, 7))
  args: List[JSON.Value] = []
  for index in try Proto.packed(fields, 2)
    args = args.push(try at(values, index))
  end

  kwargs: Map[String, JSON.Value] = {}
  for pair in Proto.all_data(fields, 3)
    pair_fields = try Proto.fields(pair)
    name = try at(values, Proto.uint(pair_fields, 1))
    kwargs = kwargs.put(key_text(name), try at(values, Proto.uint(pair_fields, 2)))
  end

  ok(
    Call(
      call_id: Proto.uint(fields, 4),
      name: Proto.text(fields, 1),
      args: args,
      kwargs: kwargs,
      method: Proto.has?(fields, 5),
    ),
  )
end

def segment_text(segment: Bytes) -> String
  case Proto.fields(segment)
    ok(fields) -> Proto.text(fields, 2)
    error(_) -> ""
  end
end

# `ValueError: bad input (line 3)`, the last line Python prints, with the line of the innermost frame.
def raised_text(data: Bytes) -> String
  case Proto.fields(data)
    ok(exc) ->
      kind = Proto.text(exc, 1)
      message = Proto.text(exc, 2)
      head = kind
      if message != ""
        head = "#{kind}: #{message}"
      end

      frames = Proto.all_data(exc, 3)
      return head if frames.empty?

      "#{head} (line #{frame_line(frames.last)})"
    error(e) -> e.message
  end
end

def frame_line(frame: Bytes) -> Int
  case Proto.fields(frame)
    ok(fields) ->
      case Proto.fields(Proto.data(fields, 2))
        ok(start) -> Proto.uint(start, 1)
        error(_) -> 0
      end

    error(_) -> 0
  end
end

def exception(exc_type: String, message: String) -> Bytes
  Bytes.concat([Proto.string_field(1, exc_type), Proto.string_field(2, message)])
end

def resume(call_id: Int, result: Bytes, values: Bytes) -> Bytes
  body = Bytes.concat([Proto.varint_field(1, call_id), Proto.bytes_field(2, result), Proto.bytes_field(3, values)])
  Proto.bytes_field(4, body)
end

def resource_limits(limits: Limits) -> Bytes
  Bytes.concat([
    Proto.varint_field(2, limits.max_memory_bytes),
    Proto.varint_field(4, limits.max_recursion_depth),
    Proto.varint_field(5, limits.max_suspensions),
    Proto.varint_field(6, limits.max_feed_ms * 1000),
  ])
end

def named_ref(name: String, index: Int) -> Bytes
  Bytes.concat([Proto.string_field(1, name), Proto.varint_field(2, index)])
end

def node(kind: Int, body: Bytes) -> Bytes = Proto.bytes_field(kind, body)

def arena(nodes: List[Bytes]) -> Bytes
  Bytes.concat([Proto.varint_field(1, nodes.size)] + nodes.map { |n| Proto.bytes_field(2, n) })
end

def at(values: List[JSON.Value], index: Int) -> Result[JSON.Value]
  return error("monty: a node index is out of its arena") if index >= values.size

  ok(values[index])
end

def key_text(key: JSON.Value) -> String
  case JSON.string(key)
    ok(text) -> text
    error(_) -> JSON.encode(key)
  end
end

# The nodes of an arena as JSON, in one forward pass: a container's children come before it.
def nodes(arena: Bytes) -> Result[List[JSON.Value]]
  fields = try Proto.fields(arena)
  values: List[JSON.Value] = []
  for data in Proto.all_data(fields, 2)
    values = values.push(try node_value(data, values))
  end

  ok(values)
end

def node_value(data: Bytes, done: List[JSON.Value]) -> Result[JSON.Value]
  fields = try Proto.fields(data)
  return ok(JSON.null()) if fields.empty?

  field = fields.last
  body: List[Proto.Field] = []
  if [11, 12, 13, 14, 15, 16, 22, 23, 25].include?(field.number)
    body = try Proto.fields(field.data)
  end

  case field.number
    2 -> ok(JSON.null())
    1 -> ok(JSON.from("Ellipsis"))
    3 -> ok(JSON.from("NotImplemented"))
    4 -> ok(JSON.from(field.value != 0))
    5 -> ok(JSON.from(Proto.unzigzag(field.value)))
    6 -> ok(JSON.from("<int too large>"))
    7 -> ok(JSON.from(Float.from_bits(field.value)))
    8, 26, 27, 29, 30, 33 -> ok(JSON.from(Proto.utf8(field.data)))
    9 -> ok(JSON.from(Proto.utf8(field.data)))
    11, 12, 15, 16 ->
      items: List[JSON.Value] = []
      for index in try Proto.packed(body, 1)
        items = items.push(try at(done, index))
      end

      ok(JSON.array(items))
    13 ->
      names = Proto.all_data(body, 2).map { |name| Proto.utf8(name) }
      indexes = try Proto.packed(body, 3)
      out: Map[String, JSON.Value] = {}
      for i in 0...[names.size, indexes.size].min.unwrap!
        out = out.put(names[i], try at(done, indexes[i]))
      end

      ok(JSON.object(out))
    14 ->
      out: Map[String, JSON.Value] = {}
      for pair in Proto.all_data(body, 1)
        pair_fields = try Proto.fields(pair)
        name = try at(done, Proto.uint(pair_fields, 1))
        out = out.put(key_text(name), try at(done, Proto.uint(pair_fields, 2)))
      end

      ok(JSON.object(out))
    22 -> ok(JSON.from("#{Proto.text(body, 1)}(#{Proto.text(body, 2).inspect})"))
    23 -> ok(JSON.from("<class #{Proto.text(body, 1)}>"))
    25 -> ok(JSON.from("<function #{Proto.text(body, 1)}>"))
    _ -> ok(JSON.from("<value of kind #{field.number}>"))
  end
end
