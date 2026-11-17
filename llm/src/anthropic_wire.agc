## The Anthropic Messages wire format: the request JSON, and the `message_*` and `content_block_*` stream events folded
## into events and a response. Pure.
##
## Each content block is one block. A `thinking` block (with its `signature`) and a `redacted_thinking` one go back
## unchanged: the whole block sits in the `replay` of a `Thinking` part.

import Body from "body"
import {StopReason} from "stop_reason"
import Types from "types"

## What the events so far gave.
struct Turn
  ## The content blocks in the order they started; a block's index is its place here.
  parts: List[Part] = []
  usage: Types.Usage
  id: String = ""
  stop_reason: String = ""
  ## `message_stop` came.
  stopped: Bool = false
end

## A content block being streamed.
struct Part
  index: Int
  kind: PartKind
  pieces: List[String] = []
  id: String = ""
  name: String = ""
  signature: String = ""
  ## The `data` of a `redacted_thinking` block.
  data: String = ""
end

enum PartKind
  Text
  Thinking
  RedactedThinking
  Call
  ## A block that is no block of ours (a server tool's, say): it is left out.
  Other
end

## The state before the first event.
def new_turn() -> Turn = Turn(usage: Types.Usage())

## The message ended (`message_stop`).
def ended?(turn: Turn) -> Bool = turn.stopped

## The JSON body of a streamed call: adaptive thinking with summarized text, `effort` in `output_config`. With
## `cache`, a cache breakpoint ends the stable prefix (the system prompt, else the last tool), and the top-level one
## caches the conversation so far. No `temperature` or `seed`: API version 2026-10-21 refuses sampling settings.
## Error `llm.unsupported`: a `Custom` tool, which this API does not have, or `ToolChoice.Required`, which the current
## models (Opus 5.5, Sonnet 5.5, Fable) refuse.
def request_body(request: Types.Request) -> Result[String]
  try no_custom_tools(request)
  if request.tool_choice == Types.ToolChoice.Required
    return error("llm: anthropic takes only the auto tool choice", kind: "llm.unsupported")
  end

  body: Map[String, JSON.Value] = {
    "model": JSON.from(request.model),
    "messages": JSON.array(messages(request.messages)),
    "max_tokens": JSON.from(request.max_tokens.unwrap_or(Types.ANTHROPIC_MAX_TOKENS)),
    "stream": JSON.from(true),
    "thinking": JSON.object({"type": JSON.from("adaptive"), "display": JSON.from("summarized")}),
  }

  prefix_cached = request.cache and not request.system.empty?
  if not request.system.empty?
    body = body.put("system", JSON.array([cached(text_json(request.system), prefix_cached)]))
  end

  if not request.tools.empty?
    tools = request.tools.map { |tool| tool_json(tool) }
    if request.cache and not prefix_cached
      tools = tools.set(tools.size - 1, cached(tools.last, true))
    end

    body = body.put("tools", JSON.array(tools))
    body = body.put("tool_choice", JSON.object({"type": JSON.from("auto")}))
  end

  if request.cache
    body = body.put("cache_control", ephemeral())
  end

  for effort in option_list(request.effort)
    body = body.put("output_config", JSON.object({"effort": JSON.from(effort)}))
  end

  ok(JSON.encode(JSON.object(Body.merge_extra(body, request.extra))))
end

## Folds the `data` of one SSE event. Errors: `llm.api` (an `error` event, its type in `details`), `llm.protocol`
## (bad JSON).
def take(turn: Turn, data: String) -> Result[Types.Fold[Turn]]
  json = try protocol(JSON.parse(data))
  case text_at(json, "type")
    "message_start" -> ok(start_message(turn, json_at(json, "message").unwrap_or(JSON.object({}))))
    "content_block_start" -> ok(start_block(turn, json))
    "content_block_delta" -> ok(add_delta(turn, json))
    "message_delta" -> ok(end_message(turn, json))
    "message_stop" -> ok(fold(turn.with(stopped: true), []))
    "error" -> api_error(json)
    _ -> ok(fold(turn, []))
  end
end

## The response of a stream that ended. Error `llm.protocol`: it ended before `message_stop`.
def finish(turn: Turn) -> Result[Types.Response]
  return error("llm: the stream ended before the message did", kind: "llm.protocol") if not turn.stopped

  blocks = turn.parts.select { |p| p.kind != PartKind.Other }.map { |p| block(p) }
  message = Types.Message(role: Types.Role.Assistant, content: blocks)
  ok(Types.Response(message: message, stop_reason: stop_reason(turn.stop_reason), usage: turn.usage, id: turn.id))
end

private

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

def int_at(json: JSON.Value, key: String) -> Optional[Int]
  for value in option_list(json_at(json, key))
    case JSON.int(value)
      ok(n) -> return some(n)
      error(_) -> nil
    end
  end

  none
end

def api_error[T](json: JSON.Value) -> Result[T]
  err = json_at(json, "error").unwrap_or(json)
  kind = text_at(err, "type")
  message = "llm: the API failed in the stream: #{kind} #{text_at(err, "message")}".strip
  error(message, kind: "llm.api", details: {"type": kind})
end

def no_custom_tools(request: Types.Request) -> Result[Void]
  for tool in request.tools
    return unsupported(tool.name) if tool.kind == Types.ToolKind.Custom
  end

  for message in request.messages
    for block in message.content
      case block
        Types.Block.ToolUse(call) if call.kind == Types.ToolKind.Custom -> return unsupported(call.name)
        _ -> nil
      end
    end
  end

  ok()
end

def unsupported(name: String) -> Result[Void]
  error("llm: anthropic has no custom (freeform) tools: #{name}", kind: "llm.unsupported")
end

def ephemeral() -> JSON.Value = JSON.object({"type": JSON.from("ephemeral")})

def cached(json: JSON.Value, cache: Bool) -> JSON.Value
  return json if not cache

  case JSON.node(json)
    JSON.Node.Object(fields) -> JSON.object(fields.put("cache_control", ephemeral()))
    _ -> json
  end
end

def text_json(text: String) -> JSON.Value = JSON.object({"type": JSON.from("text"), "text": JSON.from(text)})

def tool_json(tool: Types.Tool) -> JSON.Value
  JSON.object({
    "name": JSON.from(tool.name),
    "description": JSON.from(tool.description),
    "input_schema": tool.input_schema,
  })
end

# A message left with no block (only empty text, or the thinking of another provider) is not sent.
def messages(list: List[Types.Message]) -> List[JSON.Value]
  out: List[JSON.Value] = []
  for message in list
    content = message_content(message)
    if not content.empty?
      out = out.push(JSON.object({"role": JSON.from(role(message.role)), "content": JSON.array(content)}))
    end
  end

  out
end

def role(role: Types.Role) -> String
  case role
    Types.Role.User -> "user"
    Types.Role.Assistant -> "assistant"
  end
end

# Tool results come first in a user message, as the API asks.
def message_content(message: Types.Message) -> List[JSON.Value]
  results = message.content.flat_map { |b| result_json(b) }
  results + message.content.flat_map { |b| block_json(b) }
end

def result_json(block: Types.Block) -> List[JSON.Value]
  case block
    Types.Block.ToolResult(result) ->
      fields: Map[String, JSON.Value] = {
        "type": JSON.from("tool_result"),
        "tool_use_id": JSON.from(result.tool_use_id),
        "content": JSON.from(result.content),
      }

      if result.is_error
        fields = fields.put("is_error", JSON.from(true))
      end

      [JSON.object(fields)]
    _ -> []
  end
end

# The API refuses an empty text block.
def block_json(block: Types.Block) -> List[JSON.Value]
  case block
    Types.Block.Text(part) if part.text.empty? -> []
    Types.Block.Text(part) -> [text_json(part.text)]
    Types.Block.Thinking(part) -> option_list(part.replay).select { |r| own_thinking?(r) }
    Types.Block.ToolUse(call) -> [call_json(call)]
    Types.Block.ToolResult(_) -> []
  end
end

# Thinking goes back only as this API gave it; the reasoning of another provider is dropped.
def own_thinking?(replay: JSON.Value) -> Bool
  case text_at(replay, "type")
    "thinking" -> not text_at(replay, "signature").empty?
    "redacted_thinking" -> not text_at(replay, "data").empty?
    _ -> false
  end
end

# The input as the model wrote it, when it is a JSON object.
def call_json(call: Types.ToolCall) -> JSON.Value
  input = call.input
  case JSON.parse(call.arguments)
    ok(json) if JSON.kind(json) == "object" -> input = json
    _ -> nil
  end

  JSON.object({"type": JSON.from("tool_use"), "id": JSON.from(call.id), "name": JSON.from(call.name), "input": input})
end

def start_message(turn: Turn, message: JSON.Value) -> Types.Fold[Turn]
  started = turn.with(id: text_at(message, "id"))
  case json_at(message, "usage")
    some(usage) -> fold(started.with(usage: to_usage(turn.usage, usage)), [])
    none -> fold(started, [])
  end
end

def start_block(turn: Turn, json: JSON.Value) -> Types.Fold[Turn]
  content = json_at(json, "content_block").unwrap_or(JSON.object({}))
  part = Part(index: int_at(json, "index").unwrap_or(-1), kind: part_kind(text_at(content, "type")))
  part = part.with(id: text_at(content, "id"), name: text_at(content, "name"), data: text_at(content, "data"))
  index = turn.parts.size
  started = turn.with(parts: turn.parts.push(part))
  case part.kind
    PartKind.Call ->
      fold(started, [Types.Event.ToolUseStart(Types.ToolStart(index: index, id: part.id, name: part.name))])
    PartKind.Text -> add_text(started, part.index, text_at(content, "text"), "text_delta")
    PartKind.Thinking -> add_text(started, part.index, text_at(content, "thinking"), "thinking_delta")
    _ -> fold(started, [])
  end
end

def part_kind(name: String) -> PartKind
  case name
    "text" -> PartKind.Text
    "thinking" -> PartKind.Thinking
    "redacted_thinking" -> PartKind.RedactedThinking
    "tool_use" -> PartKind.Call
    _ -> PartKind.Other
  end
end

def add_delta(turn: Turn, json: JSON.Value) -> Types.Fold[Turn]
  delta = json_at(json, "delta").unwrap_or(JSON.object({}))
  index = int_at(json, "index").unwrap_or(-1)
  kind = text_at(delta, "type")
  case kind
    "text_delta" -> add_text(turn, index, text_at(delta, "text"), kind)
    "thinking_delta" -> add_text(turn, index, text_at(delta, "thinking"), kind)
    "input_json_delta" -> add_text(turn, index, text_at(delta, "partial_json"), kind)
    "signature_delta" -> add_signature(turn, index, text_at(delta, "signature"))
    _ -> fold(turn, [])
  end
end

# A piece goes to the block of its `index`; one for a block that never started is dropped.
def add_text(turn: Turn, index: Int, text: String, kind: String) -> Types.Fold[Turn]
  case (turn.parts.find_index { |p| p.index == index })
    some(at) if not text.empty? ->
      part = turn.parts[at]
      piece = Types.Piece(index: at, text: text)
      event = Types.Event.TextDelta(piece)
      case kind
        "thinking_delta" -> event = Types.Event.ThinkingDelta(piece)
        "input_json_delta" -> event = Types.Event.ToolInputDelta(piece)
        _ -> nil
      end

      fold(turn.with(parts: turn.parts.set(at, part.with(pieces: part.pieces.push(text)))), [event])
    _ -> fold(turn, [])
  end
end

def add_signature(turn: Turn, index: Int, signature: String) -> Types.Fold[Turn]
  case (turn.parts.find_index { |p| p.index == index })
    some(at) ->
      part = turn.parts[at]
      fold(turn.with(parts: turn.parts.set(at, part.with(signature: part.signature + signature))), [])
    none -> fold(turn, [])
  end
end

def end_message(turn: Turn, json: JSON.Value) -> Types.Fold[Turn]
  delta = json_at(json, "delta").unwrap_or(JSON.object({}))
  ended = turn.with(stop_reason: text_at(delta, "stop_reason"))
  case json_at(json, "usage")
    some(usage) ->
      used = to_usage(turn.usage, usage)
      fold(ended.with(usage: used), [Types.Event.UsageUpdate(used)])
    none -> fold(ended, [])
  end
end

# The counts of `message_delta` are totals so far; a count it leaves out keeps the one of `message_start`.
def to_usage(old: Types.Usage, usage: JSON.Value) -> Types.Usage
  old.with(
    input: int_at(usage, "input_tokens").unwrap_or(old.input),
    output: int_at(usage, "output_tokens").unwrap_or(old.output),
    cache_read: int_at(usage, "cache_read_input_tokens").unwrap_or(old.cache_read),
    cache_write: int_at(usage, "cache_creation_input_tokens").unwrap_or(old.cache_write),
  )
end

def stop_reason(reason: String) -> StopReason
  case reason
    "end_turn" -> StopReason.EndTurn
    "tool_use" -> StopReason.ToolUse
    "max_tokens" -> StopReason.MaxTokens
    "stop_sequence" -> StopReason.StopSequence
    "refusal" -> StopReason.Refusal
    "pause_turn" -> StopReason.PauseTurn
    _ -> StopReason.Other(reason)
  end
end

def block(part: Part) -> Types.Block
  streamed = part.pieces.join("")
  case part.kind
    PartKind.Text -> Types.Block.Text(Types.TextPart(text: streamed))
    PartKind.Thinking ->
      replay = JSON.object({
        "type": JSON.from("thinking"),
        "thinking": JSON.from(streamed),
        "signature": JSON.from(part.signature),
      })

      Types.Block.Thinking(Types.ThinkingPart(text: streamed, replay: some(replay)))
    PartKind.RedactedThinking ->
      replay = JSON.object({"type": JSON.from("redacted_thinking"), "data": JSON.from(part.data)})
      Types.Block.Thinking(Types.ThinkingPart(text: "", replay: some(replay)))
    PartKind.Call -> Types.Block.ToolUse(tool_call(part, streamed))
    # Left out by `finish`.
    PartKind.Other -> Types.Block.Text(Types.TextPart(text: ""))
  end
end

def tool_call(part: Part, arguments: String) -> Types.ToolCall
  call = Types.ToolCall(id: part.id, name: part.name, arguments: arguments, input: JSON.object({}))
  # No arguments at all is an empty object.
  return call if arguments.strip.empty?

  case JSON.parse(arguments)
    ok(json) if JSON.kind(json) == "object" -> call.with(input: json)
    ok(json) -> call.with(input_error: some("the arguments are a JSON #{JSON.kind(json)}, not an object"))
    error(e) -> call.with(input_error: some("the arguments are not JSON: #{e.message}"))
  end
end
