## The file of a session in the data folder: JSON Lines, appended as the session goes. The first line is the session;
## then one line per event (with its id), per message of the model's history and per message a client draws. A line
## that does not parse is a write that a crash cut: loading skips it, and `reopen` starts a new line after it.

import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"

EXTENSION = ".jsonl"
MAX_LINE_BYTES = 16_777_216
MAX_WRITE_BYTES = 1_048_576

struct Header
  id: String
  cwd: String
  model: String
end

struct Logged
  id: Int
  event: Protocol.Event
end

struct Saved
  header: Header
  events: List[Logged]
  history: List[LLM.Message]
  shown: List[Protocol.Message]
end

def file_of(dir: String, id: String) -> String = "#{dir}/#{id}#{EXTENSION}"

## Creates the file of a new session (0600); its path.
def create(dir: String, header: Header) -> Result[String]
  path = file_of(dir, header.id)
  handle = try File.open(path, "create_private")
  written = File.write(
    handle,
    line({
      "type": JSON.from("session"),
      "id": JSON.from(header.id),
      "cwd": JSON.from(header.cwd),
      "model": JSON.from(header.model),
    }),
  )

  try File.close(handle)
  try written
  ok(path)
end

def append_event(path: String, logged: Logged) -> Result[Void]
  data = try JSON.parse(Protocol.encode_event(logged.event))
  append(
    path,
    line({
      "type": JSON.from("event"),
      "id": JSON.from(logged.id),
      "name": JSON.from(Protocol.event_name(logged.event)),
      "data": data,
    }),
  )
end

def append_message(path: String, message: LLM.Message) -> Result[Void]
  append(path, line({"type": JSON.from("message"), "message": encode_message(message)}))
end

def append_shown(path: String, message: Protocol.Message) -> Result[Void]
  append(
    path,
    line({
      "type": JSON.from("shown"),
      "role": JSON.from(Protocol.role_name(message.role)),
      "text": JSON.from(message.text),
    }),
  )
end

## Ends a line a crash may have left open, so the next record starts on a line of its own.
def reopen(path: String) -> Result[Void] = append(path, "\n")

def load(path: String) -> Result[Saved]
  lines = try File.foreach(path, MAX_LINE_BYTES).to_a
  header: Optional[Header] = none
  events: List[Logged] = []
  history: List[LLM.Message] = []
  shown: List[Protocol.Message] = []
  for text in lines
    record = JSON.parse(text)
    next if not record.ok?

    json = record.unwrap!
    kind = try field(json, "type")
    case kind
      "session" ->
        header = some(Header(id: try field(json, "id"), cwd: try field(json, "cwd"), model: try field(json, "model")))
      "event" ->
        data = JSON.encode(try JSON.get(json, "data"))
        event = try Protocol.decode_event(try field(json, "name"), data)
        events = events.push(Logged(id: try JSON.int(try JSON.get(json, "id")), event: event))
      "message" -> history = history.push(try decode_message(try JSON.get(json, "message")))
      "shown" ->
        role = try Protocol.parse_role(try field(json, "role"))
        shown = shown.push(Protocol.Message(role: role, text: try field(json, "text")))
      _ -> return error("#{path}: unknown record #{kind}")
    end
  end

  case header
    some(h) -> ok(Saved(header: h, events: events, history: history, shown: shown))
    none -> error("#{path}: no session record")
  end
end

def encode_message(message: LLM.Message) -> JSON.Value
  role = case message.role
    LLM.Role.User -> "user"
    LLM.Role.Assistant -> "assistant"
  end

  JSON.object({"role": JSON.from(role), "content": JSON.array(message.content.map { |b| encode_block(b) })})
end

def decode_message(json: JSON.Value) -> Result[LLM.Message]
  role = try role_of(try field(json, "role"))

  content: List[LLM.Block] = []
  for item in try JSON.list(try JSON.get(json, "content"))
    content = content.push(try decode_block(item))
  end

  ok(LLM.Message(role: role, content: content))
end

private

def line(fields: Map[String, JSON.Value]) -> String = "#{JSON.encode(JSON.object(fields))}\n"

def append(path: String, text: String) -> Result[Void]
  bytes = text.bytes
  File.open(path, "append") do |handle|
    start = 0
    while start < bytes.size
      try File.write_bytes(handle, bytes.drop(start).take(MAX_WRITE_BYTES))
      start = start + MAX_WRITE_BYTES
    end

    ok()
  end
end

def field(json: JSON.Value, key: String) -> Result[String] = JSON.string(try JSON.get(json, key))

def encode_block(block: LLM.Block) -> JSON.Value
  case block
    LLM.Block.Text(part) -> with_replay({"type": JSON.from("text"), "text": JSON.from(part.text)}, part.replay)
    LLM.Block.Thinking(part) -> with_replay({"type": JSON.from("thinking"), "text": JSON.from(part.text)}, part.replay)
    LLM.Block.ToolUse(call) ->
      kind = case call.kind
        LLM.ToolKind.Function -> "function"
        LLM.ToolKind.Custom -> "custom"
      end

      fields = {
        "type": JSON.from("tool_use"),
        "id": JSON.from(call.id),
        "name": JSON.from(call.name),
        "arguments": JSON.from(call.arguments),
        "input": call.input,
        "kind": JSON.from(kind),
      }

      for problem in option_list(call.input_error)
        fields = fields.put("input_error", JSON.from(problem))
      end

      with_replay(fields, call.replay)
    LLM.Block.ToolResult(output) ->
      JSON.object({
        "type": JSON.from("tool_result"),
        "tool_use_id": JSON.from(output.tool_use_id),
        "content": JSON.from(output.content),
        "is_error": JSON.from(output.is_error),
      })
  end
end

def with_replay(fields: Map[String, JSON.Value], replay: Optional[JSON.Value]) -> JSON.Value
  case replay
    some(value) -> JSON.object(fields.put("replay", value))
    none -> JSON.object(fields)
  end
end

def decode_block(json: JSON.Value) -> Result[LLM.Block]
  replay = optional(json, "replay")
  kind = try field(json, "type")
  case kind
    "text" -> ok(LLM.Block.Text(LLM.TextPart(text: try field(json, "text"), replay: replay)))
    "thinking" -> ok(LLM.Block.Thinking(LLM.ThinkingPart(text: try field(json, "text"), replay: replay)))
    "tool_use" ->
      call = LLM.ToolCall(
        id: try field(json, "id"),
        name: try field(json, "name"),
        arguments: try field(json, "arguments"),
        input: try JSON.get(json, "input"),
        input_error: optional(json, "input_error").map { |v| JSON.string(v).unwrap_or("") },
        kind: try tool_kind_of(try field(json, "kind")),
        replay: replay,
      )

      ok(LLM.Block.ToolUse(call))
    "tool_result" ->
      output = LLM.ToolOutput(
        tool_use_id: try field(json, "tool_use_id"),
        content: try field(json, "content"),
        is_error: try JSON.bool(try JSON.get(json, "is_error")),
      )

      ok(LLM.Block.ToolResult(output))
    _ -> error("unknown block #{kind}")
  end
end

def role_of(name: String) -> Result[LLM.Role]
  case name
    "user" -> ok(LLM.Role.User)
    "assistant" -> ok(LLM.Role.Assistant)
    _ -> error("unknown role #{name}")
  end
end

def tool_kind_of(name: String) -> Result[LLM.ToolKind]
  case name
    "function" -> ok(LLM.ToolKind.Function)
    "custom" -> ok(LLM.ToolKind.Custom)
    _ -> error("unknown tool kind #{name}")
  end
end

def optional(json: JSON.Value, key: String) -> Optional[JSON.Value]
  case JSON.get(json, key)
    ok(value) -> some(value)
    error(_) -> none
  end
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
