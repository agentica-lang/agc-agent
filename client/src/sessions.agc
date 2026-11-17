## What both clients decide the same way about a session: the request that opens one, where the events after a
## snapshot are read from, and what a client says of its thinking level, of a compaction and, on leaving, of how to
## come back.

import Protocol from "pkg/protocol/protocol"

## A new session in `cwd`, else the folder the client runs in.
def new_session(
  cwd: Optional[String],
  model: Optional[String],
  api: Optional[String],
  provider: Optional[String],
  profile: Optional[String] = none,
) -> Result[Protocol.NewSession]
  folder = case cwd
    some(dir) -> dir
    none -> try Path.cwd()
  end

  ok(Protocol.NewSession(cwd: folder, model: model, api: api, provider: provider, profile: profile))
end

## The event id to read the stream of `session` after: while a turn runs, the start of the turn, so the client gets
## the whole turn; with `skip_replay` (a server that no longer has that start), and when no turn runs, what comes next.
def replay_from(session: Protocol.Session, skip_replay: Bool) -> Int
  return session.last_event_id if skip_replay

  session.turn_from_event_id.unwrap_or(session.last_event_id)
end

## How to come back to session `id` with `command` (`finn`, `finn chat`); none for a session with nothing in it yet.
def resume_hint(command: String, id: String, empty: Bool) -> Optional[String]
  return none if empty or id == ""

  some("to come back: #{command} --session #{id}")
end

## The thinking level of `session`, as a client says it.
def thinking(session: Protocol.Session) -> String = "thinking #{session.effort.unwrap_or("as the model's default")}"

## What a compaction did: `folded` the history, or found nothing to fold.
def compacted(folded: Bool) -> String
  return "compacted" if folded

  "nothing to compact yet"
end
