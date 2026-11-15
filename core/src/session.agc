## A session: an actor that owns the history, the events and the running turn. HTTP handlers and the turn's task send
## it messages; every subscriber gets the same events.
##
## The events are numbered from 1. The session keeps the last `keep_events` of them, and every event of the running
## turn however many, so a client that attaches from `turn_from_event_id` replays the whole turn. A `Last-Event-ID`
## outside what it keeps gets `resync`.

import Actor from "std/actor"
import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import SSE from "pkg/sse/sse"
import Agent from "agent"
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
end

enum Msg
  Snapshot(Channel[Protocol.Session])
  Subscribe(Optional[Int], Channel[Channel[Bytes]])
  Send(String, Channel[Result[String]])
  Answer(String, Protocol.Decision, Channel[Result[Void]])
  Stop(Channel[Bool])
  Emit(String, Protocol.Event)
  Ask(String, Protocol.ApprovalRequested, Channel[Protocol.Decision])
  Expire(String, String)
  Commit(String, List[LLM.Message])
  Finished(String, Protocol.StopReason)
end

struct Logged
  id: Int
  event: Protocol.Event
end

struct Waiting
  request: Protocol.ApprovalRequested
  reply: Channel[Protocol.Decision]
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
  log: List[Logged] = []
  subscribers: List[Channel[Bytes]] = []
  history: List[LLM.Message] = []
  display: List[Protocol.Message] = []
  turn: Optional[Running] = none
  turns: Int = 0
  pending: List[Waiting] = []
  resolved: List[String] = []
  allowed: List[String] = []
end

def start(setup: Setup) -> Actor.Ref[State, Msg]
  Actor.start(Actor.Behaviour(init: -> { State(setup: setup) }, handle: &handle, terminate: some(&terminate)))
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
    Msg.Ask(turn_id, request, reply) -> Actor.continue(if_current(state, turn_id, ->(s) { ask(s, request, reply) }))
    Msg.Expire(turn_id, approval_id) -> Actor.continue(if_current(state, turn_id, ->(s) { expire(s, approval_id) }))
    Msg.Commit(turn_id, history) -> Actor.continue(if_current(state, turn_id, ->(s) { s.with(history: history) }))
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
  state.with(subscribers: state.subscribers.push(out))
end

def frame(id: String, event: Protocol.Event) -> String
  sse = SSE.Event(name: Protocol.event_name(event), data: Protocol.encode_event(event), id: id)
  SSE.encode(sse).unwrap_or("")
end

def emit(state: State, event: Protocol.Event) -> State
  id = state.counter + 1
  text = frame(Protocol.format_event_id(id), event)
  live = state.subscribers.select { |out| out.send(text.bytes, 0).ok? or close(out) }
  log = trim(state.log.push(Logged(id: id, event: event)), state)
  state.with(counter: id, log: log, subscribers: live)
end

def close(out: Channel[Bytes]) -> Bool
  out.close
  false
end

def trim(log: List[Logged], state: State) -> List[Logged]
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

  turn_id = "turn-#{state.turns + 1}"
  inbox: Channel[Msg] = Actor.inbox
  address = inbox.address
  setup = state.setup
  link = Agent.Link(
    emit: ->(event) { _ = Actor.cast(address, Msg.Emit(turn_id, event), CALL_MS) },
    approve: ->(request) { wait_approval(address, turn_id, request, setup.approval_timeout_ms) },
    commit: ->(history) { _ = Actor.cast(address, Msg.Commit(turn_id, history), CALL_MS) },
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
  user = Protocol.Message(role: Protocol.Role.User, text: text)
  started = state.with(turn: some(running), turns: state.turns + 1, display: state.display.push(user))
  Actor.reply(reply, ok(turn_id))
  emit(started, Protocol.Event.TurnStarted(Protocol.TurnStarted(turn_id: turn_id)))
end

def run_turn(job: Job) -> Void
  outcome = Agent.run(job.turn)
  _ = Actor.cast(job.address, Msg.Finished(job.turn.id, outcome.reason), CALL_MS)
end

# With a client attached, an approval waits for its answer; with none, it is denied after `timeout_ms`.
def wait_approval(
  address: Address[Msg],
  turn_id: String,
  request: Protocol.ApprovalRequested,
  timeout_ms: Int,
) -> Protocol.Decision
  reply: Channel[Protocol.Decision] = Channel.new(1)
  _ = Actor.cast(address, Msg.Ask(turn_id, request, reply), CALL_MS)
  while true
    case reply.recv(timeout_ms)
      ok(decision) -> return decision
      error(_) if reply.closed? -> return Protocol.Decision.Deny
      error(_) -> _ = Actor.cast(address, Msg.Expire(turn_id, request.approval_id), CALL_MS)
    end
  end

  Protocol.Decision.Deny
end

def ask(state: State, request: Protocol.ApprovalRequested, reply: Channel[Protocol.Decision]) -> State
  if state.allowed.include?(approval_key(request))
    _ = reply.send(Protocol.Decision.Allow, 0)
    return state
  end

  waiting = state.with(pending: state.pending.push(Waiting(request: request, reply: reply)))
  emit(waiting, Protocol.Event.ApprovalRequested(request))
end

def approval_key(request: Protocol.ApprovalRequested) -> String = "#{request.tool}\n#{request.preview}"

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

def expire(state: State, approval_id: String) -> State
  return state if not state.subscribers.empty?

  resolve(state, approval_id, Protocol.Decision.Deny, Protocol.ApprovalSource.Timeout)
end

def resolve(state: State, approval_id: String, decision: Protocol.Decision, source: Protocol.ApprovalSource) -> State
  found = state.pending.find { |w| w.request.approval_id == approval_id }
  case found
    ok(waiting) ->
      _ = waiting.reply.send(decision, 0)
      allowed = state.allowed
      if decision == Protocol.Decision.AllowSession
        allowed = allowed.push(approval_key(waiting.request))
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
    some(turn) ->
      finished = Protocol.Event.TurnFinished(Protocol.TurnFinished(turn_id: turn.id, stop_reason: reason))
      texts = state.history.drop(turn.first_message + 1).select { |m| m.role == LLM.Role.Assistant }
      text = texts.map { |m| Agent.assistant_text(m) }.select { |t| not t.empty? }.join("\n\n")
      display = state.display
      if not text.empty?
        display = display.push(Protocol.Message(role: Protocol.Role.Assistant, text: text))
      end

      emit(state.with(display: display), finished).with(turn: none)
    none -> state
  end
end
