## The OpenAI chat completions wire format: the request JSON, and the stream chunks folded into events and a
## response. Pure.

import Body from "body"
import {StopReason} from "stop_reason"
import Types from "types"

## What the chunks so far gave.
struct Turn
  ## The blocks of the answer in the order they started; a block's index is its place here.
  parts: List[Part] = []
  finish: Optional[String] = none
  usage: Types.Usage
  id: String = ""
  ## `data: [DONE]` came.
  done: Bool = false
end

## One chunk folded: the next state and the events it gave.
struct Step
  turn: Turn
  events: List[Types.Event]
end

## A block being streamed.
struct Part
  kind: PartKind
  pieces: List[String] = []
  ## A tool call: the `index` of the API (`index:N`), else its id (`id:X`).
  key: String = ""
  call_id: String = ""
  name: String = ""
end

enum PartKind
  Text
  Thinking
  Call
end

## The state before the first chunk.
def new_turn() -> Turn = Turn(usage: Types.Usage())

## The JSON body of a streamed call. Error `llm.unsupported`: a `Custom` tool, which only Responses has.
def request_body(request: Types.Request) -> Result[String]
  try check_custom(request)
  body: Map[String, JSON.Value] = {
    "model": JSON.from(request.model),
    "messages": JSON.array(messages(request)),
    "max_tokens": JSON.from(request.max_tokens),
    "stream": JSON.from(true),
    "stream_options": JSON.object({"include_usage": JSON.from(true)}),
  }

  if not request.tools.empty?
    body = body.put("tools", JSON.array(request.tools.map { |tool| tool_json(tool) }))
    body = body.put("tool_choice", JSON.from(tool_choice(request.tool_choice)))
  end

  for effort in option_list(request.effort)
    body = body.put("reasoning_effort", JSON.from(effort))
  end

  for temperature in option_list(request.temperature)
    body = body.put("temperature", JSON.from(temperature))
  end

  for seed in option_list(request.seed)
    body = body.put("seed", JSON.from(seed))
  end

  ok(JSON.encode(JSON.object(Body.merge_extra(body, request.extra))))
end

## Folds the `data` of one SSE event. Errors: `llm.api` (an error object in the stream), `llm.protocol` (bad JSON).
def take(turn: Turn, data: String) -> Result[Types.Fold[Turn]]
  step = try take_step(turn, data)
  ok(Types.Fold(state: step.turn, events: step.events))
end

## The stream sent `data: [DONE]`.
def ended?(turn: Turn) -> Bool = turn.done

## The response of a stream that ended. Error `llm.protocol`: it ended before a `finish_reason`.
def finish(turn: Turn) -> Result[Types.Response]
  case turn.finish
    some(reason) ->
      message = Types.Message(role: Types.Role.Assistant, content: turn.parts.map { |p| block(p) })
      ok(Types.Response(message: message, stop_reason: stop_reason(reason), usage: turn.usage, id: turn.id))
    none -> error("llm: the stream ended before its finish_reason", kind: "llm.protocol")
  end
end

private

struct Chunk
  id: Optional[String]
  choices: Optional[List[Choice]]
  usage: Optional[WireUsage]
end

struct Choice
  delta: Optional[Delta]
  finish_reason: Optional[String]
end

struct Delta
  content: Optional[String]
  reasoning_content: Optional[String]
  tool_calls: Optional[List[CallDelta]]
end

struct CallDelta
  index: Optional[Int]
  id: Optional[String]
  function: Optional[FunctionDelta]
end

struct FunctionDelta
  name: Optional[String]
  arguments: Optional[String]
end

struct WireUsage
  prompt_tokens: Int
  completion_tokens: Int
  prompt_tokens_details: Optional[PromptDetails]
  completion_tokens_details: Optional[CompletionDetails]
end

struct PromptDetails
  cached_tokens: Optional[Int]
end

struct CompletionDetails
  reasoning_tokens: Optional[Int]
end

def take_step(turn: Turn, data: String) -> Result[Step]
  return ok(Step(turn: turn.with(done: true), events: [])) if data.strip == "[DONE]"

  json = try protocol(JSON.parse(data))
  case JSON.get(json, "error")
    ok(err) -> return error("llm: the API failed in the stream: #{err}", kind: "llm.api")
    error(_) -> nil
  end

  chunk = try protocol(JSON.decode(json, Chunk))
  step = Step(turn: turn.with(id: chunk.id.unwrap_or(turn.id)), events: [])
  for choice in chunk.choices.unwrap_or([])
    step = take_choice(step, choice)
  end

  for usage in option_list(chunk.usage)
    used = to_usage(usage)
    step = Step(turn: step.turn.with(usage: used), events: step.events.push(Types.Event.UsageUpdate(used)))
  end

  ok(step)
end

def stop_reason(name: String) -> StopReason
  case name
    "stop" -> StopReason.EndTurn
    "tool_calls", "function_call" -> StopReason.ToolUse
    "length" -> StopReason.MaxTokens
    "content_filter" -> StopReason.Refusal
    _ -> StopReason.Other(name)
  end
end

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

def tool_choice(choice: Types.ToolChoice) -> String
  case choice
    Types.ToolChoice.Auto -> "auto"
    Types.ToolChoice.Required -> "required"
  end
end

def tool_json(tool: Types.Tool) -> JSON.Value
  function = JSON.object({
    "name": JSON.from(tool.name),
    "description": JSON.from(tool.description),
    "parameters": tool.input_schema,
  })

  JSON.object({"type": JSON.from("function"), "function": function})
end

def messages(request: Types.Request) -> List[JSON.Value]
  out: List[JSON.Value] = []
  if not request.system.empty?
    out = out.push(role_text("system", request.system))
  end

  for message in request.messages
    case message.role
      Types.Role.User -> out = out + user_messages(message.content)
      Types.Role.Assistant -> out = out.push(assistant_message(message.content))
    end
  end

  out
end

# Each tool result is a message of its own, before the text of the same user message.
def user_messages(blocks: List[Types.Block]) -> List[JSON.Value]
  out: List[JSON.Value] = []
  texts: List[String] = []
  for block in blocks
    case block
      Types.Block.ToolResult(result) -> out = out.push(tool_message(result))
      Types.Block.Text(part) -> texts = texts.push(part.text)
      _ -> nil
    end
  end

  return out if texts.empty?

  out.push(role_text("user", texts.join("\n")))
end

def tool_message(result: Types.ToolOutput) -> JSON.Value
  # The API has no error flag: the text says it.
  content = result.content
  if result.is_error
    content = "Error: #{content}"
  end

  JSON.object({
    "role": JSON.from("tool"),
    "tool_call_id": JSON.from(result.tool_use_id),
    "content": JSON.from(content),
  })
end

# Thinking is not sent back: the chat completions API takes no reasoning in a request.
def assistant_message(blocks: List[Types.Block]) -> JSON.Value
  texts: List[String] = []
  calls: List[JSON.Value] = []
  for block in blocks
    case block
      Types.Block.Text(part) -> texts = texts.push(part.text)
      Types.Block.ToolUse(call) -> calls = calls.push(call_json(call))
      _ -> nil
    end
  end

  fields: Map[String, JSON.Value] = {"role": JSON.from("assistant")}
  if texts.empty?
    fields = fields.put("content", JSON.null())
  else
    fields = fields.put("content", JSON.from(texts.join("")))
  end

  if not calls.empty?
    fields = fields.put("tool_calls", JSON.array(calls))
  end

  JSON.object(fields)
end

# The arguments go back as the model wrote them, so the prompt prefix (and its cache) stays the same.
def call_json(call: Types.ToolCall) -> JSON.Value
  arguments = call.arguments
  if arguments.empty?
    arguments = "{}"
  end

  function = JSON.object({"name": JSON.from(call.name), "arguments": JSON.from(arguments)})
  JSON.object({"id": JSON.from(call.id), "type": JSON.from("function"), "function": function})
end

# Chat completions streams no freeform calls, so a `Custom` tool or call is refused before anything is sent.
def check_custom(request: Types.Request) -> Result[Void]
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
  error("llm: openai_chat has no custom (freeform) tools: #{name}", kind: "llm.unsupported")
end

def role_text(role: String, text: String) -> JSON.Value
  JSON.object({"role": JSON.from(role), "content": JSON.from(text)})
end

def take_choice(step: Step, choice: Choice) -> Step
  result = step
  for delta in option_list(choice.delta)
    for text in option_list(delta.reasoning_content)
      result = take_text(result, PartKind.Thinking, text)
    end

    for text in option_list(delta.content)
      result = take_text(result, PartKind.Text, text)
    end

    for call in delta.tool_calls.unwrap_or([])
      result = take_call(result, call)
    end
  end

  for reason in option_list(choice.finish_reason)
    result = result.with(turn: result.turn.with(finish: some(reason)))
  end

  result
end

# The API streams one text and one reasoning: each is one block, placed where it first came.
def take_text(step: Step, kind: PartKind, text: String) -> Step
  return step if text.empty?

  parts = step.turn.parts
  index = parts.find_index { |p| p.kind == kind }.unwrap_or(parts.size)
  part = Part(kind: kind)
  if index < parts.size
    part = parts[index]
  end

  piece = Types.Piece(index: index, text: text)
  event = Types.Event.TextDelta(piece)
  if kind == PartKind.Thinking
    event = Types.Event.ThinkingDelta(piece)
  end

  turn = step.turn.with(parts: put_part(parts, index, part.with(pieces: part.pieces.push(text))))
  Step(turn: turn, events: step.events.push(event))
end

# A call is found by its `index`; an API that sends none (whole calls, as Gemini's) by its id; a piece with neither
# goes on with the last call.
def take_call(step: Step, delta: CallDelta) -> Step
  parts = step.turn.parts
  function = delta.function.unwrap_or(FunctionDelta(name: none, arguments: none))
  key = call_key(parts, delta)
  events = step.events
  index = parts.find_index { |p| p.kind == PartKind.Call and p.key == key }.unwrap_or(parts.size)
  part = Part(kind: PartKind.Call)
  if index < parts.size
    part = parts[index]
  else
    # Some APIs leave out the id; one is made from the place so a result can still point at the call.
    part = part.with(key: key, call_id: delta.id.unwrap_or("call_#{index}"), name: function.name.unwrap_or(""))
    events = events.push(Types.Event.ToolUseStart(Types.ToolStart(index: index, id: part.call_id, name: part.name)))
  end

  piece = function.arguments.unwrap_or("")
  if not piece.empty?
    part = part.with(pieces: part.pieces.push(piece))
    events = events.push(Types.Event.ToolInputDelta(Types.Piece(index: index, text: piece)))
  end

  Step(turn: step.turn.with(parts: put_part(parts, index, part)), events: events)
end

def call_key(parts: List[Part], delta: CallDelta) -> String
  case delta.index
    some(i) -> return "index:#{i}"
    none -> nil
  end

  case delta.id
    some(id) -> return "id:#{id}"
    none -> nil
  end

  calls = parts.select { |p| p.kind == PartKind.Call }
  return "index:0" if calls.empty?

  calls.last.key
end

def put_part(parts: List[Part], index: Int, part: Part) -> List[Part]
  return parts.push(part) if index == parts.size

  parts.set(index, part)
end

def to_usage(usage: WireUsage) -> Types.Usage
  cached = 0
  for details in option_list(usage.prompt_tokens_details)
    cached = details.cached_tokens.unwrap_or(0)
  end

  reasoning = 0
  for details in option_list(usage.completion_tokens_details)
    reasoning = details.reasoning_tokens.unwrap_or(0)
  end

  Types.Usage(
    input: usage.prompt_tokens - cached,
    output: usage.completion_tokens,
    cache_read: cached,
    reasoning: reasoning,
  )
end

def block(part: Part) -> Types.Block
  text = part.pieces.join("")
  case part.kind
    PartKind.Text -> Types.Block.Text(Types.TextPart(text: text))
    PartKind.Thinking -> Types.Block.Thinking(Types.ThinkingPart(text: text))
    PartKind.Call -> Types.Block.ToolUse(tool_call(part.call_id, part.name, text))
  end
end

def tool_call(id: String, name: String, arguments: String) -> Types.ToolCall
  call = Types.ToolCall(id: id, name: name, arguments: arguments, input: JSON.object({}))
  # No arguments at all is an empty object.
  return call if arguments.strip.empty?

  case JSON.parse(arguments)
    ok(json) if JSON.kind(json) == "object" -> call.with(input: json)
    ok(json) -> call.with(input_error: some("the arguments are a JSON #{JSON.kind(json)}, not an object"))
    error(e) -> call.with(input_error: some("the arguments are not JSON: #{e.message}"))
  end
end
