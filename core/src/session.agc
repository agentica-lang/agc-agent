## A session: an actor that owns the history, the events and the running turn. HTTP handlers and the turn's task send
## it messages; every subscriber gets the same events.
##
## The events are numbered from 1. The session keeps the last `keep_events` of them, and every event of the running
## turn however many, so a client that attaches from `turn_from_event_id` replays the whole turn. A `Last-Event-ID`
## outside what it keeps gets `resync`.
##
## Every event and message goes to the session's file before a client sees it, so a session started again from its
## file keeps its ids. A turn that a restart cut ends then as `cancelled`. When a write fails, the event gets no id:
## the clients get an `error` without one, the running turn stops, and no turn starts until a write works again.

import Actor from "std/actor"
import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import SSE from "pkg/sse/sse"
import Agent from "agent"
import Store from "store"
import Tools from "tools"

CALL_MS = 5000
## Room in a subscriber's channel past its replay; a client that falls this far behind is dropped.
LIVE_ROOM = 1024

struct Setup
  id: String
  cwd: String
  model: String
  provider: LLM.Provider
  system: String
  ctx: Tools.Context
  keep_events: Int
  approval_timeout_ms: Int
  file: String
end

enum Msg
  Snapshot(Channel[Protocol.Session])
  Subscribe(Optional[Int], Channel[Channel[Bytes]])
  Send(String, Channel[Result[String]])
  Answer(String, Protocol.Decision, Channel[Result[Void]])
  Stop(Channel[Bool])
  Emit(String, Protocol.Event)
  Ask(String, Agent.Ask, Channel[Protocol.Decision])
  Expire(String)
  Commit(String, List[LLM.Message])
  Finished(String, Protocol.StopReason)
end

struct Waiting
  request: Protocol.ApprovalRequested
  reply: Channel[Protocol.Decision]
  key: String
  asked_ms: Int
end

struct Running
  id: String
  task: Task[Void]
  from_event_id: Int
  first_message: Int
end

struct State
  setup: Setup
  counter: Int = 0
  log: List[Store.Logged] = []
  subscribers: List[Channel[Bytes]] = []
  history: List[LLM.Message] = []
  display: List[Protocol.Message] = []
  turn: Optional[Running] = none
  turns: Int = 0
  pending: List[Waiting] = []
  approvals: Int = 0
  ## The approvals answered, so a late answer is told it came late.
  resolved: List[String] = []
  ## The `tool` and target pairs that `allow_session` allowed.
  allowed: List[String] = []
  ## Since when no client is attached.
  alone_since: Optional[Int] = none
  ## Why the last write to the file failed; none once one works.
  broken: Optional[String] = none
end

## Starts a session; from what its file saved when there is one.
def start(setup: Setup, saved: Optional[Store.Saved] = none) -> Actor.Ref[State, Msg]
  init = -> {
    case saved
      some(s) -> restore(setup, s)
      none -> State(setup: setup)
    end
  }

  Actor.start(Actor.Behaviour(init: init, handle: &handle, terminate: some(&terminate)))
end

def snapshot(address: Address[Msg]) -> Result[Protocol.Session]
  Actor.call(address, CALL_MS) do |reply| Msg.Snapshot(reply) end
end

## The event stream from after `last_event_id` (from now when none), as SSE bytes.
def subscribe(address: Address[Msg], last_event_id: Optional[Int]) -> Result[Channel[Bytes]]
  Actor.call(address, CALL_MS) do |reply| Msg.Subscribe(last_event_id, reply) end
end

## Starts a turn; its id, or `session.busy` while one runs.
def send(address: Address[Msg], text: String) -> Result[String]
  sent: Result[Result[String]] = Actor.call(address, CALL_MS) do |reply| Msg.Send(text, reply) end
  ok(try try sent)
end

def answer(address: Address[Msg], approval_id: String, decision: Protocol.Decision) -> Result[Void]
  answered: Result[Result[Void]] = Actor.call(address, CALL_MS) do |reply| Msg.Answer(approval_id, decision, reply) end
  try try answered
  ok()
end

## Stops the running turn; whether one ran.
def stop(address: Address[Msg]) -> Result[Bool] = Actor.call(address, CALL_MS) do |reply| Msg.Stop(reply) end

private

struct Job
  turn: Agent.Turn
  address: Address[Msg]
end

# A turn that a restart cut, with its approvals still waiting.
struct Cut
  turn_id: String
  approvals: List[String]
end

def handle(state: State, msg: Msg) -> Actor.Step[State]
  case msg
    Msg.Snapshot(reply) ->
      Actor.reply(reply, session(state))
      Actor.continue(state)
    Msg.Subscribe(last, reply) -> Actor.continue(attach(state, last, reply))
    Msg.Send(text, reply) -> Actor.continue(start_turn(state, text, reply))
    Msg.Answer(approval_id, decision, reply) -> Actor.continue(answer_approval(state, approval_id, decision, reply))
    Msg.Stop(reply) ->
      Actor.reply(reply, state.turn.some?)
      Actor.continue(stop_turn(state))
    Msg.Emit(turn_id, event) -> Actor.continue(if_current(state, turn_id, ->(s) { emit(s, event) }))
    Msg.Ask(turn_id, call, reply) -> Actor.continue(if_current(state, turn_id, ->(s) { ask(s, call, reply) }))
    Msg.Expire(turn_id) -> Actor.continue(if_current(state, turn_id, ->(s) { expire(s) }))
    Msg.Commit(turn_id, history) -> Actor.continue(if_current(state, turn_id, ->(s) { commit(s, history) }))
    Msg.Finished(turn_id, reason) -> Actor.continue(if_current(state, turn_id, ->(s) { finish(s, reason) }))
  end
end

def terminate(state: State) -> Void
  for turn in option_list(state.turn)
    Task.cancel(turn.task)
  end

  for out in state.subscribers
    out.close
  end
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end

# A message of a turn that was stopped is dropped.
def if_current(state: State, turn_id: String, change: Fn[State, State]) -> State
  case state.turn
    some(turn) if turn.id == turn_id -> change.call(state)
    _ -> state
  end
end

def session(state: State) -> Protocol.Session
  Protocol.Session(
    id: state.setup.id,
    cwd: state.setup.cwd,
    model: state.setup.model,
    last_event_id: state.counter,
    turn_id: state.turn.map { |t| t.id },
    turn_from_event_id: state.turn.map { |t| t.from_event_id },
    pending_approvals: state.pending.map { |w| w.request },
    history: state.display,
  )
end

def attach(state: State, last: Optional[Int], reply: Channel[Channel[Bytes]]) -> State
  from = last.unwrap_or(state.counter)
  first = state.counter + 1
  if not state.log.empty?
    first = state.log[0].id
  end

  replay: List[String] = []
  if from > state.counter or from < first - 1
    replay = [frame("", Protocol.Event.Resync)]
  else
    replay = state.log
      .select { |logged| logged.id > from }
      .map { |logged| frame(Protocol.format_event_id(logged.id), logged.event) }
  end

  out: Channel[Bytes] = Channel.new(replay.size + LIVE_ROOM)
  for text in replay
    _ = out.send(text.bytes, 0)
  end

  Actor.reply(reply, out)
  prune(state.with(subscribers: state.subscribers.push(out)))
end

# Drops the clients that left, and notes when the last one did.
def prune(state: State) -> State
  live = state.subscribers.select { |out| not out.closed? }
  return state.with(subscribers: live, alone_since: none) if not live.empty?
  return state.with(subscribers: live) if state.alone_since.some?

  state.with(subscribers: live, alone_since: some(Time.monotonic_ms))
end

def frame(id: String, event: Protocol.Event) -> String
  sse = SSE.Event(name: Protocol.event_name(event), data: Protocol.encode_event(event), id: id)
  SSE.encode(sse).unwrap_or("")
end

def emit(state: State, event: Protocol.Event) -> State
  id = state.counter + 1
  logged = Store.Logged(id: id, event: event)
  case Store.append_event(state.setup.file, logged)
    ok(_) ->
      live = broadcast(state, frame(Protocol.format_event_id(id), event))
      prune(state.with(counter: id, log: trim(state.log.push(logged), state), subscribers: live))
    error(e) -> broke(state, e)
  end
end

def broadcast(state: State, text: String) -> List[Channel[Bytes]]
  state.subscribers.select { |out| out.send(text.bytes, 0).ok? or close(out) }
end

# A write failed: the clients are told without an id, which only a saved event gets, and the running turn stops.
def broke(state: State, e: Error) -> State
  message = "the session file cannot be written: #{e.message}"
  IO.warn("session #{state.setup.id}: #{message}")
  failure = Protocol.Failure(kind: Protocol.KIND_SESSION_STORAGE, message: message)
  out = state.with(broken: some(message), subscribers: broadcast(state, frame("", Protocol.Event.Error(failure))))
  case out.turn
    some(turn) ->
      Task.cancel(turn.task)
      for waiting in out.pending
        _ = waiting.reply.send(Protocol.Decision.Deny, 0)
      end

      cancelled = Protocol.TurnFinished(turn_id: turn.id, stop_reason: Protocol.StopReason.Cancelled)
      live = broadcast(out, frame("", Protocol.Event.TurnFinished(cancelled)))
      out.with(turn: none, pending: [], subscribers: live)
    none -> out
  end
end

def close(out: Channel[Bytes]) -> Bool
  out.close
  false
end

def trim(log: List[Store.Logged], state: State) -> List[Store.Logged]
  keep_from = state.turn.map { |t| t.from_event_id }.unwrap_or(state.counter + 1)
  drop = 0
  while log.size - drop > state.setup.keep_events and log[drop].id <= keep_from
    drop = drop + 1
  end

  log.drop(drop)
end

def start_turn(state: State, text: String, reply: Channel[Result[String]]) -> State
  if state.turn.some?
    Actor.reply(reply, error("a turn is running", kind: Protocol.KIND_SESSION_BUSY))
    return state
  end

  case Store.append_user(state.setup.file, text)
    ok(_) -> nil
    error(e) ->
      Actor.reply(
        reply,
        error("the session file cannot be written: #{e.message}", kind: Protocol.KIND_SESSION_STORAGE),
      )

      return state.with(broken: some(e.message))
  end

  turn_id = "turn-#{state.turns + 1}"
  inbox: Channel[Msg] = Actor.inbox
  address = inbox.address
  setup = state.setup
  link = Agent.Link(
    emit: ->(event) { tell(address, Msg.Emit(turn_id, event)) },
    approve: ->(call) { wait_approval(address, turn_id, call, setup.approval_timeout_ms) },
    commit: ->(history) { tell(address, Msg.Commit(turn_id, history)) },
  )

  turn = Agent.Turn(
    id: turn_id,
    provider: setup.provider,
    model: setup.model,
    system: setup.system,
    history: state.history,
    text: text,
    ctx: setup.ctx,
    link: link,
  )

  task = Task.spawn(&run_turn, Job(turn: turn, address: address))
  running = Running(id: turn_id, task: task, from_event_id: state.counter, first_message: state.history.size)
  started = state.with(
    turn: some(running),
    turns: state.turns + 1,
    history: state.history.push(LLM.Message(role: LLM.Role.User, content: [Agent.text_block(text)])),
    display: state.display.push(Protocol.Message(role: Protocol.Role.User, text: text)),
    broken: none,
  )

  Actor.reply(reply, ok(turn_id))
  emit(started, Protocol.Event.TurnStarted(Protocol.TurnStarted(turn_id: turn_id)))
end

def run_turn(job: Job) -> Void
  outcome = Agent.run(job.turn)
  _ = Actor.cast(job.address, Msg.Finished(job.turn.id, outcome.reason), CALL_MS)
end

# A session that is gone cannot take the turn's events: the turn ends.
def tell(address: Address[Msg], msg: Msg) -> Void
  if not Actor.cast(address, msg, CALL_MS).ok?
    Task.cancel(Task.current)
  end
end

# The session denies an approval once no client has been attached for `timeout_ms`; the turn asks it to check now and
# then.
def wait_approval(address: Address[Msg], turn_id: String, call: Agent.Ask, timeout_ms: Int) -> Protocol.Decision
  reply: Channel[Protocol.Decision] = Channel.new(1)
  return Protocol.Decision.Deny if not Actor.cast(address, Msg.Ask(turn_id, call, reply), CALL_MS).ok?

  poll_ms = [timeout_ms, 1000].min.unwrap!
  while true
    case reply.recv(poll_ms)
      ok(decision) -> return decision
      error(_) if reply.closed? -> return Protocol.Decision.Deny
      error(_) -> return Protocol.Decision.Deny if not Actor.cast(address, Msg.Expire(turn_id), CALL_MS).ok?
    end
  end

  Protocol.Decision.Deny
end

def ask(state: State, call: Agent.Ask, reply: Channel[Protocol.Decision]) -> State
  key = "#{call.tool}\n#{call.target}"
  if state.allowed.include?(key)
    _ = reply.send(Protocol.Decision.Allow, 0)
    return state
  end

  request = Protocol.ApprovalRequested(
    approval_id: "a#{state.approvals + 1}",
    call_id: call.call_id,
    tool: call.tool,
    preview: call.target,
    detail: call.detail,
  )

  waiting = Waiting(request: request, reply: reply, key: key, asked_ms: Time.monotonic_ms)
  asked = state.with(pending: state.pending.push(waiting), approvals: state.approvals + 1)
  emit(asked, Protocol.Event.ApprovalRequested(request))
end

def answer_approval(
  state: State,
  approval_id: String,
  decision: Protocol.Decision,
  reply: Channel[Result[Void]],
) -> State
  if (not state.pending.any? { |w| w.request.approval_id == approval_id })
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

def expire(state: State) -> State
  pruned = prune(state)
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

def resolve(state: State, approval_id: String, decision: Protocol.Decision, source: Protocol.ApprovalSource) -> State
  found = state.pending.find { |w| w.request.approval_id == approval_id }
  case found
    ok(waiting) ->
      _ = waiting.reply.send(decision, 0)
      allowed = state.allowed
      if decision == Protocol.Decision.AllowSession
        allowed = allowed.push(waiting.key)
      end

      next_state = state.with(
        pending: state.pending.select { |w| w.request.approval_id != approval_id },
        resolved: state.resolved.push(approval_id),
        allowed: allowed,
      )

      resolved = Protocol.ApprovalResolved(approval_id: approval_id, decision: decision, source: source)
      emit(next_state, Protocol.Event.ApprovalResolved(resolved))
    error(_) -> state
  end
end

def stop_turn(state: State) -> State
  case state.turn
    some(turn) ->
      Task.cancel(turn.task)
      denied = state
      for waiting in state.pending
        denied = resolve(denied, waiting.request.approval_id, Protocol.Decision.Deny, Protocol.ApprovalSource.Stop)
      end

      finish(denied, Protocol.StopReason.Cancelled)
    none -> state
  end
end

def finish(state: State, reason: Protocol.StopReason) -> State
  case state.turn
    some(turn) -> ended(state, turn.id, turn.first_message, reason).with(turn: none)
    none -> state
  end
end

# Shows the answer of the turn whose user message is at `first_message` of the history, then ends the turn.
def ended(state: State, turn_id: String, first_message: Int, reason: Protocol.StopReason) -> State
  texts = state.history.drop(first_message + 1).select { |m| m.role == LLM.Role.Assistant }
  text = texts.map { |m| Agent.assistant_text(m) }.select { |t| not t.empty? }.join("\n\n")
  shown = state
  if not text.empty?
    case Store.append_answer(state.setup.file, text)
      ok(_) ->
        shown = state.with(display: state.display.push(Protocol.Message(role: Protocol.Role.Assistant, text: text)))
      error(e) -> return broke(state, e)
    end
  end

  emit(shown, Protocol.Event.TurnFinished(Protocol.TurnFinished(turn_id: turn_id, stop_reason: reason)))
end

# The history of a turn only grows, so only its new messages go to the file.
def commit(state: State, history: List[LLM.Message]) -> State
  added = history.drop(state.history.size)
  return state if added.empty?

  case Store.append_messages(state.setup.file, added)
    ok(_) -> state.with(history: history)
    error(e) -> broke(state, e)
  end
end

def restore(setup: Setup, saved: Store.Saved) -> State
  events = saved.events
  state = State(
    setup: setup,
    counter: events.map { |logged| logged.id }.max.unwrap_or(0),
    log: events.drop([events.size - setup.keep_events, 0].max.unwrap!),
    history: saved.history,
    display: saved.shown,
    turns: count(events, Protocol.EventKind.TurnStarted),
    approvals: count(events, Protocol.EventKind.ApprovalRequested),
    resolved: resolved_ids(events),
  )

  case cut_turn(events)
    some(cut) -> end_cut_turn(state, cut)
    none -> state
  end
end

def count(events: List[Store.Logged], kind: Protocol.EventKind) -> Int
  events.select { |logged| Protocol.event_kind(logged.event) == kind }.size
end

def resolved_ids(events: List[Store.Logged]) -> List[String]
  ids: List[String] = []
  for logged in events
    case logged.event
      Protocol.Event.ApprovalResolved(resolved) -> ids = ids.push(resolved.approval_id)
      _ -> nil
    end
  end

  ids
end

def cut_turn(events: List[Store.Logged]) -> Optional[Cut]
  cut: Optional[Cut] = none
  for logged in events
    case logged.event
      Protocol.Event.TurnStarted(started) -> cut = some(Cut(turn_id: started.turn_id, approvals: []))
      Protocol.Event.TurnFinished(_) -> cut = none
      Protocol.Event.ApprovalRequested(request) ->
        cut = cut.map { |c| c.with(approvals: c.approvals.push(request.approval_id)) }
      Protocol.Event.ApprovalResolved(resolved) ->
        cut = cut.map { |c| c.with(approvals: c.approvals.select { |a| a != resolved.approval_id }) }
      _ -> nil
    end
  end

  cut
end

def end_cut_turn(state: State, cut: Cut) -> State
  out = state
  for approval_id in cut.approvals
    resolved = Protocol.ApprovalResolved(
      approval_id: approval_id,
      decision: Protocol.Decision.Deny,
      source: Protocol.ApprovalSource.Stop,
    )

    out = emit(out.with(resolved: out.resolved.push(approval_id)), Protocol.Event.ApprovalResolved(resolved))
  end

  ended(out, cut.turn_id, turn_message(out.history), Protocol.StopReason.Cancelled)
end

# Where the last turn began: its user message is the last one with text (tool results have none).
def turn_message(history: List[LLM.Message]) -> Int
  at = history.size
  for i in 0...history.size
    if (history[i].role == LLM.Role.User and history[i].content.any? { |b| text_block?(b) })
      at = i
    end
  end

  at
end

def text_block?(block: LLM.Block) -> Bool
  case block
    LLM.Block.Text(_) -> true
    _ -> false
  end
end
