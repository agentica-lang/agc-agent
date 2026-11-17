## The events of a session: each goes to the session's file, then to every subscriber; a client that attaches
## replays what the session keeps.

import Actor from "std/actor"
import Protocol from "pkg/protocol/protocol"
import SSE from "pkg/sse/sse"
import Session from "state"
import Store from "store"

## Room in a subscriber's channel past its replay; a client that falls this far behind is dropped.
LIVE_ROOM = 1024
RESERVE = 1000

def attach(state: Session.State, last: Optional[Int], reply: Channel[Channel[Bytes]]) -> Session.State
  from = last.unwrap_or(state.counter)
  first = state.counter + 1
  if not state.log.empty?
    first = state.log[0].id
  end

  replay: List[String] = []
  if from > state.counter or from < first - 1 or from < state.lost_below
    replay = [frame("", Protocol.Event.Resync)]
  else
    replay = lost_after(state, from)
    for logged in (state.log.select { |l| l.id > from })
      replay = replay.push(frame(Protocol.format_event_id(logged.id), logged.event)) + lost_after(state, logged.id)
    end
  end

  out: Channel[Bytes] = Channel.new(replay.size + LIVE_ROOM)
  for text in replay
    _ = out.send(text.bytes, 0)
  end

  Actor.reply(reply, out)
  prune(state.with(subscribers: state.subscribers.push(out)))
end

## Drops the clients that left, and notes when the last one did.
def prune(state: Session.State) -> Session.State
  live = state.subscribers.select { |out| not out.closed? }
  return state.with(subscribers: live, alone_since: none) if not live.empty?
  return state.with(subscribers: live) if state.alone_since.some?

  state.with(subscribers: live, alone_since: some(Time.monotonic_ms))
end

def frame(id: String, event: Protocol.Event) -> String
  sse = SSE.Event(name: Protocol.event_name(event), data: Protocol.encode_event(event), id: id)
  SSE.encode(sse).unwrap_or("")
end

## A `usage` of one call goes out with the session's output and cost so far, which count it once it is saved, and the
## model's window when it is known; `call_output` keeps the call's own output. A call that a stop cut is not counted:
## its `usage` comes after the turn ended, if at all.
def emit_counted(state: Session.State, event: Protocol.Event) -> Session.State
  case event
    Protocol.Event.Usage(usage) ->
      output = state.output + usage.output
      cost = state.cost
      turn_cost = state.turn_cost
      for call in option_list(usage.cost)
        cost = some(cost.unwrap_or(0.0) + call)
        turn_cost = turn_cost + call
      end

      window: Optional[Int] = none
      if state.window > 0
        window = some(state.window)
      end

      counted = usage.with(
        output: output,
        turn_cost: cost.map { |_| turn_cost },
        session_cost: cost,
        window: window,
        call_output: some(usage.output),
      )

      emitted = emit(state, Protocol.Event.Usage(counted))
      return emitted if emitted.counter == state.counter

      emitted.with(output: output, context: usage.context, usage: some(counted), cost: cost, turn_cost: turn_cost)
    _ -> emit(state, event)
  end
end

def emit(state: Session.State, event: Protocol.Event) -> Session.State
  id = state.counter + 1
  logged = Store.Logged(id: id, event: event)
  case save(state, -> { saved_event(state, logged) })
    ok(_) ->
      live = broadcast(state, frame(Protocol.format_event_id(id), event))
      reserved = id
      if delta?(event)
        reserved = [state.reserved, id + RESERVE - 1].max.unwrap!
        if id <= state.reserved
          reserved = state.reserved
        end
      end

      log = trim(state.log.push(logged), state)
      prune(state.with(counter: id, log: log, subscribers: live, broken: none, reserved: reserved))
    error(e) -> broke(state, e)
  end
end

## After a failed write, the next one starts on a new line.
def save(state: Session.State, write: Fn[Result[Void]]) -> Result[Void]
  if state.broken.some?
    try Store.reopen(state.setup.file)
  end

  write.call()
end

def broadcast(state: Session.State, text: String) -> List[Channel[Bytes]]
  state.subscribers.select { |out| out.send(text.bytes, 0).ok? or close(out) }
end

## A write failed: the clients are told without an id, which only a saved event gets, and the running turn stops.
def broke(state: Session.State, e: Error) -> Session.State
  message = "the session file cannot be written: #{e.message}"
  IO.warn("session #{state.setup.id}: #{message}")
  failure = Protocol.Failure(kind: Protocol.KIND_SESSION_STORAGE, message: message)
  error_frame = frame("", Protocol.Event.Error(failure))
  out = state.with(broken: some(message), subscribers: broadcast(state, error_frame))
  case out.turn
    some(turn) ->
      Task.cancel(turn.task)
      # The denials are not events: a write to a file that just failed would fail too. The turn ends, so none of its
      # approvals can be answered; after a restart the turn and its approvals end as when a restart cuts a turn.
      for waiting in out.pending
        _ = waiting.reply.send(Protocol.Decision.Deny, 0)
      end

      cancelled = Protocol.TurnFinished(
        turn_id: turn.id,
        stop_reason: Protocol.StopReason.Cancelled,
        history_size: some(out.display.size),
      )

      end_frame = frame("", Protocol.Event.TurnFinished(cancelled))
      frames = [error_frame] + drop_frames(out) + [end_frame]
      lost = Session.Lost(to: out.counter, frames: frames)
      live = out.subscribers
      for each in frames.drop(1)
        live = broadcast(out.with(subscribers: live), each)
      end

      out.with(turn: none, pending: [], queued: [], subscribers: live, lost: some(lost))
    none -> unsent(out)
  end
end

## The queue of a session whose file cannot be written goes: an `error` event without an id says so.
def unsent(state: Session.State) -> Session.State
  live = state.subscribers
  for each in drop_frames(state)
    live = broadcast(state.with(subscribers: live), each)
  end

  state.with(queued: [], subscribers: live)
end

private

# The frames a failed write lost right after event `id`.
def lost_after(state: Session.State, id: Int) -> List[String]
  case state.lost
    some(lost) if lost.to == id -> lost.frames
    _ -> []
  end
end

# A delta is not saved; one past the saved or reserved ids reserves the next block.
def saved_event(state: Session.State, logged: Store.Logged) -> Result[Void]
  return Store.append_event(state.setup.file, logged) if not delta?(logged.event)
  return ok() if logged.id <= state.reserved

  Store.append_reserved(state.setup.file, logged.id + RESERVE - 1)
end

def delta?(event: Protocol.Event) -> Bool
  case event
    Protocol.Event.TextDelta(_), Protocol.Event.ThinkingDelta(_) -> true
    _ -> false
  end
end

def close(out: Channel[Bytes]) -> Bool
  out.close
  false
end

def trim(log: List[Store.Logged], state: Session.State) -> List[Store.Logged]
  keep_from = state.turn.map { |t| t.from_event_id }.unwrap_or(state.counter + 1)
  drop = 0
  while log.size - drop > state.setup.keep_events and log[drop].id <= keep_from
    drop = drop + 1
  end

  log.drop(drop)
end

def drop_frames(state: Session.State) -> List[String]
  return [] if state.queued.empty?

  message = "#{state.queued.size} queued message(s) were not sent: the session file cannot be written"
  [frame("", Protocol.Event.Error(Protocol.Failure(kind: Protocol.KIND_QUEUE_DROPPED, message: message)))]
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
