## The slash commands that move between sessions or change one, and the pickers they open.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import Picker from "picker"
import Side from "side"
import Sides from "sides"
import State from "state"
import Status from "status"
import Logins from "logins"
import McpPanel from "mcp_panel"
import Turn from "turn"
import Terminal from "terminal"
import Session from "session"

def on_picker_key(app: State.Model, picker: Picker.Picker, event: TUI.Event) -> State.Model
  case Picker.key(picker, event)
    Picker.Step.Stay(next_picker) -> app.with(picker: some(next_picker))
    Picker.Step.Close if picker.kind == Picker.Kind.Logins -> Logins.login_cancelled(app.with(picker: none))
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
    Client.Command.Help -> help_command(Session.with_custom(app.with(custom_dir: none), app.id, app.cwd))
    Client.Command.Shortcuts -> shortcuts_command(app)
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
    Client.Command.Confine(on) -> confine_command(app, on)
    Client.Command.Profile(name) -> State.tried(app, profile_command(app, name))
    Client.Command.Mcp(name, reconnecting) -> mcp_command(app, name, reconnecting)
    Client.Command.Compact -> compact_command(app)
    Client.Command.Logs(count) -> logs_command(app, count)
    Client.Command.Reload -> State.tried(app, reload_command(app))
    Client.Command.Mouse -> mouse_command(app)
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

## The mouse reporting goes off or on: off, the terminal selects text itself, and the app only draws.
def mouse_command(app: State.Model) -> State.Model
  turned = turn_mouse(app, not app.mouse)
  return State.noted(turned, "mouse on: drag to select and copy, click to fold; /mouse turns it off") if turned.mouse

  State.noted(turned, "mouse off: the terminal selects text; /mouse turns it on")
end

## The model with the mouse reporting set, the terminal told.
def turn_mouse(app: State.Model, on: Bool) -> State.Model
  app.write.call(Terminal.mouse(on))
  app.with(mouse: on, selection: none, pressed: none, click: none)
end

## Shift+Tab: the next profile, `build`, `plan`, then the others by name, and `build` again; it applies from the next
## turn, as `/profile NAME` does, and a turn that runs refuses it.
def next_profile(app: State.Model) -> State.Model
  return State.noted(app, "a turn is running: change the profile after it") if State.busy?(app)
  return app if app.id == "" or app.moving

  State.tried(app, cycled(app))
end

## The model with the keys that the config of the server asks for (its `keys` map as `settings`, checked), with the
## warnings about its entries in `keys.warnings`; the keys it has when the server says none (it did not answer).
def with_keys(app: State.Model, settings: Optional[List[Protocol.KeySetting]]) -> State.Model
  case settings
    some(listed) -> app.with(keys: Client.effective(listed))
    none -> app
  end
end

## The note of a reconnect, and the banner with the servers that are still failed.
def mcp_reconnected(app: State.Model, text: String, status: Optional[Protocol.McpStatus]) -> State.Model
  noted = State.noted(app, text)
  case status
    some(read) -> McpPanel.reconnected(noted.with(banner: Client.mcp_banner(noted.banner, read)), read)
    none -> noted
  end
end

private

# The profile after the session's in the order Shift+Tab goes through; the list of the server, without the ones that
# do not load.
def cycled(app: State.Model) -> Result[State.Model]
  listed = (try app.backend.list_profiles.call(app.id)).profiles.select { |p| p.source != "" }.map { |p| p.name }
  first = ["build", "plan"].select { |name| listed.include?(name) }
  names = first + listed.select { |name| not first.include?(name) }.sort
  return error("no profile to change to") if names.empty?

  at = names.index(State.profile_name(app)).map { |i| i + 1 }.unwrap_or(0)
  profile_command(app, some(names[at % names.size]))
end

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
  sessions = Client.resumable(try app.backend.list_sessions.call(), app.id)
  return ok(State.noted(app, "no sessions")) if sessions.empty?

  ok(app.with(picker: some(Picker.Picker(sessions: sessions))))
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
  Session.resume(Session.fresh(app), try Client.pick(try app.backend.list_sessions.call(), choice, app.id))
end

# `/profile` lists the profiles, `*` before the session's; `/profile NAME` changes it, with the model and thinking
# level it brings, and shows the server's warnings about it.
def profile_command(app: State.Model, name: Optional[String]) -> Result[State.Model]
  for wanted in State.option_list(name)
    try app.backend.update_session.call(app.id, Protocol.UpdateSession(profile: some(wanted)))
    session = try app.backend.session.call(app.id)
    shown = app.with(
      serving: State.serving_of(session),
      profile: Session.profile_name(session),
      effort: session.effort,
      confirmed: session.effort,
    )

    done = State.noted(shown, "profile #{Client.printable(wanted)} from the next turn")
    return ok(Session.profile_notices(done, session))
  end

  current = (try app.backend.session.call(app.id)).profile.map { |p| p.name }.unwrap_or("")
  lines = Client.profile_listing(try app.backend.list_profiles.call(app.id), current)
  ok(Sides.shown(app, Side.of("Profiles", lines)))
end

# `/mcp` lists the servers, `/mcp NAME` its tools, and `/mcp reconnect NAME` starts it again in a task (the
# answer waits
# for the server), with a note of how it went.
def mcp_command(app: State.Model, name: Optional[String], reconnecting: Bool) -> State.Model
  for wanted in State.option_list(name)
    return reconnect_mcp(app, wanted) if reconnecting

    return State.tried(app, shown_mcp(app, wanted))
  end

  State.tried(app, shown_mcp(app, ""))
end

def shown_mcp(app: State.Model, name: String) -> Result[State.Model]
  status = try app.backend.mcp.call(app.id)
  banner = Client.mcp_banner(app.banner, status)
  return ok(McpPanel.opened(app.with(banner: banner), status)) if name.empty?

  ok(Sides.shown(app.with(banner: banner), Side.of("MCP #{Client.printable(name)}", Client.mcp_tools(status, name))))
end

def status_after(read: Result[Protocol.McpStatus]) -> Optional[Protocol.McpStatus]
  return none if not read.ok?

  some(read.unwrap!)
end

def reconnect_mcp(app: State.Model, name: String) -> State.Model
  backend = app.backend
  id = app.id
  State.effect(
    State.noted(app, "mcp #{name}: starting again"),
    TUI.Cmd.Run(
      -> {
        case backend.mcp_reconnect.call(id, name)
          ok(server) ->
            State.Msg.Mcp(
              Client.mcp_listing(Protocol.McpStatus(servers: [server]))[0],
              status_after(backend.mcp.call(id)),
            )
          error(e) -> State.Msg.Note("error: mcp #{Client.printable(name)}: #{Client.printable(e.message)}")
        end
      },
    ),
  )
end

# `/help`, after the session's slash commands were read again.
def help_command(app: State.Model) -> State.Model = Sides.shown(app, Side.of("Help", aired(Client.help(app.custom))))

# `/shortcuts`: the keys in effect, as the footer names them.
def shortcuts_command(app: State.Model) -> State.Model
  Sides.shown(app, Side.of("Shortcuts", aired(Client.key_lines(app.keys))))
end

## The panel lines with air: a blank line starts every entry but the first. An entry is a non-indented line with its
## indented continuation lines, so commands keep their detail line and key rows stay grouped.
def aired(lines: List[String]) -> List[String]
  out: List[String] = []
  for line in lines
    if not out.empty? and not line.start_with?(" ") and out.last != ""
      out = out.push("")
    end

    out = out.push(line)
  end

  out
end

def thinking_command(app: State.Model, level: Optional[String]) -> State.Model
  case level
    some(text) ->
      State.tried(app, changed(app, Protocol.UpdateSession(effort: level), "thinking #{text} from the next turn"))
    none -> State.tried(app, shown_thinking(app))
  end
end

def confine_command(app: State.Model, on: Optional[Bool]) -> State.Model
  case on
    some(wanted) -> State.tried(app, changed(app, Protocol.UpdateSession(confine: on), confine_note(wanted)))
    none -> State.tried(app, shown_confine(app))
  end
end

def confine_note(on: Bool) -> String
  return "the file tools stay in the session folder from the next turn" if on

  "the file tools reach any path from the next turn"
end

def shown_confine(app: State.Model) -> Result[State.Model]
  ok(State.noted(app, Client.confined(try app.backend.session.call(app.id))))
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
  change = try Client.model_change(try app.backend.list_providers.call(), current, text)
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

## What the server read again, as notes: one line, then each warning.
def reload_command(app: State.Model) -> Result[State.Model]
  report = Client.reload_report(try app.backend.reload.call())
  wanted = app.backend.display.call()
  keyed = Status.tick(with_keys(app, wanted.keys).with(statusline: wanted.statusline, status_gone: false))
  ok(Sides.shown(keyed, Side.of("Reload", report + keyed.keys.warnings.map { |warning| "warning: #{warning}" })))
end

## The last lines of the server log in the side panel, which follows it.
def logs_command(app: State.Model, count: Int) -> State.Model = Sides.logs(app, count)

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
