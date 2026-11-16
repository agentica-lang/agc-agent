## One script in one `monty subprocess` worker: the session is configured and fed in one request, then each event
## is answered until the script ends. Frames are a 4-byte little-endian length and a protobuf message.

import Binary from "std/binary"
import Wire from "wire"

MAX_FRAME = 16_777_216
READ_PIECE = 1_048_576
SEND_MS = 10_000
CLOSE_MS = 2_000

struct Limits
  max_memory_bytes: Int = 67_108_864
  max_recursion_depth: Int = 200
  ## Sandbox time of the script, without the time its calls of host functions take.
  max_feed_ms: Int = 5_000
  max_calls: Int = 50
  ## How long one answer of the worker may take, a backstop for the sandbox clock.
  wait_ms: Int = 15_000
  max_output_chars: Int = 30_000
end

## A call of a host function by name, with keyword arguments.
struct Call
  name: String
  args: List[JSON.Value]
  kwargs: Map[String, JSON.Value]
end

enum Answer
  Value(String)
  Raise(String, String)
end

## What the script printed, its value (null when none) and, when it raised, the exception.
struct Outcome
  output: String
  value: JSON.Value
  error: Optional[String]
end

## The words that start the worker of `binary`.
def command(binary: String) -> List[String] = [binary, "subprocess"]

## Runs `code` in a worker that `words` start, with each of `functions` a host function that `host` answers. A Python
## error is an outcome with `error`; a worker that crashes, refuses the session or goes past `wait_ms` is an `error`.
def run(
  words: List[String],
  code: String,
  functions: List[String],
  host: Fn[Call, Answer],
  limits: Limits = Limits(),
) -> Result[Outcome]
  return error("monty: no worker command", kind: "monty.crash") if words.empty?

  process = try Process.spawn_captured(words[0], words.drop(1), Process.Options(pgroup: true))
  result = drive(process, code, functions, host, limits)
  Process.close(process)
  result
end

private

struct State
  output: String = ""
  cut: Int = 0
  calls: Int = 0
end

def drive(
  process: Process,
  code: String,
  functions: List[String],
  host: Fn[Call, Answer],
  limits: Limits,
) -> Result[Outcome]
  wire_limits = Wire.Limits(
    max_memory_bytes: limits.max_memory_bytes,
    max_recursion_depth: limits.max_recursion_depth,
    max_feed_ms: limits.max_feed_ms,
    max_suspensions: limits.max_calls + 1000,
  )

  try send(process, Wire.start("script.py", "1.6.0", wire_limits, code, functions))
  state = State()
  while true
    event = try receive(process, limits.wait_ms)
    case event
      Wire.Event.Print(text) -> state = printed(state, text, limits.max_output_chars)
      Wire.Event.Call(call) ->
        state = state.with(calls: state.calls + 1)
        try send(process, answer(call, functions, host, state.calls, limits.max_calls))
      Wire.Event.OsCall(call_id) -> try send(process, Wire.not_handled(call_id))
      Wire.Event.NameLookup(_) -> try send(process, Wire.undefined())
      Wire.Event.Futures -> try send(process, Wire.abort("RuntimeError", "async host calls are not supported"))
      Wire.Event.Complete(value) -> return finished(process, state, value, none)
      Wire.Event.Raised(text) -> return finished(process, state, JSON.null(), some(text))
      Wire.Event.Fatal(message) -> return error("monty: #{message}", kind: "monty.fatal")
      _ -> next
    end
  end

  error("monty: the worker stopped", kind: "monty.crash")
end

def finished(process: Process, state: State, value: JSON.Value, raised: Optional[String]) -> Result[Outcome]
  _ = send(process, Wire.shutdown())
  output = state.output
  if state.cut > 0
    output = "#{output}\n[output cut: #{state.cut} more characters]"
  end

  ok(Outcome(output: output, value: value, error: raised))
end

def answer(call: Wire.Call, functions: List[String], host: Fn[Call, Answer], count: Int, max: Int) -> Bytes
  if call.method or not functions.include?(call.name)
    return Wire.raised(call.call_id, "NameError", "name '#{call.name}' is not defined")
  end

  return Wire.raised(call.call_id, "RuntimeError", "a script makes at most #{max} tool calls") if count > max

  case host.call(Call(name: call.name, args: call.args, kwargs: call.kwargs))
    Answer.Value(text) -> Wire.returned(call.call_id, text)
    Answer.Raise(kind, message) -> Wire.raised(call.call_id, kind, message)
  end
end

def printed(state: State, text: String, max: Int) -> State
  room = max - state.output.length
  return state.with(cut: state.cut + text.length) if room <= 0
  return state.with(output: state.output + text) if text.length <= room

  state.with(output: state.output + text.slice(0, room), cut: state.cut + text.length - room)
end

def send(process: Process, message: Bytes) -> Result[Void]
  head = try Binary.write_u32_le(message.length)
  Process.send_bytes(process, Bytes.concat([head, message]), SEND_MS)
end

def receive(process: Process, wait_ms: Int) -> Result[Wire.Event]
  head = try read_exactly(process, 4, wait_ms)
  size = try Binary.read_u32_le(head, 0)
  return error("monty: a frame of #{size} bytes is over the limit", kind: "monty.protocol") if size > MAX_FRAME

  body = try read_exactly(process, size, wait_ms)
  case Wire.decode(body)
    ok(event) -> ok(event)
    error(e) -> error(e.message, kind: "monty.protocol")
  end
end

def read_exactly(process: Process, count: Int, wait_ms: Int) -> Result[Bytes]
  pieces: List[Bytes] = []
  got = 0
  deadline = Time.monotonic_ms + wait_ms
  while got < count
    left = deadline - Time.monotonic_ms
    return error("monty: the worker did not answer in #{wait_ms} ms", kind: "monty.timeout") if left <= 0

    read = Process.read_bytes(process, [count - got, READ_PIECE].min.unwrap!, left)
    return error("monty: #{read.message}", kind: "monty.timeout") if not read.ok?

    piece = read.unwrap!
    return error("monty: the worker stopped", kind: "monty.crash") if piece.empty?

    pieces = pieces.push(piece)
    got = got + piece.length
  end

  ok(Bytes.concat(pieces))
end
