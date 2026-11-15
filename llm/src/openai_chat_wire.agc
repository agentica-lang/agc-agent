## The OpenAI chat completions wire format: the request JSON, and the stream chunks folded into events and a
## response. Pure.

import Stop from "stop_reason"
import Types from "types"

## What the chunks so far gave.
struct Turn
  text: List[String] = []
  thinking: List[String] = []
  calls: List[Call] = []
  finish: Optional[String] = none
  usage: Types.Usage
  ## `data: [DONE]` came.
  done: Bool = false
end

## One chunk folded: the next state and the events it gave.
struct Step
  turn: Turn
  events: List[Types.Event]
end

## A tool call being streamed: its pieces of arguments, by the `index` of the API.
struct Call
  index: Int
  id: String
  name: String
  arguments: List[String] = []
end

## The state before the first chunk.
def new_turn() -> Turn = Turn(usage: Types.Usage())

## The JSON body of a streamed call.
def request_body(request: Types.Request) -> String
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

  JSON.encode(JSON.object(body))
end

## Folds the `data` of one SSE event. Errors: `llm.api` (an error object in the stream), `llm.protocol` (bad JSON).
def take(turn: Turn, data: String) -> Result[Step]
  return ok(Step(turn: turn.with(done: true), events: [])) if data.strip == "[DONE]"

  json = try protocol(JSON.parse(data))
  case JSON.get(json, "error")
    ok(err) -> return error("llm: the API failed in the stream: #{err}", kind: "llm.api")
    error(_) -> nil
  end

  chunk = try protocol(JSON.decode(json, Chunk))
  step = Step(turn: turn, events: [])
  for choice in chunk.choices.unwrap_or([])
    step = take_choice(step, choice)
  end

  for usage in option_list(chunk.usage)
    used = to_usage(usage)
    step = Step(turn: step.turn.with(usage: used), events: step.events.push(Types.Event.UsageUpdate(used)))
  end

  ok(step)
end

## The response of a stream that ended. Error `llm.protocol`: it ended before a `finish_reason`.
def finish(turn: Turn) -> Result[Types.Response]
  case turn.finish
    some(reason) ->
      message = Types.Message(role: Types.Role.Assistant, content: blocks(turn))
      ok(Types.Response(message: message, stop_reason: Stop.from_openai(reason), usage: turn.usage))
    none -> error("llm: the stream ended before its finish_reason", kind: "llm.protocol")
  end
end

## The models of `GET /models`, with the context of llama.cpp (`meta.n_ctx`) or `context_length` when given.
def models(body: String) -> Result[List[Types.Model]]
  list = try protocol(JSON.decode(body, ModelList))
  ok(list.data.map { |m| Types.Model(id: m.id, context: context_of(m)) })
end

private

struct Chunk
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
end

struct PromptDetails
  cached_tokens: Optional[Int]
end

struct ModelList
  data: List[WireModel]
end

struct WireModel
  id: String
  context_length: Optional[Int]
  meta: Optional[ModelMeta]
end

struct ModelMeta
  n_ctx: Optional[Int]
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
      Types.Block.Text(text) -> texts = texts.push(text)
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
      Types.Block.Text(text) -> texts = texts.push(text)
      Types.Block.ToolUse(call) -> calls = calls.push(call_json(call))
      _ -> nil
    end
  end

  fields: Map[String, JSON.Value] = {"role": JSON.from("assistant")}
  if texts.empty?
    fields = fields.put("content", JSON.null())
  else
    fields = fields.put("content", JSON.from(texts.join("\n")))
  end

  if not calls.empty?
    fields = fields.put("tool_calls", JSON.array(calls))
  end

  JSON.object(fields)
end

def call_json(call: Types.ToolCall) -> JSON.Value
  function = JSON.object({"name": JSON.from(call.name), "arguments": JSON.from(arguments_text(call.input))})
  JSON.object({"id": JSON.from(call.id), "type": JSON.from("function"), "function": function})
end

# An input kept as raw text goes back as that text.
def arguments_text(input: JSON.Value) -> String
  case JSON.string(input)
    ok(raw) -> raw
    error(_) -> JSON.encode(input)
  end
end

def role_text(role: String, text: String) -> JSON.Value
  JSON.object({"role": JSON.from(role), "content": JSON.from(text)})
end

def take_choice(step: Step, choice: Choice) -> Step
  turn = step.turn
  events = step.events
  for delta in option_list(choice.delta)
    for text in option_list(delta.reasoning_content)
      if not text.empty?
        turn = turn.with(thinking: turn.thinking.push(text))
        events = events.push(Types.Event.ThinkingDelta(text))
      end
    end

    for text in option_list(delta.content)
      if not text.empty?
        turn = turn.with(text: turn.text.push(text))
        events = events.push(Types.Event.TextDelta(text))
      end
    end

    for call in delta.tool_calls.unwrap_or([])
      taken = take_call(Step(turn: turn, events: events), call)
      turn = taken.turn
      events = taken.events
    end
  end

  for reason in option_list(choice.finish_reason)
    turn = turn.with(finish: some(reason))
  end

  Step(turn: turn, events: events)
end

def take_call(step: Step, delta: CallDelta) -> Step
  turn = step.turn
  events = step.events
  index = delta.index.unwrap_or(0)
  function = delta.function.unwrap_or(FunctionDelta(name: none, arguments: none))
  call = Call(index: index, id: "", name: "")
  case (turn.calls.find { |c| c.index == index })
    ok(found) -> call = found
    error(_) ->
      # Some APIs leave out the id; one is made from the index so results can still point at the call.
      call = Call(index: index, id: delta.id.unwrap_or("call_#{index}"), name: function.name.unwrap_or(""))
      events = events.push(Types.Event.ToolUseStart(call.id, call.name))
  end

  piece = function.arguments.unwrap_or("")
  if not piece.empty?
    call = call.with(arguments: call.arguments.push(piece))
    events = events.push(Types.Event.ToolInputDelta(call.id, piece))
  end

  Step(turn: turn.with(calls: put_call(turn.calls, call)), events: events)
end

def put_call(calls: List[Call], call: Call) -> List[Call]
  return calls.push(call) if (not calls.any? { |c| c.index == call.index })

  calls.map { |c| replaced(c, call) }
end

def replaced(old: Call, call: Call) -> Call
  return call if old.index == call.index

  old
end

def to_usage(usage: WireUsage) -> Types.Usage
  cached = 0
  for details in option_list(usage.prompt_tokens_details)
    cached = details.cached_tokens.unwrap_or(0)
  end

  Types.Usage(input: usage.prompt_tokens - cached, output: usage.completion_tokens, cache_read: cached)
end

def blocks(turn: Turn) -> List[Types.Block]
  out: List[Types.Block] = []
  if not turn.thinking.empty?
    out = out.push(Types.Block.Thinking(turn.thinking.join(""), JSON.null()))
  end

  if not turn.text.empty?
    out = out.push(Types.Block.Text(turn.text.join("")))
  end

  out + turn.calls.map { |c| Types.Block.ToolUse(Types.ToolCall(id: c.id, name: c.name, input: input_of(c))) }
end

# No arguments is an empty object; anything that is not a JSON object stays raw text for the caller to refuse.
def input_of(call: Call) -> JSON.Value
  raw = call.arguments.join("")
  return JSON.object({}) if raw.strip.empty?

  case JSON.parse(raw)
    ok(json) if JSON.kind(json) == "object" -> json
    _ -> JSON.from(raw)
  end
end

def context_of(model: WireModel) -> Optional[Int]
  case model.context_length
    some(n) -> some(n)
    none -> model.meta.map { |meta| meta.n_ctx }.unwrap_or(none)
  end
end
