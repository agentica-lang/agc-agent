## One turn of the agent: the model answers, the tools it calls run (after an approval when they ask), their results go
## back in one user message, and so on until the model ends the turn, a limit stops it or the loop guard does.

import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import CodeMode from "code_mode"
import Compaction from "compaction"
import Tools from "tools"

MAX_ROUNDS = 50
## The provider whose models are offered `apply_patch`, as a custom tool.
RESPONSES = "openai_responses"
SAME_ROUNDS = 3
DENIED_BY_RULE = "denied by a rule of the config"
DENIED_BY_USER = "the user denied this call"

## How a turn reaches its session. `approve` waits for the answer; `commit` gets the history after each finished
## round, so a stopped turn keeps no unfinished tool call. `compacted` gets a compaction of the history it committed,
## and `window` the model's window once the turn asked the provider for it (-1 when it does not say).
struct Link
  emit: Fn[Protocol.Event, Void]
  approve: Fn[Ask, Protocol.Decision]
  commit: Fn[List[LLM.Message], Void]
  compacted: Fn[Compaction.Compaction, Void]
  window: Fn[Int, Void]
end

## A call that waits for an approval. `allow_session` allows the same `tool` on the same `target` again.
struct Ask
  call_id: String
  tool: String
  target: String
  detail: String
end

struct Turn
  id: String
  provider: LLM.Provider
  model: String
  system: String
  history: List[LLM.Message]
  text: String
  ctx: Tools.Context
  link: Link
  ## Fields of every request in the format of the API.
  extra: Map[String, JSON.Value] = {}
  ## `window` 0 asks the provider for it.
  compaction: Compaction.Settings
  ## The context of the session's last call.
  last_context: Int = 0
  max_rounds: Int = MAX_ROUNDS
  ## Adds `run_script`, which calls the tools from a Python script.
  code_mode: Optional[CodeMode.Settings] = none
end

struct Outcome
  history: List[LLM.Message]
  reason: Protocol.StopReason
end

def run(given: Turn) -> Outcome
  turn = given.with(compaction: given.compaction.with(window: known_window(given)))
  messages = turn.history.push(LLM.Message(role: LLM.Role.User, content: [text_block(turn.text)]))
  turn.link.commit.call(messages)
  folded = compacted(turn, turn.last_context, Folded(messages: messages, on: true))
  messages = folded.messages
  last_round = ""
  same = 0
  for _round in 1..turn.max_rounds
    called = call_model(turn, messages)
    response = called.unwrap_or(EMPTY)
    case called
      ok(_) -> nil
      error(e) ->
        turn.link.emit.call(Protocol.Event.Error(Protocol.Failure(kind: e.kind, message: e.message)))
        return Outcome(history: messages, reason: Protocol.StopReason.Other("error"))
    end

    if response.stop_reason != LLM.StopReason.ToolUse
      messages = messages.push(without_calls(response.message))
      turn.link.commit.call(messages)
      return Outcome(history: messages, reason: stop_reason(response.stop_reason))
    end

    calls = tool_calls(response.message)
    results = calls.map { |call| run_call(turn, call) }
    messages = messages + [response.message, LLM.Message(role: LLM.Role.User, content: results)]
    turn.link.commit.call(messages)
    context = response.usage.input + response.usage.cache_read + response.usage.cache_write
    folded = compacted(turn, context, folded.with(messages: messages))
    messages = folded.messages
    this_round = JSON.encode(JSON.from([calls.map { |c| "#{c.name} #{c.arguments}" }, results.map { |r| text_of(r) }]))
    same = same_count(this_round, last_round, same)
    last_round = this_round
    return Outcome(history: messages, reason: Protocol.StopReason.LoopGuard) if same >= SAME_ROUNDS
  end

  Outcome(history: messages, reason: Protocol.StopReason.LoopGuard)
end

def text_block(text: String) -> LLM.Block = LLM.Block.Text(LLM.TextPart(text: text))

## The text of the model's blocks, for the history a client draws.
def assistant_text(message: LLM.Message) -> String = message.content.map { |b| text_of(b) }.join("")

private

EMPTY = LLM.Response(
  message: LLM.Message(role: LLM.Role.Assistant, content: []),
  stop_reason: LLM.StopReason.EndTurn,
  usage: LLM.Usage(),
)

struct Folded
  messages: List[LLM.Message]
  # False once a summary failed in this turn, or a fold left the context past the limit.
  on: Bool
  # A fold happened and no call measured the context since.
  just: Bool = false
end

# The session keeps a window once the API answered; after a failed request a later turn asks again.
def known_window(turn: Turn) -> Int
  return turn.compaction.window if turn.compaction.window != 0

  case Compaction.window(turn.provider, turn.model, turn.compaction)
    ok(tokens) ->
      turn.link.window.call(tokens)
      if tokens < 0
        message = "the API does not give the model's window: no compaction (set FINN_CONTEXT_WINDOW)"
        turn.link.emit.call(Protocol.Event.Error(Protocol.Failure(kind: Compaction.KIND_NO_WINDOW, message: message)))
      end

      tokens
    error(_) -> 0
  end
end

# Past the part of the window the settings give, the history from the first task to the running turn becomes a
# summary. A summary that fails is an `error` event, and the turn tries no more; so is a fold after which the next call
# is still past the limit, so that every round does not fold again.
def compacted(turn: Turn, context: Int, folded: Folded) -> Folded
  return folded if not folded.on

  due = Compaction.due?(turn.compaction, context)
  return folded.with(just: false) if not due

  if folded.just
    message = "the compacted history is still past the limit: no more compaction in this turn"
    turn.link.emit.call(Protocol.Event.Error(Protocol.Failure(kind: Compaction.KIND_FAILED, message: message)))
    return folded.with(on: false, just: false)
  end

  for span in option_list(Compaction.span(folded.messages))
    case Compaction.summarize(turn.provider, turn.compaction, folded.messages, span)
      ok(compaction) ->
        turn.link.compacted.call(compaction)
        return folded.with(messages: Compaction.apply(folded.messages, compaction), just: true)
      error(e) ->
        message = "the history was not compacted: #{e.message}"
        turn.link.emit.call(Protocol.Event.Error(Protocol.Failure(kind: Compaction.KIND_FAILED, message: message)))
        return folded.with(on: false)
    end
  end

  folded
end

def call_model(turn: Turn, messages: List[LLM.Message]) -> Result[LLM.Response]
  tools = offered(turn).map { |t| LLM.Tool(name: t.name, description: t.description, input_schema: t.input_schema) }
  if turn.provider.name == RESPONSES
    patch = Tools.patch()
    grammar = Tools.patch_grammar()
    tools = tools.push(
      LLM.Tool(name: patch.name, description: patch.description, input_schema: grammar, kind: LLM.ToolKind.Custom),
    )
  end

  request = LLM.Request(model: turn.model, system: turn.system, messages: messages, tools: tools, extra: turn.extra)
  stream = try LLM.stream(turn.provider, request)
  while true
    case stream.events.recv(60000)
      ok(LLM.Event.TextDelta(piece)) ->
        turn.link.emit.call(Protocol.Event.TextDelta(Protocol.TextDelta(text: piece.text)))
      ok(LLM.Event.ThinkingDelta(piece)) ->
        turn.link.emit.call(Protocol.Event.ThinkingDelta(Protocol.ThinkingDelta(text: piece.text)))
      ok(_) -> next
      error(_) -> break if stream.events.closed?
    end
  end

  response = try LLM.response(stream)
  turn.link.emit.call(Protocol.Event.Usage(usage(response.usage)))
  ok(response)
end

def usage(u: LLM.Usage) -> Protocol.Usage
  Protocol.Usage(
    input: u.input,
    output: u.output,
    cache_read: u.cache_read,
    cache_write: u.cache_write,
    context: u.input + u.cache_read + u.cache_write,
  )
end

def offered(turn: Turn) -> List[Tools.Tool]
  base = Tools.all()
  for _settings in option_list(turn.code_mode)
    return base.push(CodeMode.spec(base))
  end

  base
end

def run_call(turn: Turn, call: LLM.ToolCall) -> LLM.Block
  output = noticed_run(turn, with_input(call))
  LLM.Block.ToolResult(LLM.ToolOutput(tool_use_id: call.id, content: output.text, is_error: output.is_error))
end

# A custom tool's call has its text as `input`, the field its tool reads.
def with_input(call: LLM.ToolCall) -> LLM.ToolCall
  return call if call.kind != LLM.ToolKind.Custom

  call.with(input: JSON.object({"input": JSON.from(call.arguments)}))
end

# Runs the call between its `tool_started` and `tool_finished` events.
def noticed_run(turn: Turn, call: LLM.ToolCall) -> Tools.Output
  summary = target(turn, call).unwrap_or(call.name)
  turn.link.emit.call(
    Protocol.Event.ToolStarted(Protocol.ToolStarted(call_id: call.id, name: call.name, summary: summary)),
  )

  started = Time.monotonic_ms
  output = checked_run(turn, call)
  finished = Protocol.ToolFinished(
    call_id: call.id,
    ok: not output.is_error,
    summary: first_line(output.text),
    duration_ms: Time.monotonic_ms - started,
  )

  turn.link.emit.call(Protocol.Event.ToolFinished(finished))
  output
end

def target(turn: Turn, call: LLM.ToolCall) -> Result[String]
  return CodeMode.target(turn.ctx, call.input) if call.name == CodeMode.NAME and turn.code_mode.some?

  Tools.target(turn.ctx, call.name, call.input)
end

def checked_run(turn: Turn, call: LLM.ToolCall) -> Tools.Output
  for problem in option_list(call.input_error)
    return Tools.Output(text: problem, is_error: true)
  end

  if call.name == CodeMode.NAME
    for settings in option_list(turn.code_mode)
      names = Tools.all().map { |tool| tool.name }
      return CodeMode.run(
        settings,
        call.input,
        names,
        ->(name: String, input: JSON.Value) { nested(turn, call, name, input) },
      )
    end
  end

  case Tools.target(turn.ctx, call.name, call.input)
    ok(target) -> approved_run(turn, call, target)
    error(e) -> Tools.Output(text: e.message, is_error: true)
  end
end

def approved_run(turn: Turn, call: LLM.ToolCall, target: String) -> Tools.Output
  case Tools.verdict(turn.ctx, call.name, call.input)
    Tools.Verdict.Deny -> Tools.Output(text: DENIED_BY_RULE, is_error: true)
    Tools.Verdict.Allow -> Tools.run(turn.ctx, call.name, call.input)
    Tools.Verdict.Ask ->
      ask = Ask(call_id: call.id, tool: call.name, target: target, detail: Tools.detail(call.name, call.input))
      case turn.link.approve.call(ask)
        Protocol.Decision.Deny -> Tools.Output(text: DENIED_BY_USER, is_error: true)
        _ -> Tools.run(turn.ctx, call.name, call.input)
      end
  end
end

# A tool call of a script: a call of its own for the notices and the approval, with an id under the script's.
def nested(turn: Turn, script: LLM.ToolCall, name: String, input: JSON.Value) -> CodeMode.Reply
  id = "#{script.id}.#{Random.int(0, 999_999_999)}"
  call = LLM.ToolCall(id: id, name: name, arguments: JSON.encode(input), input: input)
  output = noticed_run(turn, call)
  return CodeMode.Reply.Done(output.text) if not output.is_error
  return CodeMode.Reply.Denied(output.text) if [DENIED_BY_RULE, DENIED_BY_USER].include?(output.text)

  CodeMode.Reply.Failed(output.text)
end

def tool_calls(message: LLM.Message) -> List[LLM.ToolCall]
  calls: List[LLM.ToolCall] = []
  for block in message.content
    case block
      LLM.Block.ToolUse(call) -> calls = calls.push(call)
      _ -> nil
    end
  end

  calls
end

# A call the model did not finish (a `max_tokens` stop) has no result, which the next request could not carry.
def without_calls(message: LLM.Message) -> LLM.Message
  message.with(
    content: message.content.select { |b| tool_calls(LLM.Message(role: message.role, content: [b])).empty? },
  )
end

def stop_reason(reason: LLM.StopReason) -> Protocol.StopReason
  case reason
    LLM.StopReason.EndTurn -> Protocol.StopReason.EndTurn
    LLM.StopReason.MaxTokens -> Protocol.StopReason.MaxTokens
    LLM.StopReason.Refusal -> Protocol.StopReason.Refusal
    LLM.StopReason.ToolUse -> Protocol.StopReason.Other("tool_use")
    LLM.StopReason.StopSequence -> Protocol.StopReason.Other("stop_sequence")
    LLM.StopReason.PauseTurn -> Protocol.StopReason.Other("pause_turn")
    LLM.StopReason.Other(name) -> Protocol.parse_stop_reason(name)
  end
end

def same_count(this_round: String, last_round: String, same: Int) -> Int
  return same + 1 if this_round == last_round

  1
end

def text_of(block: LLM.Block) -> String
  case block
    LLM.Block.Text(part) -> part.text
    LLM.Block.ToolResult(output) -> output.content
    _ -> ""
  end
end

def first_line(text: String) -> String
  line = text.split("\n").first
  return line if line.length <= 120

  line.slice(0, 120) + "..."
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
