## The file of a session in the data folder: JSON Lines, appended as the session goes. The first line is the session;
## then one line per event but the deltas (with its id), per block of ids the deltas take, per user message, per
## round of the model's history and per answer a client draws. A record is one line, written whole or cut by a crash:
## loading skips a line that does not parse or decode, and `reopen` ends a line that a crash left open.
##
## The file keeps the events and messages in plain text, tool output and file contents included, until it is removed.

import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import Compaction from "compaction"

EXTENSION = ".jsonl"
MAX_LINE_BYTES = 16_777_216
MAX_WRITE_BYTES = 1_048_576

struct Header
  id: String
  cwd: String
  model: String
  created_ms: Int
  ## The system prompt of every call of the session, so a cache of its prefix stays valid after a restart.
  system: Optional[String] = none
  ## The model API of the session, by its `AGC_AGENT_API` name; none in a file made before the choice.
  api: Optional[String] = none
end

struct Logged
  id: Int
  event: Protocol.Event
end

## What a file holds. `open_end` is true when its last line has no end (a crash cut it): `reopen` before an append.
## `users` counts the turns that began, and `open_user` is true when the last one has no `turn_started`.
struct Saved
  header: Header
  events: List[Logged]
  history: List[LLM.Message]
  shown: List[Protocol.Message]
  skipped: Int
  open_end: Bool
  users: Int = 0
  open_user: Bool = false
  ## After the last saved event, the ids up to this one may have gone to events that are not saved; 0 when none.
  reserved: Int = 0
  ## The answer of the last turn so far at its last compaction, which may have folded part of it.
  folded: Optional[Folded] = none
end

## The answer texts of a turn when it was compacted, and the size of the history after: the texts of the messages
## from there on follow them.
struct Folded
  texts: List[String]
  at: Int
end

def file_of(dir: String, id: String) -> String = "#{dir}/#{id}#{EXTENSION}"

## Creates the file of a new session (0600); its path.
def create(dir: String, header: Header) -> Result[String]
  path = file_of(dir, header.id)
  handle = try File.open(path, "create_private")
  fields = {
    "type": JSON.from("session"),
    "id": JSON.from(header.id),
    "cwd": JSON.from(header.cwd),
    "model": JSON.from(header.model),
    "created_ms": JSON.from(header.created_ms),
    "system": JSON.from(header.system),
    "api": JSON.from(header.api),
  }

  written = File.write(handle, try line(fields))
  try File.close(handle)
  try written
  ok(path)
end

def append_event(path: String, logged: Logged) -> Result[Void]
  data = try JSON.parse(Protocol.encode_event(logged.event))
  name = Protocol.event_name(logged.event)
  append(path, {"type": JSON.from("event"), "id": JSON.from(logged.id), "name": JSON.from(name), "data": data})
end

## The message that starts a turn: shown, and the first of the turn's history.
def append_user(path: String, text: String) -> Result[Void]
  append(path, {"type": JSON.from("user"), "text": JSON.from(text)})
end

## The messages a round added to the history, in one record so that a call never goes without its result.
def append_messages(path: String, messages: List[LLM.Message]) -> Result[Void]
  append(path, {"type": JSON.from("messages"), "messages": JSON.array(messages.map { |m| encode_message(m) })})
end

## Ids up to `until` may go to events that are not saved (deltas), so a restart starts after them. A saved event
## after it ends the reservation.
def append_reserved(path: String, until: Int) -> Result[Void]
  append(path, {"type": JSON.from("ids"), "until": JSON.from(until)})
end

## A compaction of the history as the records before it left it, with the answer texts of the running turn so far.
def append_compaction(path: String, compaction: Compaction.Compaction, answer: List[String]) -> Result[Void]
  append(
    path,
    {
      "type": JSON.from("compaction"),
      "from": JSON.from(compaction.from),
      "to": JSON.from(compaction.to),
      "summary": JSON.from(compaction.summary),
      "answer": JSON.from(answer),
    },
  )
end

## The answer of a turn, as a client draws it.
def append_answer(path: String, text: String) -> Result[Void]
  append(path, {"type": JSON.from("answer"), "text": JSON.from(text)})
end

def reopen(path: String) -> Result[Void] = write(path, "\n")

## The first line of a file: the session, without reading the rest.
def header(path: String) -> Result[Header]
  File.open(path, "read") do |handle| decode_header(try JSON.parse(try File.read_line(handle))) end
end

def load(path: String) -> Result[Saved]
  lines = try File.foreach(path, MAX_LINE_BYTES).to_a
  size = (try File.stat(path)).size_bytes
  header: Optional[Header] = none
  saved = Saved(
    header: Header(id: "", cwd: "", model: "", created_ms: 0),
    events: [],
    history: [],
    shown: [],
    skipped: 0,
    open_end: size != lines.map { |text| text.bytesize + 1 }.sum,
  )

  for text in lines
    next if text.empty?

    case JSON.parse(text)
      ok(json) if header.none? -> header = some(try decode_header(json))
      ok(json) ->
        case added(saved, json)
          ok(next_saved) -> saved = next_saved
          error(_) -> saved = saved.with(skipped: saved.skipped + 1)
        end

      error(_) -> saved = saved.with(skipped: saved.skipped + 1)
    end
  end

  case header
    some(h) -> ok(saved.with(header: h))
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

# A line longer than a load reads is refused.
def line(fields: Map[String, JSON.Value]) -> Result[String]
  text = "#{JSON.encode(JSON.object(fields))}\n"
  return error("a record of #{text.bytesize} bytes is over #{MAX_LINE_BYTES}") if text.bytesize > MAX_LINE_BYTES

  ok(text)
end

def append(path: String, fields: Map[String, JSON.Value]) -> Result[Void] = write(path, try line(fields))

def write(path: String, text: String) -> Result[Void]
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

def decode_header(json: JSON.Value) -> Result[Header]
  return error("the first record is not the session") if try field(json, "type") != "session"

  ok(
    Header(
      id: try field(json, "id"),
      cwd: try field(json, "cwd"),
      model: try field(json, "model"),
      created_ms: try JSON.int(try JSON.get(json, "created_ms")),
      system: optional_string(json, "system"),
      api: optional_string(json, "api"),
    ),
  )
end

def added(saved: Saved, json: JSON.Value) -> Result[Saved]
  kind = try field(json, "type")
  case kind
    "event" ->
      event = try Protocol.decode_event(try field(json, "name"), JSON.encode(try JSON.get(json, "data")))
      logged = Logged(id: try JSON.int(try JSON.get(json, "id")), event: event)
      started = Protocol.event_kind(event) == Protocol.EventKind.TurnStarted
      ok(saved.with(events: saved.events.push(logged), open_user: saved.open_user and not started, reserved: 0))
    "user" ->
      text = try field(json, "text")
      message = LLM.Message(role: LLM.Role.User, content: [LLM.Block.Text(LLM.TextPart(text: text))])
      shown = Protocol.Message(role: Protocol.Role.User, text: text)
      users = saved.users + 1
      ok(
        saved.with(
          history: saved.history.push(message),
          shown: saved.shown.push(shown),
          users: users,
          open_user: true,
          folded: none,
        ),
      )
    "messages" ->
      messages: List[LLM.Message] = []
      for item in try JSON.list(try JSON.get(json, "messages"))
        messages = messages.push(try decode_message(item))
      end

      ok(saved.with(history: saved.history + messages))
    "compaction" ->
      compaction = Compaction.Compaction(
        from: try JSON.int(try JSON.get(json, "from")),
        to: try JSON.int(try JSON.get(json, "to")),
        summary: try field(json, "summary"),
      )

      return error("a compaction outside the history") if compaction.to > saved.history.size

      history = Compaction.apply(saved.history, compaction)
      folded = saved.folded
      # An `answer` that is missing or not a list of texts leaves the answer as it was.
      for texts in answer_texts(json)
        folded = some(Folded(texts: texts, at: history.size))
      end

      ok(saved.with(history: history, folded: folded))
    "ids" -> ok(saved.with(reserved: try JSON.int(try JSON.get(json, "until"))))
    "answer" ->
      shown = Protocol.Message(role: Protocol.Role.Assistant, text: try field(json, "text"))
      ok(saved.with(shown: saved.shown.push(shown)))
    _ -> error("unknown record #{kind}")
  end
end

def answer_texts(json: JSON.Value) -> List[List[String]]
  case JSON.get(json, "answer")
    ok(value) ->
      case JSON.decode(value, List[String])
        ok(texts) -> [texts]
        error(_) -> []
      end

    error(_) -> []
  end
end

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

def optional_string(json: JSON.Value, key: String) -> Optional[String]
  case JSON.string(JSON.get(json, key).unwrap_or(JSON.null()))
    ok(text) -> some(text)
    error(_) -> none
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
