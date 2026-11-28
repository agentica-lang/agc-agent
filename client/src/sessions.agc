## What both clients decide the same way about a session: the request that opens one, where the events after a
## snapshot are read from, and what a client says of its thinking level, of a compaction and, on leaving, of how to
## come back.

import Protocol from "pkg/protocol/protocol"
import Commands from "commands"

## A new session in `cwd`, else the folder the client runs in.
def new_session(
  cwd: Optional[String],
  model: Optional[String],
  api: Optional[String],
  provider: Optional[String],
  profile: Optional[String] = none,
  remember: Bool = false,
) -> Result[Protocol.NewSession]
  folder = case cwd
    some(dir) -> dir
    none -> try Path.cwd()
  end

  ok(
    Protocol.NewSession(
      cwd: folder,
      model: model,
      api: api,
      provider: provider,
      profile: profile,
      remember: some(remember),
    ),
  )
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

## Whether the file tools of `session` stay in its folder, as a client says it.
def confined(session: Protocol.Session) -> String
  return "the file tools stay in the session folder (/confine off lets them reach any path)" if session.confine

  "the file tools reach any path (/confine on keeps them in the session folder)"
end

## What a compaction did: `folded` the history, or found nothing to fold.
def compacted(folded: Bool) -> String
  return "compacted" if folded

  "nothing to compact yet"
end

## `child s2` for the child session `id`, as both clients name it.
def child_label(id: String) -> String = "child #{id}"

## Who sent a wake or a queued message with `source` (`child:ID` for a child's answer, `extension` otherwise), as
## both clients name it. An async child's answer wakes with `extension`: the clients name the source they are given
## and never guess a child from the wake's text.
def wake_label(source: String) -> String
  return child_label(source.slice(6, source.length - 6)) if source.start_with?("child:")

  source
end

## What both clients show for a started or delivered wake with `source`: who answered, never its text, so a child's
## answer never reads as typed input.
def wake_note(source: String) -> String = "#{wake_label(source)} answered"

## What both clients show above the prompt for a message that waits: a wake reads as who answered, never as typed
## text; a user's own message reads as what it says.
def waiting_line(text: String, source: Optional[String]) -> String
  for sent in option_list(source)
    return wake_note(sent)
  end

  "queued: #{Commands.printable(text)}"
end

private

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
