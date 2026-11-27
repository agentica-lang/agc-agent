## A turn of a session: it starts, reads the queued messages, asks the approvals, commits its messages and ends;
## and the compaction of the history.

import Actor from "std/actor"
import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import Agent from "../agent/agent"
import Compaction from "../agent/compaction"
import Extensions from "../config/registry"
import Spec from "../tools/spec"
import Spill from "../tools/spill"
import Session from "state"
import Store from "store"
import Stream from "stream"
import Todos from "../tools/todos"
import Tools from "../tools/tools"
import Logger from "std/logger"

## A wake from `source` (`child:ID` for a child's answer, `extension` otherwise). One that finds a running turn queues
## into it, like a user's message, and does not count. An idle one parks in the stop window, or past the cap, and
## starts a turn otherwise: only a wake that starts a turn counts.
def wake(
  state: Session.State,
  text: String,
  source: String,
  reply: Channel[Result[Protocol.MessageAccepted]],
) -> Session.State
  for _running in option_list(state.turn)
    return park(state, text, source, reply) if state.stop_window

    return start_turn(state, text, reply, some(source))
  end

  if state.stop_window or (state.setup.wakes_max > 0 and state.wakes >= state.setup.wakes_max)
    return park(state, text, source, reply)
  end

  start_turn(state, text, reply, some(source))
end

## A wake that waits for the next user message: accepted and kept, with an empty `turn_id` for the clients.
def park(
  state: Session.State,
  text: String,
  source: String,
  reply: Channel[Result[Protocol.MessageAccepted]],
) -> Session.State
  parked = state.parked.push(Session.Parked(text: text, source: source))
  Actor.reply(reply, ok(Protocol.MessageAccepted(turn_id: "")))
  queued = Protocol.MessageQueued(turn_id: "", text: text, source: some(source))
  Stream.emit(state.with(parked: parked), Protocol.Event.MessageQueued(queued))
end

## A message sent while a turn runs waits in the queue, which the turn reads before its next model call. The user's
## `/name` of a skill puts its content before the message, unless the session has it already. `source` is who sent it
## when the user did not: a wake that queues into the running turn, or starts the next one from `next_turn`.
def start_turn(
  state: Session.State,
  typed: String,
  reply: Channel[Result[Protocol.MessageAccepted]],
  source: Optional[String] = none,
) -> Session.State
  if state.compacting or state.shell.some?
    Actor.reply(reply, error(Session.busy_reason(state), kind: Protocol.KIND_SESSION_BUSY))
    return state
  end

  if not state.setup.refused.empty?
    Actor.reply(reply, error(state.setup.refused, kind: Protocol.KIND_SESSION_UNAVAILABLE))
    return state
  end

  if not state.setup.profile_refused.empty?
    Actor.reply(reply, error(state.setup.profile_refused, kind: Protocol.KIND_SESSION_UNAVAILABLE))
    return state
  end

  for running in option_list(state.turn)
    if state.queued.size >= MAX_QUEUED or (texts(state.queued) + [typed]).join("\n\n").bytesize > MAX_QUEUED_BYTES
      message = "a turn is running and its queue is full (#{MAX_QUEUED} messages, #{MAX_QUEUED_BYTES} bytes)"
      Actor.reply(reply, error(message, kind: Protocol.KIND_SESSION_BUSY))
      return state
    end

    message_id = "#{running.id}.#{running.queued + 1}"
    Actor.reply(reply, ok(Protocol.MessageAccepted(turn_id: running.id, message_id: some(message_id))))
    waiting = state.queued.push(Session.Unread(id: message_id, text: typed, source: source))
    cleared = state
    if source.none?
      cleared = state.with(wakes: 0, stop_window: false)
    end

    queued = cleared.with(turn: some(running.with(queued: running.queued + 1)), queued: waiting)
    event = Protocol.MessageQueued(turn_id: running.id, text: typed, message_id: some(message_id), source: source)
    return Stream.emit(queued, Protocol.Event.MessageQueued(event))
  end

  case route(state.setup)
    error(e) ->
      Actor.reply(reply, error(e.message, kind: Protocol.KIND_INVALID))
      return state
    ok(_) -> nil
  end

  handled = on_message(state.setup, typed, state.marks)
  if not handled.ok?
    Logger.warning("session #{state.setup.id}: #{handled.message}")
    Actor.reply(reply, error("an extension refused the message: #{handled.message}", kind: Protocol.KIND_INVALID))
    return state
  end

  expanded = handled.unwrap!

  shells = not state.shells.empty?
  # The parked wakes go before the user's own message; a wake starts with no parked one. The record keeps them but
  # not the shells, which the next load reads again from their own events.
  take: List[Session.Parked] = []
  if source.none?
    take = state.parked
  end

  taken = take.map { |parked| parked.text }
  own = (taken + [expanded.text]).join("\n\n")
  text = Store.with_shells(state.shells, own)
  case Stream.save(state, -> { Store.append_user(state.setup.file, own, typed, expanded.names, shells, source) })
    ok(_) -> state = state.with(marks: state.marks + expanded.names)
    error(e) ->
      Actor.reply(
        reply,
        error("the session file cannot be written: #{e.message}", kind: Protocol.KIND_SESSION_STORAGE),
      )

      return state.with(broken: some(e.message))
  end

  turn_id = new_turn_id(state.turns + 1)
  inbox: Channel[Session.Msg] = Actor.inbox
  address = inbox.address
  setup = routed(state.setup)
  storage = artifacts(setup)
  ctx = Spec.snapshot(setup.ctx)
  for port in option_list(storage)
    ctx = ctx.with(tools: [Spill.tool(port)] + ctx.tools)
  end

  link = Agent.Link(
    emit: ->(event) { tell(address, Session.Msg.Emit(turn_id, event)) },
    approve: ->(call) { wait_approval(address, turn_id, call, setup.approval_timeout_ms) },
    commit: ->(history, marks, read) { tell(address, Session.Msg.Commit(turn_id, history, marks, read)) },
    take: ->(after) { taken(address, turn_id, after, setup.take_ms) },
    compacted: ->(compaction) { tell(address, Session.Msg.Compacted(turn_id, compaction)) },
    window: ->(window) { tell(address, Session.Msg.Window(window)) },
    stripped: -> { tell(address, Session.Msg.Stripped(turn_id)) },
    renewed: ->(provider) { tell(address, Session.Msg.Renewed(provider)) },
  )

  turn = Agent.Turn(
    id: turn_id,
    provider: setup.provider,
    model: setup.model,
    system: setup.system,
    history: state.history,
    text: text,
    ctx: ctx,
    link: link,
    extra: setup.extra,
    cache: setup.cache,
    headers: headers_of(setup),
    refresh: setup.refresh,
    max_rounds: setup.max_rounds,
    stripped: state.stripped,
    source: "#{setup.provider_name}/#{setup.api}",
    origin: setup.origin,
    compaction: compaction_of(state.setup, state.window),
    last_context: state.context,
    code_mode: setup.code_mode,
    max_tokens: setup.max_tokens,
    catalog: setup.catalog,
    catalog_provider: setup.catalog_provider,
    catalog_wait_ms: setup.catalog_wait_ms,
    turn_tools: Extensions.turn_tools(setup.builtins),
    marks: state.marks,
    on_fold: some(on_fold(setup)),
    todos: todos_of(state),
    shows: setup.shows,
    effort: setup.effort,
    gate: gate(setup.approver),
    artifacts: storage,
  )

  task = Task.spawn(&run_turn, Job(turn: turn, address: address))
  # A user's turn takes the parked wakes and resets the count; a wake's turn counts and keeps them (none wait).
  wakes = state.wakes
  fresh_parked = state.parked
  window = state.stop_window
  if source.none?
    wakes = 0
    fresh_parked = []
    window = false
  end

  for _source in option_list(source)
    wakes = state.wakes + 1
  end

  running = Session.Running(id: turn_id, task: task, from_event_id: state.counter, shown: state.display.size + 1)
  started = state.with(
    turn: some(running),
    turns: state.turns + 1,
    turn_cost: 0.0,
    wakes: wakes,
    parked: fresh_parked,
    stop_window: window,
    history: state.history.push(LLM.Message(role: LLM.Role.User, content: [Agent.text_block(text)])),
    display: state.display.push(Protocol.Message(role: Protocol.Role.User, text: typed)),
    broken: none,
    shells: [],
  )

  Actor.reply(reply, ok(Protocol.MessageAccepted(turn_id: turn_id)))
  begun = Protocol.TurnStarted(turn_id: turn_id, history_size: some(started.display.size), source: source)
  Stream.emit(started, Protocol.Event.TurnStarted(begun))
end

## The queued messages after the first `after`, each with the content of the skills it names. Nothing changes here: the
## commit of the turn that read them takes them out of the queue.
def take(state: Session.State, turn_id: String, after: Int, reply: Channel[List[Agent.Queued]]) -> Session.State
  current = state.turn.map { |t| t.id == turn_id }.unwrap_or(false)
  read: List[Agent.Queued] = []
  if current
    marks = state.marks
    for waiting in state.queued.drop(after)
      typed = waiting.text
      # Accepted already: a handler that fails leaves it as the skills made it.
      handled = on_message(state.setup, typed, marks)
      if not handled.ok?
        Logger.warning("session #{state.setup.id}: #{handled.message}")
      end

      expanded = handled.unwrap_or(Extensions.noted(state.setup.builtins, typed, marks))

      read = read.push(Agent.Queued(id: waiting.id, typed: typed, text: expanded.text, names: expanded.names))
      marks = marks + expanded.names
    end
  end

  Actor.reply(reply, read)
  state
end

## The endpoint of the API that serves the model of `setup`, when its provider gives each model its own; none for
## another provider. An error says why the model cannot be used.
def route(setup: Session.Setup) -> Result[Optional[Session.Endpoint]]
  for find in option_list(setup.routed)
    return find.call(setup.provider_name, setup.model)
  end

  ok(none)
end

## `setup` on the API that serves its model.
def routed(setup: Session.Setup) -> Session.Setup
  case route(setup)
    ok(found) -> with_endpoint(setup, found)
    error(_) -> setup
  end
end

def with_endpoint(setup: Session.Setup, found: Optional[Session.Endpoint]) -> Session.Setup
  for endpoint in option_list(found)
    return setup.with(
      api: endpoint.api,
      provider: endpoint.provider,
      extra: endpoint.extra,
      cache: endpoint.cache,
      headers: endpoint.headers,
      refresh: endpoint.refresh,
    )
  end

  setup
end

## What writes the summary of a compaction: the compaction model, on the API that serves it.
def compaction_of(setup: Session.Setup, window: Int) -> Compaction.Settings
  asked = setup.with(model: compact_model(setup))
  settings = Compaction.Settings(
    window: window,
    model: asked.model,
    props_url: setup.props_url,
    api_key: setup.api_key,
    extra: setup.extra,
    headers: headers_of(setup),
    artifacts: artifacts(setup),
  )

  mine: Optional[Session.Endpoint] = none
  case route(setup)
    ok(found) -> mine = found
    error(_) -> nil
  end

  case route(asked)
    ok(found) ->
      for endpoint in option_list(found)
        settings = settings.with(
          provider: some(endpoint.provider),
          extra: endpoint.extra,
          headers: headers_of(asked.with(headers: endpoint.headers)),
        )
      end

      # A summary model the catalog does not list takes the provider's own API, not the one of the session's model.
      if found.none? and mine.some?
        settings = settings.with(provider: some(setup.provider))
      end

    error(e) -> settings = settings.with(refused: e.message)
  end

  settings
end

def artifacts(setup: Session.Setup) -> Optional[Spill.Port]
  for shows in option_list(setup.shows)
    return none if not shows.call(Spill.NAME)
  end

  some(Store.artifacts(setup.file))
end

def gate(approver: Optional[Extensions.Approver]) -> Optional[Fn[Tools.Context, String, JSON.Value, Tools.Verdict]]
  case approver
    some(a) -> a.verdict
    none -> none
  end
end

def ask(state: Session.State, call: Agent.Ask, reply: Channel[Protocol.Decision]) -> Session.State
  allowed = state.setup.approver.map { |a| a.allows.call(call.tool, call.target) }.unwrap_or(false)
  if allowed
    _ = reply.send(Protocol.Decision.Allow, 0)
    return state
  end

  request = Protocol.ApprovalRequested(
    approval_id: "a#{state.approvals + 1}",
    call_id: call.call_id,
    tool: call.tool,
    preview: call.target,
    detail: call.detail,
    prefix: state.setup.approver.map { |a| a.prefix.call(call.tool, call.target) }.unwrap_or(none),
  )

  waiting = Session.Waiting(request: request, reply: reply, asked_ms: Time.monotonic_ms)
  asked = state.with(pending: state.pending.push(waiting), approvals: state.approvals + 1)
  Stream.emit(asked, Protocol.Event.ApprovalRequested(request))
end

def answer_approval(
  state: Session.State,
  approval_id: String,
  decision: Protocol.Decision,
  reply: Channel[Result[Void]],
) -> Session.State
  if not state.pending.any? { |w| w.request.approval_id == approval_id }
    kind = Protocol.KIND_APPROVAL_NOT_FOUND
    if state.resolved.include?(approval_id)
      kind = Protocol.KIND_APPROVAL_RESOLVED
    end

    Actor.reply(reply, error("approval #{approval_id} is not waiting", kind: kind))
    return state
  end

  Actor.reply(reply, ok())
  resolve(state, approval_id, decision, Protocol.ApprovalSource.Client)
end

def expire(state: Session.State) -> Session.State
  pruned = Stream.prune(state)
  now = Time.monotonic_ms
  out = pruned
  for alone in option_list(pruned.alone_since)
    for waiting in pruned.pending
      if now >= [waiting.asked_ms, alone].max.unwrap! + state.setup.approval_timeout_ms
        out = resolve(out, waiting.request.approval_id, Protocol.Decision.Deny, Protocol.ApprovalSource.Timeout)
      end
    end
  end

  out
end

def stop_turn(state: Session.State) -> Session.State
  case state.turn
    some(turn) ->
      Task.cancel(turn.task)
      denied = state
      for waiting in state.pending
        denied = resolve(denied, waiting.request.approval_id, Protocol.Decision.Deny, Protocol.ApprovalSource.Stop)
      end

      finish(denied, Protocol.StopReason.Cancelled, none)
    none -> state
  end
end

def finish(state: Session.State, reason: Protocol.StopReason, limit: Optional[Int]) -> Session.State
  case state.turn
    some(turn) if reason == Protocol.StopReason.Cancelled ->
      ended(dropped(state), turn.id, turn.texts, reason).with(turn: none)
    some(turn) -> next_turn(ended(state, turn.id, turn.texts, reason, limit).with(turn: none))
    none -> state
  end
end

def start_fold(state: Session.State, reply: Channel[Result[Session.Fold]]) -> Session.State
  if Session.busy?(state)
    Actor.reply(reply, error(Session.busy_reason(state), kind: Protocol.KIND_SESSION_BUSY))
    return state
  end

  setup = routed(state.setup)
  settings = compaction_of(state.setup, state.window)

  fold = Session.Fold(
    provider: setup.provider,
    refresh: setup.refresh,
    settings: settings,
    history: state.history,
    span: Compaction.span(state.history),
  )

  Actor.reply(reply, ok(fold))
  state.with(compacting: true)
end

def end_fold(
  state: Session.State,
  found: Optional[Compaction.Compaction],
  reply: Channel[Result[Void]],
) -> Session.State
  done = state.with(compacting: false)
  for summary in option_list(found)
    staying = Compaction.staying(done.history, summary)
    extra = on_fold(done.setup).call(done.marks, staying)
    extra = "#{extra}#{Agent.folded_todos(staying, todos_of(done))}"
    folded = compact(done, summary.with(summary: "#{summary.summary}#{extra}"))
    if folded.broken.some?
      Actor.reply(reply, error("the session file cannot be written", kind: Protocol.KIND_SESSION_STORAGE))
      return folded
    end

    Actor.reply(reply, ok())
    return folded
  end

  Actor.reply(reply, ok())
  done
end

def compact(state: Session.State, compaction: Compaction.Compaction) -> Session.State
  answer = state.turn.map { |t| t.texts }.unwrap_or([])
  case Stream.save(state, -> { Store.append_compaction(state.setup.file, compaction, answer) })
    ok(_) -> state.with(history: Compaction.apply(state.history, compaction), broken: none, stripped: false)
    error(e) -> Stream.broke(state, e)
  end
end

def stripped(state: Session.State) -> Session.State
  case Stream.save(state, -> { Store.append_stripped(state.setup.file) })
    ok(_) -> state.with(stripped: true, broken: none)
    error(e) -> Stream.broke(state, e)
  end
end

## The history of a turn only grows, so only its new messages go to the file.
## The messages the turn read from the queue leave it here, shown after the answer of the turn so far. A crash between
## their `queued` records and the messages record leaves a shown message that the history lacks.
def commit(
  state: Session.State,
  history: List[LLM.Message],
  marks: List[String],
  read: List[Agent.Queued],
) -> Session.State
  added = history.drop(state.history.size)
  return state if added.empty?

  shown = state
  if not read.empty?
    shown = answer_so_far(state)
    return shown if shown.broken.some?
  end

  for queued in read
    source: Optional[String] = none
    for waiting in state.queued
      if waiting.id == queued.id
        source = waiting.source
      end
    end

    case Stream.save(shown, -> { Store.append_queued(state.setup.file, queued.typed, source) })
      ok(_) ->
        message = Protocol.Message(role: Protocol.Role.User, text: queued.typed)
        shown = shown.with(display: shown.display.push(message), queued: shown.queued.drop(1))
        shown = delivered(shown, queued.id, queued.typed)
        return shown if shown.broken.some?
      error(e) -> return Stream.broke(shown, e)
    end
  end

  case Stream.save(shown, -> { Store.append_messages(state.setup.file, added, marks) })
    ok(_) ->
      turn = shown.turn.map { |t| t.with(texts: t.texts + answer_texts(added)) }
      display = Store.with_thinking(shown.display, added)
      shown.with(history: history, turn: turn, broken: none, marks: shown.marks + marks, display: display)
    error(e) -> Stream.broke(shown, e)
  end
end

## The running turn sends the queued message `id` with its next call: the clients show it as a user message.
def delivered(state: Session.State, id: String, typed: String) -> Session.State
  for running in option_list(state.turn)
    event = Protocol.MessageDelivered(turn_id: running.id, text: typed, message_id: some(id))
    return Stream.emit(state, Protocol.Event.MessageDelivered(event))
  end

  state
end

def texts(queued: List[Session.Unread]) -> List[String] = queued.map { |w| w.text }

## Shows the answer of the turn, its `texts` together, then ends the turn.
def ended(
  state: Session.State,
  turn_id: String,
  texts: List[String],
  reason: Protocol.StopReason,
  limit: Optional[Int] = none,
) -> Session.State
  text = texts.join("\n\n")
  shown = state
  if not text.empty?
    case Stream.save(state, -> { Store.append_answer(state.setup.file, text) })
      ok(_) ->
        answer = Protocol.Message(role: Protocol.Role.Assistant, text: text)
        shown = state.with(display: state.display.push(answer), broken: none)
      error(e) -> return Stream.broke(state, e)
    end
  end

  finished = Protocol.TurnFinished(
    turn_id: turn_id,
    stop_reason: reason,
    history_size: some(shown.display.size),
    max_tokens: limit,
  )

  Stream.emit(shown, Protocol.Event.TurnFinished(finished))
end

def answer_texts(messages: List[LLM.Message]) -> List[String]
  said = messages.select { |m| m.role == LLM.Role.Assistant }.map { |m| Agent.assistant_text(m) }
  said.select { |t| not t.empty? }
end

## The number of the turn and a random part: a server that lost the last records of a session never gives a turn the id
## of another.
def new_turn_id(number: Int) -> String = "turn-#{number}-#{OpenSSL.Random.hex(4)}"

private

MAX_QUEUED = 20
## The queued messages together, as the next turn would get them, are at most one message's size.
MAX_QUEUED_BYTES = 1_048_576

struct Job
  turn: Agent.Turn
  address: Address[Session.Msg]
end

def run_turn(job: Job) -> Void
  outcome = Agent.run(job.turn)
  _ = Actor.cast(job.address, Session.Msg.Finished(job.turn.id, outcome.reason, outcome.max_tokens), Session.CALL_MS)
end

# A session that is gone cannot take the turn's events: the turn ends.
def tell(address: Address[Session.Msg], msg: Session.Msg) -> Void
  if not Actor.cast(address, msg, Session.CALL_MS).ok?
    Task.cancel(Task.current)
  end
end

# The session denies an approval once no client has been attached for `timeout_ms`; the turn asks it to check now and
# then.
def taken(address: Address[Session.Msg], turn_id: String, after: Int, wait_ms: Int) -> List[Agent.Queued]
  none_taken: List[Agent.Queued] = []
  taken: Result[List[Agent.Queued]] = Actor.call(address, wait_ms) do |reply|
    Session.Msg.Take(turn_id, after, reply)
  end

  taken.unwrap_or(none_taken)
end

def wait_approval(
  address: Address[Session.Msg],
  turn_id: String,
  call: Agent.Ask,
  timeout_ms: Int,
) -> Protocol.Decision
  reply: Channel[Protocol.Decision] = Channel.new(1)
  return Protocol.Decision.Deny if not Actor.cast(address, Session.Msg.Ask(turn_id, call, reply), Session.CALL_MS).ok?

  poll_ms = [timeout_ms, 1000].min.unwrap!
  while true
    case reply.recv(poll_ms)
      ok(decision) -> return decision
      error(_) if reply.closed? -> return Protocol.Decision.Deny
      error(_) ->
        return Protocol.Decision.Deny if not Actor.cast(address, Session.Msg.Expire(turn_id), Session.CALL_MS).ok?
    end
  end

  Protocol.Decision.Deny
end

# A message after the skills it names and the `message` handlers of the extensions.
def on_message(setup: Session.Setup, typed: String, marks: List[String]) -> Result[Extensions.Noted]
  expanded = Extensions.noted(setup.builtins, typed, marks)
  case setup.registry
    some(registry) -> ok(expanded.with(text: try Extensions.message(registry, expanded.text)))
    none -> ok(expanded)
  end
end

# The session's todo list, as the tools read it.
def todos_of(state: Session.State) -> List[Todos.Todo]
  state.todos.map { |t| Todos.Todo(content: t.content, status: t.status) }
end

# What a fold adds after the summary: the skills in use, then the `fold` handlers of the extensions.
def on_fold(setup: Session.Setup) -> Fn[List[String], List[LLM.Message], String]
  ->(marks: List[String], staying: List[LLM.Message]) {
    (
      "#{Extensions.folded(setup.builtins, marks, staying)}#{setup.registry.map { |r| Extensions.fold(r, staying) }.unwrap_or("")}"
    )
  }
end

def resolve(
  state: Session.State,
  approval_id: String,
  decision: Protocol.Decision,
  source: Protocol.ApprovalSource,
) -> Session.State
  found = state.pending.find { |w| w.request.approval_id == approval_id }
  case found
    ok(waiting) ->
      _ = waiting.reply.send(decision, 0)
      asked = waiting.request
      name = Protocol.decision_name(decision)
      approver = state.setup.approver.map { |a| a.answered.call(name, asked.tool, asked.preview) }
      next_state = state.with(
        setup: state.setup.with(approver: approver),
        pending: state.pending.select { |w| w.request.approval_id != approval_id },
        resolved: state.resolved.push(approval_id),
      )

      resolved = Protocol.ApprovalResolved(approval_id: approval_id, decision: decision, source: source)
      Stream.emit(next_state, Protocol.Event.ApprovalResolved(resolved))
    error(_) -> state
  end
end

# Messages queued for a stopped turn are not sent; an `error` event says so.
def dropped(state: Session.State) -> Session.State
  return state if state.queued.empty?

  message = "#{state.queued.size} queued message(s) were not sent: the turn stopped first"
  failure = Protocol.Failure(kind: Protocol.KIND_QUEUE_DROPPED, message: message)
  Stream.emit(state.with(queued: []), Protocol.Event.Error(failure))
end

# Messages that came after the turn's last read start the next turn, together. When the first of them is a wake, it
# starts the turn and counts; a user's first message takes the parked wakes before its own.
def next_turn(state: Session.State) -> Session.State
  return state if state.queued.empty?
  return Stream.unsent(state) if state.broken.some?

  first: Optional[String] = none
  for waiting in state.queued.take(1)
    first = waiting.source
  end

  ignored: Channel[Result[Protocol.MessageAccepted]] = Channel.new(1)
  started = start_turn(state.with(queued: []), texts(state.queued).join("\n\n"), ignored, first)
  return Stream.unsent(started.with(queued: state.queued)) if started.turn.none?

  # The turn starts with all of them, as one message: each is delivered now. A client that attaches meanwhile gets the
  # history without it, and draws them from the events.
  started = started.with(turn: started.turn.map { |t| t.with(shown: t.shown - 1) })
  for waiting in state.queued
    started = delivered(started, waiting.id, waiting.text)
  end

  started
end

# The headers of the provider's calls, with the id of the session where they ask for it.
def headers_of(setup: Session.Setup) -> Map[String, String]
  out: Map[String, String] = {}
  for name in setup.headers.keys
    out = out.put(name, setup.headers[name].replace("${session}", setup.id))
  end

  out
end

def compact_model(setup: Session.Setup) -> String
  return setup.model if setup.compact_model.empty?

  setup.compact_model
end

def answer_so_far(state: Session.State) -> Session.State
  for turn in option_list(state.turn)
    text = turn.texts.join("\n\n")
    next if text.empty?

    case Stream.save(state, -> { Store.append_answer(state.setup.file, text) })
      ok(_) ->
        answer = Protocol.Message(role: Protocol.Role.Assistant, text: text)
        return state.with(display: state.display.push(answer), turn: some(turn.with(texts: [])))
      error(e) -> return Stream.broke(state, e)
    end
  end

  state
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
