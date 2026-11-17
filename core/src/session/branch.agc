## The tree of a session's file: going on from an earlier entry (`branch`) and copying a branch into a new session.

import Actor from "std/actor"
import Protocol from "pkg/protocol/protocol"
import Session from "state"
import Store from "store"
import Stream from "stream"

## The branch record goes first: when the load after it fails, the session goes on from there once it loads again.
def branch_to(state: Session.State, entry: Int, reply: Channel[Result[Protocol.Branched]]) -> Session.State
  if Session.busy?(state)
    Actor.reply(reply, error(Session.busy_reason(state), kind: Protocol.KIND_SESSION_BUSY))
    return state
  end

  case moved(state, entry)
    ok(pair) ->
      Actor.reply(reply, ok(Protocol.Branched(id: state.setup.id, text: pair.text)))
      resynced(pair.state)
    error(e) ->
      Actor.reply(reply, error(e))
      return state.with(broken: some(e.message)) if e.kind == Protocol.KIND_SESSION_STORAGE

      state
  end
end

## The tree of the session's file, read only past what the session read of it before.
def indexed(state: Session.State) -> Result[Session.State]
  ok(state.with(entries: some(try Store.entries(state.setup.file, state.entries))))
end

def copied(state: Session.State, entry: Optional[Int], to: Session.Copying) -> Result[Session.Copied]
  return error(Session.busy_reason(state), kind: Protocol.KIND_SESSION_BUSY) if Session.busy?(state)

  point = try Store.point(try Store.entries(state.setup.file, state.entries), entry)
  file = try Store.copy(state.setup.file, to.dir, to.header, point.leaf)
  settings = Store.append_settings(file, Session.choice(state.setup))
  if not settings.ok?
    _ = Store.remove(file)
  end

  try settings
  ok(Session.Copied(file: file, text: point.text))
end

private

struct Moved
  state: Session.State
  text: String
end

def moved(state: Session.State, entry: Int) -> Result[Moved]
  file = state.setup.file
  known = try indexed(state)
  point = try Store.point(known.entries.unwrap!, some(entry))
  # Read before the branch is written, so a session whose file follows the branch always has its state.
  saved = try Store.load(file, some(point.leaf))
  until = state.counter + 1
  case Stream.save(state, -> { Store.append_branch(file, point.leaf, until) })
    ok(_) -> nil
    error(e) -> return error("the session file cannot be written: #{e.message}", kind: Protocol.KIND_SESSION_STORAGE)
  end

  on_branch = known.with(
    history: saved.history,
    display: saved.shown,
    marks: saved.marks,
    stripped: saved.stripped,
    context: Session.last_usage(saved.events).context,
    todos: Session.last_todos(saved.events),
    shells: saved.shells,
    counter: until,
    reserved: until,
    broken: none,
  )

  ok(Moved(state: on_branch, text: point.text))
end

# The events so far are of another branch: a client that attaches from one of them gets `resync`, and so do the
# clients attached now, which read the session again.
def resynced(state: Session.State) -> Session.State
  for out in state.subscribers
    _ = out.send(Stream.frame("", Protocol.Event.Resync).bytes, 0)
    out.close
  end

  state.with(log: [], lost_below: state.counter, lost: none, subscribers: [])
end
