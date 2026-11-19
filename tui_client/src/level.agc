## The thinking level: F2 picks the next one, sent one change at a time.

import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import State from "state"

## The thinking levels F2 goes through, none for the model's default.
LEVELS: List[Optional[String]] = [none, some("low"), some("medium"), some("high")]

## F2: the next thinking level; the rules take its color at once.
def leveled(app: State.Model) -> State.Model
  at = LEVELS.find_index { |level| level == app.effort }.unwrap_or(0)
  wanted = app.with(effort: LEVELS[(at + 1) % LEVELS.size])
  return wanted if wanted.level_sending.some?

  send_level(wanted)
end

## A level wanted while the change was on its way goes next; the note comes once the level settles, and a failure
## with nothing newer wanted goes back to the server's level.
def level_reply(app: State.Model, result: Result[Void]) -> State.Model
  # A reply after /new or a switch belongs to the session before.
  return app if app.level_sending.none?

  sent = app.level_sending.unwrap_or("")
  done = app.with(level_sending: none)
  if result.ok?
    done = done.with(confirmed: State.level_of(sent))
  end

  return send_level(done) if State.level_name(app.effort) != sent

  case result
    ok(_) -> State.noted(done, "thinking #{sent} from the next turn")
    error(e) -> State.noted(done.with(effort: done.confirmed), "error: the thinking level was not set: #{e.message}")
  end
end

private

def send_level(app: State.Model) -> State.Model
  name = State.level_name(app.effort)
  backend = app.backend
  id = app.id
  change = Protocol.UpdateSession(effort: some(name))
  State.effect(
    app.with(level_sending: some(name)),
    TUI.Cmd.Run(-> { State.Msg.Leveled(backend.update_session.call(id, change)) }),
  )
end
