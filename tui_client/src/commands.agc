## The slash commands that move between sessions or change one, and the pickers they open.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import Picker from "picker"
import State from "state"
import Logins from "logins"
import Turn from "turn"
import Session from "session"

def on_picker_key(app: State.Model, picker: Picker.Picker, event: TUI.Event) -> State.Model
  case Picker.key(picker, event)
    Picker.Step.Stay(next_picker) -> app.with(picker: some(next_picker))
    Picker.Step.Close if picker.kind == Picker.Kind.Logins -> Logins.login_closed(app.with(picker: none))
    Picker.Step.Close -> app.with(picker: none)
    Picker.Step.Pick(key) if picker.kind == Picker.Kind.Logins ->
      Logins.login_picked(app.with(picker: none), picker, key)
    Picker.Step.Pick(key) -> picked(app.with(picker: none), picker.kind, key)
  end
end

def on_command(app: State.Model, command: Client.Command) -> State.Model
  case command
    Client.Command.Quit -> app.with(exit: some(0))
    Client.Command.Stop -> stop_command(app)
    Client.Command.Help -> app.with(entries: app.entries + Client.help().map { |line| State.note_entry(line) })
    Client.Command.Cost -> State.noted(app, "/cost comes with the model catalog")
    Client.Command.New -> switch_command(app, none)
    Client.Command.Resume(none) -> State.tried(app, picking(app))
    Client.Command.Resume(choice) -> switch_command(app, choice)
    Client.Command.Tree(choice) -> State.tried(app, tree_command(app, Picker.Kind.Tree, choice))
    Client.Command.Fork(choice) -> State.tried(app, tree_command(app, Picker.Kind.Fork, choice))
    Client.Command.Clone -> move(app, Picker.Kind.Fork, none)
    Client.Command.Export(path, force) -> export_command(app, path, force)
    Client.Command.Model(model) -> model_command(app, model)
    Client.Command.Thinking(level) -> thinking_command(app, level)
    Client.Command.Compact -> compact_command(app)
    Client.Command.Login(name) -> Logins.login_command(app, name)
    Client.Command.Logout(name) -> State.tried(app, Logins.logout_command(app, name))
  end
end

## Writes the session's branch to a file in a task; `exported` says where.
def export_command(app: State.Model, path: Optional[String], force: Bool) -> State.Model
  return State.noted(app, "no session to export yet") if app.id == ""

  backend = app.backend
  id = app.id
  State.effect(
    app,
    TUI.Cmd.Run(
      -> {
        written = case backend.exported.call(id)
          ok(exported) -> Client.saved(exported, Client.export_path(id, path), force)
          error(e) -> error(e)
        end

        State.Msg.Exported(written)
      },
    ),
  )
end

## Where the export went, or why it did not.
def exported(app: State.Model, result: Result[String]) -> State.Model
  case result
    ok(file) -> State.noted(app, "exported to #{Client.printable(file)}")
    error(e) -> State.noted(app, "error: the session was not exported: #{Client.printable(e.message)}")
  end
end

## The session is drawn again from its start; the message it went back before waits in the prompt.
def moved(app: State.Model, result: Result[Protocol.Branched]) -> State.Model
  case result
    ok(done) ->
      opened = State.tried(app.with(moving: false), Session.resume(Session.fresh(app), done.id))
      return opened if done.text.empty?

      # Follow-ups put back in the prompt stay after the message; typing then adds to both.
      if opened.prompt != ""
        both = "#{done.text}\n#{opened.prompt}"
        return State.noted(
          opened.with(prompt: both, cursor: both.length, goal_column: none),
          "went back before a message: it is in the prompt",
        )
      end

      filled = opened.with(prompt: done.text, cursor: done.text.length, goal_column: none, prefilled: true)
      State.noted(filled, "went back before a message: it is in the prompt (typing replaces it, an arrow keeps it)")
    error(e) -> State.noted(app.with(moving: false), "error: #{e.message}")
  end
end

private

def stop_command(app: State.Model) -> State.Model
  return State.noted(app, "no turn is running") if not State.busy?(app)

  Turn.stop(app)
end

# A new session (no choice), or the session `/resume` chose.
def switch_command(app: State.Model, choice: Optional[String]) -> State.Model
  return State.noted(app, "a turn is running: Esc stops it first") if app.turn
  return State.noted(app, "a message is being sent: wait for its reply first") if not app.outbox.empty?

  case choice
    some(picked) -> State.tried(app, switched(app, picked))
    none -> State.tried(app, Session.create(Session.fresh(app)))
  end
end

def picking(app: State.Model) -> Result[State.Model]
  list = try app.backend.list_sessions.call()
  return ok(State.noted(app, "no sessions")) if list.sessions.empty?

  ok(app.with(picker: some(Picker.Picker(sessions: list.sessions))))
end

def picked(app: State.Model, kind: Picker.Kind, key: String) -> State.Model
  return model_command(app, some(key)) if kind == Picker.Kind.Models

  case key.to_i
    ok(entry) if kind != Picker.Kind.Sessions -> move(app, kind, some(entry))
    _ -> switch_command(app, some(key))
  end
end

# The picker of the tree without a choice; else the move to the message the choice names in the tree the picker
# showed last (`/tree 2`, `/fork 1+`), so a message another client adds since does not change what a number names.
def tree_command(app: State.Model, kind: Picker.Kind, choice: Optional[String]) -> Result[State.Model]
  for picked in State.option_list(choice)
    return ok(State.noted(app, "open the list first: /tree")) if app.listed.none?

    return ok(move(app, kind, some(try Client.tree_entry(app.listed.unwrap!, picked))))
  end

  tree = try app.backend.tree.call(app.id)
  return ok(State.noted(app, "no messages yet")) if tree.nodes.empty?

  ok(app.with(picker: some(Picker.Picker(tree: Client.tree_rows(tree), kind: kind)), listed: some(tree)))
end

# A branch of this session from `entry` (`Kind.Tree`), or a new session from it (`Kind.Fork`), a copy when none. A
# command asks for it and `moved` opens the session it gives.
def move(app: State.Model, kind: Picker.Kind, entry: Optional[Int]) -> State.Model
  return State.noted(app, "a turn is running: Esc stops it first") if app.turn
  return State.noted(app, "a message is being sent: wait for its reply first") if not app.outbox.empty?
  return State.noted(app, "the session is moving: wait for it") if app.moving

  backend = app.backend
  id = app.id
  moving = app.with(moving: true)
  case kind
    Picker.Kind.Tree ->
      at = entry.unwrap_or(0)
      State.effect(moving, TUI.Cmd.Run(-> { State.Msg.Moved(backend.branch.call(id, at)) }))
    _ -> State.effect(moving, TUI.Cmd.Run(-> { State.Msg.Moved(backend.fork.call(id, entry)) }))
  end
end

def switched(app: State.Model, choice: String) -> Result[State.Model]
  Session.resume(Session.fresh(app), try Client.pick(try app.backend.list_sessions.call(), choice))
end

def thinking_command(app: State.Model, level: Optional[String]) -> State.Model
  case level
    some(text) ->
      State.tried(app, changed(app, Protocol.UpdateSession(effort: level), "thinking #{text} from the next turn"))
    none -> State.tried(app, shown_thinking(app))
  end
end

def shown_thinking(app: State.Model) -> Result[State.Model]
  ok(State.noted(app, Client.thinking(try app.backend.session.call(app.id))))
end

# `/model` opens the picker; `/model provider/model` moves the session to that provider when one has that name, else
# `/model NAME` changes the model.
def model_command(app: State.Model, given: Optional[String]) -> State.Model
  case given
    some(text) -> State.tried(app, model_changed(app, text))
    none -> State.tried(app, model_picking(app))
  end
end

def model_picking(app: State.Model) -> Result[State.Model]
  list = try app.backend.list_providers.call()
  ok(app.with(picker: some(Picker.models(list, app.serving))))
end

def model_changed(app: State.Model, text: String) -> Result[State.Model]
  current = app.serving.split("/")[0]
  change = Client.model_change(try app.backend.list_providers.call(), current, text)
  done = try changed(app, change, "model #{text} from the next turn")
  ok(done.with(serving: State.serving_of(try app.backend.session.call(app.id))))
end

def changed(app: State.Model, change: Protocol.UpdateSession, done: String) -> Result[State.Model]
  try app.backend.update_session.call(app.id, change)
  shown = State.noted(app, done)
  for effort in State.option_list(change.effort)
    shown = shown.with(effort: State.level_of(effort), confirmed: State.level_of(effort))
  end

  return ok(shown) if change.model.none?

  ok(shown.with(new_model: change.model))
end

# The summary takes as long as a turn: a command asks for it and gives the outcome as a note.
def compact_command(app: State.Model) -> State.Model
  backend = app.backend
  id = app.id
  State.noted(State.effect(app, TUI.Cmd.Run(-> { State.Msg.Note(compacted(backend, id)) })), "compacting the history")
end

def compacted(backend: Client.Backend, id: String) -> String
  case backend.compact.call(id)
    ok(folded) -> Client.compacted(folded)
    error(e) -> "error: #{e.message}"
  end
end
