## The OpenAI Responses wire format: the request JSON (input items), and the `response.*` stream events folded into
## events and a response. Pure.
##
## Each output item is one block: a `message` is `Text`, a `reasoning` item `Thinking`, a `function_call` or
## `custom_tool_call` a `ToolUse`. What goes back unchanged sits in `replay`: the message `id` (and Codex `phase`), the
## whole reasoning item (its `encrypted_content` too), the call's item `id` (`fc_…`).

import Body from "body"
import {StopReason} from "stop_reason"
import Types from "types"

## What the events so far gave.
struct Turn
  ## The output items in the order they started; a block's index is its place here.
  parts: List[Part] = []
  usage: Types.Usage
  id: String = ""
  ## `completed`, `incomplete` or `failed` once the response ended; `""` before.
  status: String = ""
  ## `incomplete_details.reason` of an incomplete response.
  reason: String = ""
end

## An output item being streamed.
struct Part
  output_index: Int
  kind: PartKind
  item_id: String
  pieces: List[String] = []
  call_id: String = ""
  name: String = ""
  ## The item as `response.output_item.done` gave it.
  item: Optional[JSON.Value] = none
  ## A message whose text is a refusal.
  refused: Bool = false
end

enum PartKind
  Text
  Thinking
  Call
  CustomCall
  ## An item this API has that is no block (a web search, say): it is left out.
  Other
end

## The state before the first event.
def new_turn() -> Turn = Turn(usage: Types.Usage())

## The response ended (`response.completed` or `response.incomplete`).
def ended?(turn: Turn) -> Bool = not turn.status.empty?

## The JSON body of a streamed call.
def request_body(request: Types.Request) -> Result[String] = body_of(request, true)

## The body of a call to Codex, which refuses `max_output_tokens`.
def codex_body(request: Types.Request) -> Result[String] = body_of(request, false)

def body_of(request: Types.Request, max_output: Bool) -> Result[String]
  body: Map[String, JSON.Value] = {
    "model": JSON.from(request.model),
    "input": JSON.array(input_items(request)),
    "stream": JSON.from(true),
  }

  if max_output and request.max_tokens.some?
    body = body.put("max_output_tokens", JSON.from(request.max_tokens.unwrap!))
  end

  if not request.system.empty?
    body = body.put("instructions", JSON.from(request.system))
  end

  if not request.tools.empty?
    body = body.put("tools", JSON.array(request.tools.map { |tool| tool_json(tool) }))
    body = body.put("tool_choice", JSON.from(tool_choice(request.tool_choice)))
  end

  for effort in option_list(request.effort)
    body = body.put("reasoning", JSON.object({"effort": JSON.from(effort)}))
  end

  for temperature in option_list(request.temperature)
    body = body.put("temperature", JSON.from(temperature))
  end

  # No `seed`: the Responses API has none.
  ok(JSON.encode(JSON.object(Body.merge_extra(body, request.extra))))
end

## Folds the `data` of one SSE event. Errors: `llm.api` (`response.failed`, an `error` event), `llm.protocol` (bad
## JSON).
def take(turn: Turn, data: String) -> Result[Types.Fold[Turn]]
  json = try protocol(JSON.parse(data))
  kind = text_at(json, "type")
  case kind
    "response.created", "response.in_progress" -> ok(fold(turn.with(id: response_id(json, turn.id)), []))
    "response.output_item.added" -> ok(add_item(turn, json))
    "response.output_text.delta" -> ok(add_piece(turn, json, PieceKind.Text))
    "response.refusal.delta" -> ok(add_piece(turn, json, PieceKind.Refusal))
    "response.reasoning_summary_part.added" -> ok(summary_break(turn, json))
    "response.reasoning_text.delta", "response.reasoning_summary_text.delta" ->
      ok(add_piece(turn, json, PieceKind.Thinking))
    "response.function_call_arguments.delta", "response.custom_tool_call_input.delta" ->
      ok(add_piece(turn, json, PieceKind.Input))
    "response.output_item.done" -> ok(done_item(turn, json))
    "response.completed", "response.incomplete" -> ok(end_response(turn, json))
    "response.failed" -> api_error(json_at(json, "response").unwrap_or(json))
    "error" -> api_error(json)
    _ -> ok(fold(turn, []))
  end
end

## The response of a stream that ended. Error `llm.protocol`: it ended before `response.completed` or
## `response.incomplete`.
def finish(turn: Turn) -> Result[Types.Response]
  return error("llm: the stream ended before the response did", kind: "llm.protocol") if turn.status.empty?

  blocks = turn.parts.select { |p| p.kind != PartKind.Other }.map { |p| block(p) }
  message = Types.Message(role: Types.Role.Assistant, content: blocks)
  ok(Types.Response(message: message, stop_reason: stop_reason(turn), usage: turn.usage, id: turn.id))
end

private

enum PieceKind
  Text
  Refusal
  Thinking
  Input
end

def fold(turn: Turn, events: List[Types.Event]) -> Types.Fold[Turn] = Types.Fold(state: turn, events: events)

def protocol[T](result: Result[T]) -> Result[T]
  case result
    ok(value) -> ok(value)
    error(e) -> error("llm: bad JSON from the API: #{e.message}", kind: "llm.protocol", cause: e)
  end
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(x) -> [x]
    none -> []
  end
end

def json_at(json: JSON.Value, key: String) -> Optional[JSON.Value]
  case JSON.get(json, key)
    ok(value) if not JSON.null?(value) -> some(value)
    _ -> none
  end
end

def text_at(json: JSON.Value, key: String) -> String
  case json_at(json, key)
    some(value) -> JSON.string(value).unwrap_or("")
    none -> ""
  end
end

def int_at(json: JSON.Value, key: String) -> Int
  case json_at(json, key)
    some(value) -> JSON.int(value).unwrap_or(0)
    none -> 0
  end
end

def response_id(json: JSON.Value, fallback: String) -> String
  for response in option_list(json_at(json, "response"))
    id = text_at(response, "id")
    return id if not id.empty?
  end

  fallback
end

def api_error[T](json: JSON.Value) -> Result[T]
  err = json_at(json, "error").unwrap_or(json)
  message = text_at(err, "message")
  code = text_at(err, "code")
  error("llm: the API failed in the stream: #{code} #{message}".strip, kind: "llm.api")
end

def tool_choice(choice: Types.ToolChoice) -> String
  case choice
    Types.ToolChoice.Auto -> "auto"
    Types.ToolChoice.Required -> "required"
  end
end

def tool_json(tool: Types.Tool) -> JSON.Value
  case tool.kind
    Types.ToolKind.Function ->
      JSON.object({
        "type": JSON.from("function"),
        "name": JSON.from(tool.name),
        "description": JSON.from(tool.description),
        "parameters": Body.provider_schema(tool.input_schema),
      })
    Types.ToolKind.Custom -> custom_tool_json(tool)
  end
end

# A custom tool with no format takes any text.
def custom_tool_json(tool: Types.Tool) -> JSON.Value
  fields: Map[String, JSON.Value] = {
    "type": JSON.from("custom"),
    "name": JSON.from(tool.name),
    "description": JSON.from(tool.description),
  }

  if JSON.encode(tool.input_schema) != "{}"
    fields = fields.put("format", tool.input_schema)
  end

  JSON.object(fields)
end

def input_items(request: Types.Request) -> List[JSON.Value]
  custom_ids = custom_call_ids(request.messages)
  stored = stored?(request.extra)
  out: List[JSON.Value] = []
  for message in request.messages
    case message.role
      Types.Role.User -> out = out + user_items(message.content, custom_ids)
      Types.Role.Assistant -> out = out + assistant_turn(message.content, stored)
    end
  end

  out
end

# The API keeps the items of a response (`store`) unless the request says `store: false`.
def stored?(extra: Map[String, JSON.Value]) -> Bool
  case extra.get("store")
    some(value) -> JSON.bool(value).unwrap_or(true)
    none -> true
  end
end

# When the API keeps the items, they go back by their ids. With `store: false` it has none of them and refuses an id
# it does not know: the items go back without their ids, a reasoning item by its `encrypted_content` (one without it
# is dropped), and calls by their `call_id`.
def assistant_turn(blocks: List[Types.Block], stored: Bool) -> List[JSON.Value]
  items = blocks.flat_map { |b| assistant_items(b) }
  return items if stored

  # A message without an id is an input message, which has no `status`.
  items.select { |i| text_at(i, "type") != "reasoning" or sealed?(i) }.map { |i| without(without(i, "id"), "status") }
end

def sealed?(item: JSON.Value) -> Bool = not text_at(item, "encrypted_content").empty?

def without(json: JSON.Value, key: String) -> JSON.Value
  case JSON.node(json)
    JSON.Node.Object(fields) -> JSON.object(fields.delete(key))
    _ -> json
  end
end

# A result answers a custom call with another item type, so the calls of the history are looked up by id.
def custom_call_ids(messages: List[Types.Message]) -> Set[String]
  ids: List[String] = []
  for message in messages
    for block in message.content
      case block
        Types.Block.ToolUse(call) if call.kind == Types.ToolKind.Custom -> ids = ids.push(call.id)
        _ -> nil
      end
    end
  end

  Set.new(ids)
end

# Each tool result is an item of its own, before the text of the same user message.
def user_items(blocks: List[Types.Block], custom_ids: Set[String]) -> List[JSON.Value]
  out: List[JSON.Value] = []
  texts: List[JSON.Value] = []
  for block in blocks
    case block
      Types.Block.ToolResult(result) -> out = out.push(output_item(result, custom_ids))
      Types.Block.Text(part) ->
        texts = texts.push(JSON.object({"type": JSON.from("input_text"), "text": JSON.from(part.text)}))
      _ -> nil
    end
  end

  return out if texts.empty?

  out.push(JSON.object({"type": JSON.from("message"), "role": JSON.from("user"), "content": JSON.array(texts)}))
end

def output_item(result: Types.ToolOutput, custom_ids: Set[String]) -> JSON.Value
  # The API has no error flag: the text says it.
  content = result.content
  if result.is_error
    content = "Error: #{content}"
  end

  kind = "function_call_output"
  if custom_ids.include?(result.tool_use_id)
    kind = "custom_tool_call_output"
  end

  JSON.object({"type": JSON.from(kind), "call_id": JSON.from(result.tool_use_id), "output": JSON.from(content)})
end

# Reasoning goes back as the item that came, less an empty `encrypted_content`; the thinking of another API is dropped.
def assistant_items(block: Types.Block) -> List[JSON.Value]
  case block
    Types.Block.Text(part) -> [assistant_message(part)]
    Types.Block.Thinking(part) ->
      option_list(part.replay).select { |item| text_at(item, "type") == "reasoning" }.map { |item| if_sealed(item) }
    Types.Block.ToolUse(call) -> [call_item(call)]
    Types.Block.ToolResult(_) -> []
  end
end

def if_sealed(item: JSON.Value) -> JSON.Value
  return item if sealed?(item)

  without(item, "encrypted_content")
end

# A message with refusal parts goes back with its parts as they came, unless its text was changed since.
def assistant_message(part: Types.TextPart) -> JSON.Value
  text = JSON.object({"type": JSON.from("output_text"), "text": JSON.from(part.text), "annotations": JSON.array([])})
  content = [text]
  for replay in option_list(part.replay)
    for kept in option_list(json_at(replay, "content"))
      parts: List[JSON.Value] = JSON.list(kept).unwrap_or([])
      if joined_text(parts) == part.text
        content = parts
      end
    end
  end

  fields: Map[String, JSON.Value] = {
    "type": JSON.from("message"),
    "role": JSON.from("assistant"),
    "content": JSON.array(content),
  }

  for replay in option_list(part.replay)
    for key in ["id", "phase", "status"]
      for value in option_list(json_at(replay, key))
        fields = fields.put(key, value)
      end
    end
  end

  JSON.object(fields)
end

# The arguments (or a custom call's input) go back as the model wrote them, with the call's item id when it has one.
def call_item(call: Types.ToolCall) -> JSON.Value
  fields: Map[String, JSON.Value] = {"call_id": JSON.from(call.id), "name": JSON.from(call.name)}
  case call.kind
    Types.ToolKind.Function ->
      arguments = call.arguments
      if arguments.empty?
        arguments = "{}"
      end

      fields = fields.put("type", JSON.from("function_call")).put("arguments", JSON.from(arguments))
    Types.ToolKind.Custom ->
      fields = fields.put("type", JSON.from("custom_tool_call")).put("input", JSON.from(call.arguments))
  end

  for replay in option_list(call.replay)
    for id in option_list(json_at(replay, "id"))
      fields = fields.put("id", id)
    end
  end

  JSON.object(fields)
end

def add_item(turn: Turn, json: JSON.Value) -> Types.Fold[Turn]
  item = json_at(json, "item").unwrap_or(JSON.object({}))
  output_index = int_at(json, "output_index")
  part = Part(output_index: output_index, kind: item_kind(text_at(item, "type")), item_id: text_at(item, "id"))
  part = part.with(call_id: text_at(item, "call_id"), name: text_at(item, "name"))
  index = turn.parts.size
  events: List[Types.Event] = []
  if part.kind == PartKind.Call or part.kind == PartKind.CustomCall
    start = Types.ToolStart(index: index, id: part.call_id, name: part.name, item_id: part.item_id)
    events = [Types.Event.ToolUseStart(start)]
  end

  fold(turn.with(parts: turn.parts.push(part)), events)
end

def item_kind(name: String) -> PartKind
  case name
    "message" -> PartKind.Text
    "reasoning" -> PartKind.Thinking
    "function_call" -> PartKind.Call
    "custom_tool_call" -> PartKind.CustomCall
    _ -> PartKind.Other
  end
end

# A piece goes to the item of its `output_index`; one for an item that never started is dropped.
def add_piece(turn: Turn, json: JSON.Value, kind: PieceKind) -> Types.Fold[Turn]
  add_text(turn, int_at(json, "output_index"), text_at(json, "delta"), kind)
end

# The summary parts of one reasoning item are paragraphs: a blank line goes between them.
def summary_break(turn: Turn, json: JSON.Value) -> Types.Fold[Turn]
  return fold(turn, []) if int_at(json, "summary_index") == 0

  add_text(turn, int_at(json, "output_index"), "\n\n", PieceKind.Thinking)
end

def add_text(turn: Turn, output_index: Int, text: String, kind: PieceKind) -> Types.Fold[Turn]
  case turn.parts.find_index { |p| p.output_index == output_index }
    some(index) ->
      part = turn.parts[index]
      return fold(turn, []) if text.empty?

      piece = Types.Piece(index: index, text: text, item_id: part.item_id)
      event = Types.Event.TextDelta(piece)
      case kind
        PieceKind.Text -> event = Types.Event.TextDelta(piece)
        PieceKind.Refusal ->
          event = Types.Event.TextDelta(piece)
          part = part.with(refused: true)
        PieceKind.Thinking -> event = Types.Event.ThinkingDelta(piece)
        PieceKind.Input -> event = Types.Event.ToolInputDelta(piece)
      end

      parts = turn.parts.set(index, part.with(pieces: part.pieces.push(text)))
      fold(turn.with(parts: parts), [event])
    none -> fold(turn, [])
  end
end

def done_item(turn: Turn, json: JSON.Value) -> Types.Fold[Turn]
  output_index = int_at(json, "output_index")
  case turn.parts.find_index { |p| p.output_index == output_index }
    some(index) ->
      fold(turn.with(parts: turn.parts.set(index, turn.parts[index].with(item: json_at(json, "item")))), [])
    none -> fold(turn, [])
  end
end

def end_response(turn: Turn, json: JSON.Value) -> Types.Fold[Turn]
  response = json_at(json, "response").unwrap_or(JSON.object({}))
  status = text_at(response, "status")
  if status.empty?
    status = "completed"
  end

  reason = ""
  for details in option_list(json_at(response, "incomplete_details"))
    reason = text_at(details, "reason")
  end

  ended = turn.with(status: status, reason: reason, id: response_id(json, turn.id))
  case json_at(response, "usage")
    some(usage) ->
      used = to_usage(usage)
      fold(ended.with(usage: used), [Types.Event.UsageUpdate(used)])
    none -> fold(ended, [])
  end
end

def to_usage(usage: JSON.Value) -> Types.Usage
  cached = 0
  for details in option_list(json_at(usage, "input_tokens_details"))
    cached = int_at(details, "cached_tokens")
  end

  reasoning = 0
  for details in option_list(json_at(usage, "output_tokens_details"))
    reasoning = int_at(details, "reasoning_tokens")
  end

  Types.Usage(
    input: int_at(usage, "input_tokens") - cached,
    output: int_at(usage, "output_tokens"),
    cache_read: cached,
    reasoning: reasoning,
  )
end

def stop_reason(turn: Turn) -> StopReason
  return incomplete_reason(turn.reason) if turn.status == "incomplete"
  return StopReason.Refusal if turn.parts.any? { |p| refused?(p) }

  return StopReason.ToolUse if turn.parts.any? { |p| p.kind == PartKind.Call or p.kind == PartKind.CustomCall }

  StopReason.EndTurn
end

def incomplete_reason(reason: String) -> StopReason
  case reason
    "max_output_tokens" -> StopReason.MaxTokens
    "content_filter" -> StopReason.Refusal
    _ -> StopReason.Other(reason)
  end
end

def block(part: Part) -> Types.Block
  streamed = part.pieces.join("")
  case part.kind
    PartKind.Text -> Types.Block.Text(Types.TextPart(text: item_text(part, streamed), replay: message_replay(part)))
    PartKind.Thinking -> Types.Block.Thinking(Types.ThinkingPart(text: streamed, replay: part.item))
    PartKind.Call -> Types.Block.ToolUse(tool_call(part, item_field(part, "arguments", streamed)))
    PartKind.CustomCall ->
      input = item_field(part, "input", streamed)
      call = Types.ToolCall(
        id: part.call_id,
        name: part.name,
        arguments: input,
        input: JSON.object({}),
        kind: Types.ToolKind.Custom,
        replay: id_replay(part),
      )

      Types.Block.ToolUse(call)
    # Left out by `finish`.
    PartKind.Other -> Types.Block.Text(Types.TextPart(text: ""))
  end
end

# The text of a message item as its `done` event gave it (a refusal part has its text in `refusal`), else as it
# streamed.
def item_text(part: Part, streamed: String) -> String
  contents = content_parts(part)
  return streamed if contents.empty?

  joined_text(contents)
end

def joined_text(contents: List[JSON.Value]) -> String
  contents.map { |c| text_at(c, "text") + text_at(c, "refusal") }.join("")
end

def content_parts(part: Part) -> List[JSON.Value]
  for item in option_list(part.item)
    for content in option_list(json_at(item, "content"))
      return JSON.list(content).unwrap_or([])
    end
  end

  []
end

def refused?(part: Part) -> Bool
  part.kind == PartKind.Text and (part.refused or content_parts(part).any? { |c| text_at(c, "type") == "refusal" })
end

def item_field(part: Part, key: String, streamed: String) -> String
  for item in option_list(part.item)
    case json_at(item, key)
      some(value) -> return JSON.string(value).unwrap_or(streamed)
      none -> nil
    end
  end

  streamed
end

# An input message with an `id` is an output message, which needs its `status` too. A message with a refusal keeps
# its parts.
def message_replay(part: Part) -> Optional[JSON.Value]
  fields: Map[String, JSON.Value] = {}
  if not part.item_id.empty?
    status = "completed"
    for item in option_list(part.item)
      if not text_at(item, "status").empty?
        status = text_at(item, "status")
      end
    end

    fields = fields.put("id", JSON.from(part.item_id)).put("status", JSON.from(status))
  end

  for item in option_list(part.item)
    for phase in option_list(json_at(item, "phase"))
      fields = fields.put("phase", phase)
    end
  end

  if refused?(part)
    fields = fields.put("content", JSON.array(replay_content(part)))
  end

  return none if fields.empty?

  some(JSON.object(fields))
end

def replay_content(part: Part) -> List[JSON.Value]
  contents = content_parts(part)
  return [JSON.object({"type": JSON.from("refusal"), "refusal": JSON.from(part.pieces.join(""))})] if contents.empty?

  contents.map { |c| content_part(c) }
end

def content_part(content: JSON.Value) -> JSON.Value
  if text_at(content, "type") == "refusal"
    return JSON.object({"type": JSON.from("refusal"), "refusal": JSON.from(text_at(content, "refusal"))})
  end

  annotations = json_at(content, "annotations").unwrap_or(JSON.array([]))
  JSON.object({
    "type": JSON.from("output_text"),
    "text": JSON.from(text_at(content, "text")),
    "annotations": annotations,
  })
end

def id_replay(part: Part) -> Optional[JSON.Value]
  return none if part.item_id.empty?

  some(JSON.object({"id": JSON.from(part.item_id)}))
end

def tool_call(part: Part, arguments: String) -> Types.ToolCall
  call = Types.ToolCall(id: part.call_id, name: part.name, arguments: arguments, input: JSON.object({}))
  call = call.with(replay: id_replay(part))
  # No arguments at all is an empty object.
  return call if arguments.strip.empty?

  case JSON.parse(arguments)
    ok(json) if JSON.kind(json) == "object" -> call.with(input: json)
    ok(json) -> call.with(input_error: some("the arguments are a JSON #{JSON.kind(json)}, not an object"))
    error(e) -> call.with(input_error: some("the arguments are not JSON: #{e.message}"))
  end
end
