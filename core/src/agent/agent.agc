## One turn of the agent: the model answers, the tools it calls run (after the `gate` when there is one), their
## results go back in one user message, and so on until the model ends the turn, the round limit stops it or the loop
## guard does.

import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import Catalog from "../providers/catalog"
import CodeMode from "../tools/code_mode"
import Compaction from "compaction"
import Spec from "../tools/spec"
import Todos from "../tools/todos"
import Tools from "../tools/tools"
import Logger from "std/logger"

## The provider whose models are offered `apply_patch`, as a custom tool.
RESPONSES = "openai_responses"
## The most tool rounds of a turn: high, so only a runaway turn reaches it.
MAX_ROUNDS = 500
## The loop guard stops a turn when the same 1 to `MAX_CYCLE` rounds come `CYCLE_REPEATS` times in a row.
MAX_CYCLE = 3
CYCLE_REPEATS = 3
## The rounds the guard keeps, as digests.
WINDOW = MAX_CYCLE * CYCLE_REPEATS
LATEST = "todos"
DENIED_BY_RULE = "denied by a rule of the config"
DENIED_BY_USER = "the user denied this call"
BLOCKED_BY = "blocked by an extension: "
CHANGED_BY = "an extension changed the input of this call to: "

## How a turn reaches its session. `approve` waits for the answer; `commit` gets the history after each finished
## round, so a stopped turn keeps no unfinished tool call, with the marks the round's tools of extensions made.
## `compacted` gets a compaction of the history it committed,
## and `window` the model's window once the turn asked the provider for it (-1 when it does not say).
struct Link
  emit: Fn[Protocol.Event, Void]
  approve: Fn[Ask, Protocol.Decision]
  commit: Fn[List[LLM.Message], List[String], List[Queued], Void]
  ## The messages sent while the turn runs that come after the first `Int` it read. The turn adds them to its
  ## messages before its next model call and commits them at once, which takes them out of the queue and tells the
  ## clients. Pure on the session's side: an answer that comes too late leaves them for the next read.
  take: Fn[Int, List[Queued]]
  compacted: Fn[Compaction.Compaction, Void]
  window: Fn[Int, Void]
  ## The turn sends no thinking blocks from now until a fold (Anthropic, past the limit inside a tool round).
  stripped: Fn[Void]
  ## A provider with a fresh token, for the session's later calls.
  renewed: Fn[LLM.Provider, Void]
end

## A message sent during the turn, as the turn reads it: what the user typed, the text for the model (the content of
## the skills it names first), and the names of those skills.
struct Queued
  ## The `message_id` its sender got.
  id: String
  typed: String
  text: String
  names: List[String]
end

## A call made again once with a fresh token after a 401; `fresh` is the provider that made it.
struct Renewal[T]
  result: Result[T]
  fresh: Optional[LLM.Provider] = none
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
  ## Ask the provider for its prompt cache: the system prompt and the tools, and the conversation so far.
  cache: Bool = false
  ## HTTP headers of every request.
  headers: Map[String, String] = {}
  ## A provider with a fresh token, after a 401 (the token of `ant`).
  refresh: Optional[Fn[Result[LLM.Provider]]] = none
  ## The session sends no thinking blocks until its next fold.
  stripped: Bool = false
  ## The provider of the turn, which marks its thinking: the thinking of another one is not sent. `origin` is the
  ## provider of the thinking that names none (saved before providers): the session's first.
  source: String = ""
  origin: String = ""
  ## `window` 0 asks the provider for it.
  compaction: Compaction.Settings
  ## The context of the session's last call.
  last_context: Int = 0
  max_rounds: Int = MAX_ROUNDS
  ## Adds `run_script`, which calls the tools from a Python script.
  code_mode: Optional[CodeMode.Settings] = none
  ## The output limit of each call; none takes the model's from the catalog, else sends none (the API's default).
  max_tokens: Optional[Int] = none
  ## Where the prices and the window of the model come from: the catalog and the provider of the model there.
  catalog: Optional[Catalog.Catalog] = none
  catalog_provider: String = ""
  ## How long a turn waits for a catalog that still loads.
  catalog_wait_ms: Int = 1500
  ## Read from the catalog when the turn starts.
  listed: Optional[Catalog.Model] = none
  ## The thinking level of the calls; none leaves it to the model.
  effort: Optional[String] = none
  ## The tools of extensions, after the base tools.
  turn_tools: List[Tools.TurnTool] = []
  ## The names the session's extensions noted so far (the skills it loaded).
  marks: List[String] = []
  ## The hook every tool call passes before it runs (the approval extension); without it every call runs.
  gate: Optional[Fn[Tools.Context, String, JSON.Value, Tools.Verdict]] = none
  ## What a compaction puts after its summary, from the marks and the messages it keeps.
  on_fold: Optional[Fn[List[String], List[LLM.Message], String]] = none
  ## The model's todo list when the turn starts; a fold gives the model its list again.
  todos: List[Todos.Todo] = []
  ## The last list the turn sent, under `LATEST`: a call from a script too. Made when the turn starts.
  latest: Optional[ATS[String, List[Todos.Todo]]] = none
  ## Whether the session's profile shows a tool to the model; none shows every tool.
  shows: Optional[Fn[String, Bool]] = none
end

# A `todo_write` call and its list.
struct TodoCall
  id: String
  todos: List[Todos.Todo]
end

# A tool call's result block and the mark its tool made.
struct Ran
  block: LLM.Block
  mark: Optional[String]
end

struct Outcome
  history: List[LLM.Message]
  reason: Protocol.StopReason
  ## The output limit of the last call, when it sent one.
  max_tokens: Optional[Int] = none
end

def run(started: Turn) -> Outcome
  latest: ATS[String, List[Todos.Todo]] = ATS.new()
  latest.put(LATEST, started.todos)
  given = started.with(latest: some(latest))
  turn = windowed(given.with(listed: listed_model(given)))
  messages = turn.history.push(LLM.Message(role: LLM.Role.User, content: [text_block(turn.text)]))
  turn.link.commit.call(messages, [], [])
  marks = turn.marks
  folded = compacted(turn, turn.last_context, Folded(messages: messages, on: true), marks)
  turn = renewed(turn, folded.fresh)
  folded = folded.with(fresh: none)
  messages = folded.messages
  stripped = turn.stripped and not folded.just
  rounds: List[String] = []
  tool_rounds = 0
  while tool_rounds < turn.max_rounds
    more = turn.link.take.call(0)
    if not more.empty?
      messages = messages + more.map { |q| LLM.Message(role: LLM.Role.User, content: [text_block(q.text)]) }
      names = more.flat_map { |q| q.names }
      marks = marks + names
      turn.link.commit.call(messages, names, more)
    end

    asked = Compaction.own_thinking(messages, turn.source, turn.origin)
    if stripped
      asked = Compaction.without_thinking(messages)
    end

    current = turn
    renewal = with_token(
      turn.provider,
      turn.refresh,
      ->(p: LLM.Provider) { call_model(current.with(provider: p), asked) },
    )

    turn = renewed(turn, renewal.fresh)
    called = renewal.result

    response = called.unwrap_or(EMPTY)
    response = response.with(message: Compaction.tagged(response.message, turn.source))
    case called
      ok(_) -> nil
      error(e) ->
        turn.link.emit.call(Protocol.Event.Error(Protocol.Failure(kind: e.kind, message: failure_text(turn, e))))
        return Outcome(history: messages, reason: Protocol.StopReason.Other("error"))
    end

    if response.stop_reason != LLM.StopReason.ToolUse
      messages = messages.push(without_calls(response.message))
      turn.link.commit.call(messages, [], [])
      # A cut or refused answer ends the turn: the messages sent meanwhile start the next one.
      ended = Outcome(history: messages, reason: stop_reason(response.stop_reason), max_tokens: output_limit(turn))
      cut = [LLM.StopReason.MaxTokens, LLM.StopReason.Refusal].include?(response.stop_reason)
      return ended if cut or turn.link.take.call(0).empty?

      next
    end

    calls = tool_calls(response.message)
    results: List[LLM.Block] = []
    made: List[String] = []
    for call in calls
      ran = run_call(turn, call, marks + made)
      results = results.push(ran.block)
      made = made + option_list(ran.mark)
    end

    marks = marks + made
    messages = messages + [response.message, LLM.Message(role: LLM.Role.User, content: results)]
    turn.link.commit.call(messages, made, [])
    context = response.usage.input + response.usage.cache_read + response.usage.cache_write
    if turn.provider.name == Compaction.ANTHROPIC
      if not stripped and past_limit(turn, context)
        stripped = true
        turn.link.stripped.call()
      end
    else
      folded = compacted(turn, context, folded.with(messages: messages), marks)
      turn = renewed(turn, folded.fresh)
      folded = folded.with(fresh: none)
      messages = folded.messages
    end

    this_round = JSON.encode(JSON.from([calls.map { |c| "#{c.name} #{c.arguments}" }, results.map { |r| text_of(r) }]))
    tool_rounds = tool_rounds + 1
    rounds = rounds.push(OpenSSL.Digest.sha256_hexdigest(this_round.bytes))
    if rounds.size > WINDOW
      rounds = rounds.drop(rounds.size - WINDOW)
    end

    return Outcome(history: messages, reason: Protocol.StopReason.LoopGuard) if cycling?(rounds)
  end

  Outcome(history: messages, reason: Protocol.StopReason.MaxRounds)
end

def text_block(text: String) -> LLM.Block = LLM.Block.Text(LLM.TextPart(text: text))

## `call` with `provider`; after a 401, once more with the provider `refresh` gives (a fresh token).
def with_token[T](
  provider: LLM.Provider,
  refresh: Optional[Fn[Result[LLM.Provider]]],
  call: Fn[LLM.Provider, Result[T]],
) -> Renewal[T]
  first = call.call(provider)
  return Renewal(result: first) if not unauthorized?(first)

  for fetch in option_list(refresh)
    case fetch.call()
      ok(fresh) -> return Renewal(result: call.call(fresh), fresh: some(fresh))
      error(e) -> Logger.warning("the token was not fetched again: #{e.message}")
    end
  end

  Renewal(result: first)
end

## The text of the model's blocks, for the history a client draws.
def assistant_text(message: LLM.Message) -> String = message.content.map { |b| text_of(b) }.join("")

## Whether `url` is on this machine, where a llama-server knows the window it runs with.
def local?(url: String) -> Bool = LOCAL_HOSTS.any? { |host| url.start_with?(host) }

## What a fold adds for the todo list `list`: nothing when it is empty or a `todo_write` call that stays gave it.
def folded_todos(staying: List[LLM.Message], list: List[Todos.Todo]) -> String
  return "" if list.empty? or last_todo_call(staying).map { |call| call.todos } == some(list)

  "\n\nYour todo list (`todo_write`) when the history was summarized:\n#{Todos.shown(list)}"
end

## Whether the last rounds are the same 1 to `MAX_CYCLE` rounds, `CYCLE_REPEATS` times in a row (A A A, A B A B A B).
def cycling?(rounds: List[String]) -> Bool
  for length in 1..MAX_CYCLE
    next if rounds.size < length * CYCLE_REPEATS

    tail = rounds.drop(rounds.size - length * CYCLE_REPEATS)
    cycle = tail.take(length)
    return true if (0...CYCLE_REPEATS).all? { |at| tail.drop(at * length).take(length) == cycle }
  end

  false
end

private

LOCAL_HOSTS = ["http://127.0.0.1:", "http://localhost:", "http://[::1]:", "http://0.0.0.0:"]

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
  # The provider of a fresh token, when the summary got one.
  fresh: Optional[LLM.Provider] = none
end

# The session keeps a window once the API answered; after a failed request a later turn asks again.
# A local server (llama-server) knows the window it runs with (`/props`): it goes first there; elsewhere the catalog,
# else the API.
def windowed(given: Turn) -> Turn
  listed = given.listed.map { |model| model.window.unwrap_or(0) }.unwrap_or(0)
  return given if given.compaction.window > 0 or (given.compaction.window < 0 and listed == 0)

  if listed > 0 and not local?(given.compaction.props_url)
    return given.with(compaction: given.compaction.with(window: known_window(given, ok(listed))))
  end

  renewal = with_token(
    given.provider,
    given.refresh,
    ->(p: LLM.Provider) { Compaction.window(p, given.model, given.compaction) },
  )

  turn = renewed(given, renewal.fresh)
  asked = renewal.result
  if listed > 0 and asked.unwrap_or(0) <= 0
    asked = ok(listed)
  end

  turn.with(compaction: turn.compaction.with(window: known_window(turn, asked)))
end

def known_window(turn: Turn, asked: Result[Int]) -> Int
  case asked
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
def compacted(turn: Turn, context: Int, folded: Folded, marks: List[String]) -> Folded
  return folded if not folded.on

  due = Compaction.due?(turn.compaction, context)
  return folded.with(just: false) if not due

  if folded.just
    message = "the compacted history is still past the limit: no more compaction in this turn"
    turn.link.emit.call(Protocol.Event.Error(Protocol.Failure(kind: Compaction.KIND_FAILED, message: message)))
    return folded.with(on: false, just: false)
  end

  for span in option_list(Compaction.span(folded.messages))
    renewal = with_token(
      turn.provider,
      turn.refresh,
      ->(p: LLM.Provider) { Compaction.summarize(p, turn.compaction, folded.messages, span) },
    )

    fresh = folded.with(fresh: renewal.fresh)
    case renewal.result
      ok(summary) ->
        compaction = summary
        staying = Compaction.staying(folded.messages, summary)
        for on_fold in option_list(turn.on_fold)
          extra = on_fold.call(marks, staying)
          compaction = summary.with(summary: "#{summary.summary}#{extra}")
        end

        compaction = compaction.with(summary: "#{compaction.summary}#{folded_todos(staying, latest_todos(turn))}")

        turn.link.compacted.call(compaction)
        return fresh.with(messages: Compaction.apply(folded.messages, compaction), just: true)
      error(e) ->
        message = "the history was not compacted: #{e.message}"
        turn.link.emit.call(Protocol.Event.Error(Protocol.Failure(kind: Compaction.KIND_FAILED, message: message)))
        return fresh.with(on: false)
    end
  end

  folded
end

# What a failed call says. A refusal or a connection that failed on the `local` provider, which a session gets when no
# provider was picked, says so and what to do, and is logged as a warning.
def failure_text(turn: Turn, e: Error) -> String
  return e.message if not turn.source.start_with?("local/")

  # `FINN_BASE_URL` is an explicit choice of the user: the way out is its key, not another provider.
  advice = "pick a provider with /model, or log in with /login"
  case turn.ctx.env.call("FINN_BASE_URL")
    ok(url) if not url.empty? -> advice = "check FINN_API_KEY, or pick a provider with /model"
    _ -> nil
  end

  said = e.message
  if e.kind == "llm.auth"
    said = "the local provider refused the request (HTTP #{e.code.unwrap_or(0)}): #{advice}"
  elsif e.kind == "llm.network"
    said = "the local provider did not answer (#{e.message.split("\n").select { |l| l != "" }.join("; ")}): #{advice}"
  end

  if said != e.message
    Logger.warning("turn #{turn.id}: #{said}")
  end

  said
end

# Anthropic folds only between turns: a fold inside a tool round would change the history its thinking blocks are bound
# to. Past the limit inside a round, the rest of the turn sends no thinking blocks, once said in the log.
def past_limit(turn: Turn, context: Int) -> Bool
  return false if not Compaction.due?(turn.compaction, context)

  Logger.warning(
    "turn #{turn.id}: the context is past the limit inside a tool round; the turn goes on without thinking blocks",
  )

  true
end

# The turn and the session go on with a provider of a fresh token.
def renewed(turn: Turn, fresh: Optional[LLM.Provider]) -> Turn
  for provider in option_list(fresh)
    turn.link.renewed.call(provider)
    return turn.with(provider: provider)
  end

  turn
end

def unauthorized?[T](result: Result[T]) -> Bool
  case result
    error(e) -> e.code == some(401)
    ok(_) -> false
  end
end

def call_model(turn: Turn, messages: List[LLM.Message]) -> Result[LLM.Response]
  tools = offered(turn).map { |t| LLM.Tool(name: t.name, description: t.description, input_schema: t.input_schema) }
  if turn.provider.name == RESPONSES and shown?(turn, Tools.PATCH)
    patch = Tools.patch()
    grammar = Tools.patch_grammar()
    tools = tools.push(
      LLM.Tool(name: patch.name, description: patch.description, input_schema: grammar, kind: LLM.ToolKind.Custom),
    )
  end

  request = LLM.Request(
    model: turn.model,
    system: turn.system,
    messages: messages,
    tools: tools,
    extra: turn.extra,
    cache: turn.cache,
    headers: turn.headers,
    effort: turn.effort,
    max_tokens: output_limit(turn),
  )

  stream = try LLM.stream(turn.provider, request)
  first: Optional[Int] = none
  while true
    event = stream.events.recv(60000)
    if first.none? and output?(event)
      first = some(Time.monotonic_ms)
    end

    case event
      ok(LLM.Event.TextDelta(piece)) ->
        turn.link.emit.call(Protocol.Event.TextDelta(Protocol.TextDelta(text: piece.text)))
      ok(LLM.Event.ThinkingDelta(piece)) ->
        turn.link.emit.call(Protocol.Event.ThinkingDelta(Protocol.ThinkingDelta(text: piece.text)))
      ok(_) -> next
      error(_) -> break if stream.events.closed?
    end
  end

  ended = Time.monotonic_ms
  response = try LLM.response(stream)
  used = usage(response.usage, turn.listed).with(output_ms: first.map { |at| ended - at })
  turn.link.emit.call(Protocol.Event.Usage(used))
  ok(response)
end

# A piece of the answer: text, thinking or a tool call.
def output?(event: Result[LLM.Event]) -> Bool
  case event
    ok(LLM.Event.TextDelta(_)) -> true
    ok(LLM.Event.ThinkingDelta(_)) -> true
    ok(LLM.Event.ToolUseStart(_)) -> true
    ok(LLM.Event.ToolInputDelta(_)) -> true
    _ -> false
  end
end

def usage(u: LLM.Usage, listed: Optional[Catalog.Model]) -> Protocol.Usage
  cost: Optional[Float] = none
  for model in option_list(listed)
    cost = Catalog.cost(model, u)
  end

  Protocol.Usage(
    input: u.input,
    output: u.output,
    cache_read: u.cache_read,
    cache_write: u.cache_write,
    context: u.input + u.cache_read + u.cache_write,
    cost: cost,
  )
end

# A catalog still loading gets a short wait, so that a first turn has its prices and window.
def listed_model(turn: Turn) -> Optional[Catalog.Model]
  for catalog in option_list(turn.catalog)
    _ = Catalog.wait(catalog, turn.catalog_wait_ms)
    return Catalog.find(catalog, turn.catalog_provider, turn.model)
  end

  none
end

def offered(turn: Turn) -> List[Tools.Tool]
  base = shown_tools(turn)
  extras = turn.turn_tools.map { |t| t.tool }.select { |tool| shown?(turn, tool.name) }
  for _settings in option_list(turn.code_mode)
    return base.push(CodeMode.spec(base)) + extras if shown?(turn, CodeMode.NAME)
  end

  base + extras
end

def shown_tools(turn: Turn) -> List[Tools.Tool] = Tools.offered(turn.ctx).select { |tool| shown?(turn, tool.name) }

def shown?(turn: Turn, name: String) -> Bool
  for shows in option_list(turn.shows)
    return shows.call(name)
  end

  true
end

def turn_tool(turn: Turn, name: String) -> Optional[Tools.TurnTool]
  case turn.turn_tools.find { |t| t.tool.name == name }
    ok(found) -> some(found)
    error(_) -> none
  end
end

# `marks` are the session's so far, which a tool of an extension reads.
# The result of a call whose input an extension changed says what ran, so the history keeps it.
def run_call(turn: Turn, call: LLM.ToolCall, marks: List[String]) -> Ran
  given = with_input(call)
  checked = before(turn, given)
  ran = noticed_run(turn, given, checked, marks)
  output = ran.output
  content = "#{changed_note(given, checked)}#{output.text}"
  block = LLM.Block.ToolResult(LLM.ToolOutput(tool_use_id: call.id, content: content, is_error: output.is_error))
  Ran(block: block, mark: ran.mark)
end

def changed_note(call: LLM.ToolCall, checked: Result[JSON.Value]) -> String
  case checked
    ok(input) if JSON.encode(input) != JSON.encode(call.input) -> "#{CHANGED_BY}#{JSON.encode(input)}\n\n"
    _ -> ""
  end
end

# A custom tool's call has its text as `input`, the field its tool reads.
def with_input(call: LLM.ToolCall) -> LLM.ToolCall
  return call if call.kind != LLM.ToolKind.Custom

  call.with(input: JSON.object({"input": JSON.from(call.arguments)}))
end

# Runs the call between its `tool_started` and `tool_finished` events, on the input the extensions gave (`checked`).
def noticed_run(turn: Turn, given: LLM.ToolCall, checked: Result[JSON.Value], marks: List[String]) -> Tools.TurnOutput
  call = given.with(input: checked.unwrap_or(given.input))
  summary = target(turn, call).unwrap_or(call.name)
  turn.link.emit.call(
    Protocol.Event.ToolStarted(Protocol.ToolStarted(call_id: call.id, name: call.name, summary: summary)),
  )

  change = Tools.change(turn.ctx, call.name, call.input)
  started = Time.monotonic_ms
  ran = case checked
    ok(_) -> checked_run(turn, call, marks)
    error(e) -> Tools.TurnOutput(output: Tools.Output(text: stopped_text(e), is_error: true))
  end

  output = ran.output
  diff = change
  if output.is_error
    diff = none
  end

  finished = Protocol.ToolFinished(
    call_id: call.id,
    ok: not output.is_error,
    summary: first_line(output.text),
    duration_ms: Time.monotonic_ms - started,
    output: Tools.shown_output(output.text),
    diff: diff,
  )

  turn.link.emit.call(Protocol.Event.ToolFinished(finished))
  if call.name == Todos.NAME and not output.is_error
    case Todos.todos(call.input)
      ok(list) ->
        todos = list.map { |t| Protocol.Todo(content: t.content, status: t.status) }
        turn.link.emit.call(Protocol.Event.Todos(Protocol.Todos(todos: todos)))
        for latest in option_list(turn.latest)
          latest.put(LATEST, list)
        end

      error(_) -> nil
    end
  end

  ran
end

# The input of the call after the extensions' `ToolBefore` handlers; a call with a broken input goes on as it is.
def before(turn: Turn, call: LLM.ToolCall) -> Result[JSON.Value]
  return ok(call.input) if call.input_error.some?

  case turn.ctx.before
    some(hook) -> hook.call(turn.ctx, call.name, call.input)
    none -> ok(call.input)
  end
end

def stopped_text(e: Error) -> String
  return "#{BLOCKED_BY}#{e.message}" if e.kind == Spec.BLOCKED

  e.message
end

def target(turn: Turn, call: LLM.ToolCall) -> Result[String]
  return CodeMode.target(turn.ctx, call.input) if call.name == CodeMode.NAME and turn.code_mode.some?
  for extra in option_list(turn_tool(turn, call.name))
    return extra.tool.target.call(turn.ctx, call.input)
  end

  Tools.target(turn.ctx, call.name, call.input)
end

def checked_run(turn: Turn, call: LLM.ToolCall, marks: List[String]) -> Tools.TurnOutput
  if not shown?(turn, call.name)
    return Tools.TurnOutput(output: Tools.Output(text: "the session's profile hides #{call.name}", is_error: true))
  end

  for problem in option_list(call.input_error)
    return Tools.TurnOutput(output: Tools.Output(text: problem, is_error: true))
  end

  for extra in option_list(turn_tool(turn, call.name))
    return extra.run.call(call.input, marks)
  end

  Tools.TurnOutput(output: base_run(turn, call))
end

def base_run(turn: Turn, call: LLM.ToolCall) -> Tools.Output
  if call.name == Tools.PATCH and (turn.provider.name != RESPONSES or call.kind != LLM.ToolKind.Custom)
    return Tools.Output(text: "unknown tool: #{call.name}", is_error: true)
  end

  if call.name == CodeMode.NAME
    for settings in option_list(turn.code_mode)
      names = shown_tools(turn).map { |tool| tool.name }
      return CodeMode.run(
        settings,
        call.input,
        names,
        ->(name: String, input: JSON.Value) { nested(turn, call, name, input) },
      )
    end
  end

  case Tools.target(turn.ctx, call.name, call.input)
    ok(found) -> approved_run(turn, call, found)
    error(e) -> Tools.Output(text: e.message, is_error: true)
  end
end

def approved_run(turn: Turn, call: LLM.ToolCall, target: String) -> Tools.Output
  verdict = Tools.Verdict.Allow
  for gate in option_list(turn.gate)
    verdict = gate.call(turn.ctx, call.name, call.input)
  end

  case verdict
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
  output = noticed_run(turn, call, before(turn, call), []).output
  return CodeMode.Reply.Done(output.text) if not output.is_error
  return CodeMode.Reply.Denied(output.text) if [DENIED_BY_RULE, DENIED_BY_USER].include?(output.text)
  return CodeMode.Reply.Denied(output.text) if output.text.start_with?(BLOCKED_BY)

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

# The user's limit, else the model's own from the catalog.
def output_limit(turn: Turn) -> Optional[Int]
  return turn.max_tokens if turn.max_tokens.some?

  case turn.listed
    some(model) -> model.output
    none -> none
  end
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

# The last list the turn sent, else the one it started with.
def latest_todos(turn: Turn) -> List[Todos.Todo]
  for latest in option_list(turn.latest)
    return latest.get(LATEST).unwrap_or(turn.todos)
  end

  turn.todos
end

# The last `todo_write` call of `messages` whose list is valid and whose result is not an error.
def last_todo_call(messages: List[LLM.Message]) -> Optional[TodoCall]
  blocks = messages.flat_map { |m| m.content }
  failed = blocks.flat_map { |b| failed_id(b) }
  found: Optional[TodoCall] = none
  for block in blocks
    case block
      LLM.Block.ToolUse(call) if call.name == Todos.NAME and not failed.include?(call.id) ->
        case Todos.todos(call.input)
          ok(list) -> found = some(TodoCall(id: call.id, todos: list))
          error(_) -> nil
        end

      _ -> nil
    end
  end

  found
end

def failed_id(block: LLM.Block) -> List[String]
  case block
    LLM.Block.ToolResult(result) if result.is_error -> [result.tool_use_id]
    _ -> []
  end
end
