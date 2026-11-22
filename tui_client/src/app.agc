## One session on the full screen, as an Elm program of agentica-tui: the `Model` holds the whole state, `update`
## takes the keys and the events of the server as messages and gives the next model with the work to start, and
## `view` draws a model. The event stream, the signals, the answers of approvals and the compactions run as commands,
## each giving one message, which `update` arms again; so do the sends, the stops, the level changes and the read of
## the files for `@`. The short calls to the server (session, list, update) run inside `update`, so the loop waits at
## most the client's call timeout (10 s) for each of them.
##
## This file only routes: the model and its messages are in `state`, and each part of `update` has its own file
## (`keys`, `turn`, `session`, `commands`, `logins`, `files`, `answering`, `level`), as `views` has the frame.

import Client from "pkg/client/client"
import TUI from "pkg/tui/tui"
import Approvals from "approvals"
import Args from "args"
import Clipboard from "clipboard"
import Screen from "screen"
import Selecting from "selecting"
import Terminal from "terminal"
import Theme from "theme"
import Transcript from "transcript"
import State from "state"
import Status from "status"
import Level from "level"
import Answering from "answering"
import Files from "files"
import HtmlTheme from "html_theme"
import Logins from "logins"
import McpPanel from "mcp_panel"
import Turn from "turn"
import Session from "session"
import Sides from "sides"
import Commands from "commands"
import Editor from "editor"
import Views from "views"
import Keys from "keys"

export State.Model
export State.Msg
export State.seed
export Logins.welcomed
export Session.read_feed

## How the app ended: its exit code, why it is not 0 (printed on stderr once the screen is closed: what the screen showed
## is wiped with it), and what to print once the screen is closed (how to come back to the session).
struct Ended
  code: Int
  hint: Optional[String] = none
  reason: Optional[String] = none
  ## Printed on stdout before the hint.
  line: Optional[String] = none
end

## Runs the session of `options` on `screen` until the user leaves or a signal ends it.
def run(screen: TUI.Raw.Screen, backend: Client.Backend, options: Args.Options) -> Result[Ended]
  started(screen, backend, options, &opened)
end

## `finn login` on `screen`: the login of the provider of `options` (the picker when none), then the end.
def login(screen: TUI.Raw.Screen, backend: Client.Backend, options: Args.Options) -> Result[Ended]
  started(screen, backend, options, ->(model: State.Model) { Logins.login_only(model, options.provider) })
end

def started(
  screen: TUI.Raw.Screen,
  backend: Client.Backend,
  options: Args.Options,
  first: Fn[State.Model, Result[State.Model]],
) -> Result[Ended]
  signals = try System.subscribe([System.Signal.Term, System.Signal.Hup, System.Signal.Int])
  palette = Theme.colors256?(System.env("TERM").unwrap_or(""), System.env("COLORTERM").unwrap_or(""))
  output = TUI.OutputMode.Colors256
  edits = case Client.state_dir(Args.launch(options))
    ok(dir) -> Editor.folder_of(dir, Time.now_ms / 1000)
    error(_) -> ""
  end

  seeded = State.seed(backend, options, signals, TUI.Raw.width(screen), TUI.Raw.height(screen)).with(
    edits: edits,
    host: Clipboard.detect(),
  )

  start = try first.call(seeded)
  if not palette
    output = TUI.OutputMode.Normal
    start = start.with(theme: Theme.basic())
  end

  start = themed(start)

  last = try driven(TUI.Raw.backend(screen), start, output)
  outcome = try outcome(last)
  hint = Client.resume_hint("finn", last.id, not Session.content?(last))
  ok(outcome.with(hint: joined(server_report(backend), hint)))
end

## `start` with the HTML theme applied: `theme.html` next to the user's config
## file, or `FINN_THEME` (see `HtmlTheme.theme_file`). A file that does not
## parse keeps the built-in theme with a note; a missing file changes nothing.
def themed(start: State.Model) -> State.Model
  loaded = HtmlTheme.load(start.theme, HtmlTheme.theme_file(->(name: String) { System.env(name) }), HtmlTheme.disk())
  noted = start.with(theme: loaded.theme)
  case loaded.warning
    some(text) -> State.noted(noted, text)
    none -> noted
  end
end

## Runs the app from the model `start` and its effects on `backend` until it ends: the exit code. The tests give it a
## fake terminal.
def drive(backend: TUI.Backend, start: State.Model, output: TUI.OutputMode = TUI.OutputMode.Colors256) -> Result[Int]
  ended(try driven(backend, start, output))
end

## The same, with the reason of a code that is not 0.
def drive_outcome(
  backend: TUI.Backend,
  start: State.Model,
  output: TUI.OutputMode = TUI.OutputMode.Colors256,
) -> Result[Ended]
  outcome(try driven(backend, start, output))
end

## The end of the app `last`: its code, and for a code that is not 0 the last note of the screen (the answer of a login
## that failed, say) or the signal that ended it: no end with an error is silent.
def outcome(last: State.Model) -> Result[Ended]
  code = try ended(last)
  return ok(Ended(code: code, line: last.line)) if code == 0

  ok(Ended(code: code, reason: some(why(last, code)), line: last.line))
end

# The model the app ends with.
def driven(backend: TUI.Backend, start: State.Model, output: TUI.OutputMode) -> Result[State.Model]
  app = TUI.App(
    model: start.with(effects: []),
    update: &update,
    view: &view,
    subscriptions: &subscriptions,
    cmds: start.effects,
    input: TUI.InputMode.Esc,
    mouse: true,
    output: output,
  )

  TUI.Raw.program(Terminal.guarded(backend), app)
end

def why(last: State.Model, code: Int) -> String
  return "stopped by a signal (#{code - 128})" if code > 128

  case State.last_notice(last)
    some(text) -> text
    none -> "ended with code #{code}"
  end
end

def ended(last: State.Model) -> Result[Int]
  case last.failure
    some(reason) -> error(reason, kind: "tui.session")
    none -> ok(last.exit.unwrap_or(0))
  end
end

# What the console gets after the screen closes about the warnings of the server, and then the hint to come back.
def joined(report: Optional[String], hint: Optional[String]) -> Optional[String]
  case report
    some(text) ->
      case hint
        some(more) -> some("#{text}\n#{more}")
        none -> some(text)
      end

    none -> hint
  end
end

def server_report(backend: Client.Backend) -> Optional[String]
  case backend.server_log.call(0)
    ok(log) -> Client.warning_report(log)
    error(_) -> none
  end
end

## The mouse off when the config of the server says so, and the clipboard it asks for.
def configured(app: State.Model) -> State.Model
  wanted = app.backend.display.call()
  set = Commands.with_keys(app, wanted.keys).with(clipboard: wanted.clipboard, statusline: wanted.statusline)
  set = Status.tick(set)
  for warning in set.keys.warnings
    set = State.noted(set, warning)
  end

  return set if wanted.mouse

  Commands.turn_mouse(set, false)
end

## The last warnings of the server as the banner at the top of the screen, with where the rest is.
def server_notes(app: State.Model) -> State.Model
  case app.backend.server_log.call(0)
    ok(log) -> mcp_notes(app.with(banner: Client.warning_banner(log, app.mouse)))
    error(_) -> mcp_notes(app)
  end
end

## The MCP servers that failed to start join the banner, with how to start each again.
def mcp_notes(app: State.Model) -> State.Model
  case app.backend.mcp.call(app.id)
    ok(status) -> app.with(banner: Client.mcp_banner(app.banner, status))
    error(_) -> app
  end
end

## The session of the options opened, with the signals listened to; at the first start, the login picker.
def opened(model: State.Model) -> Result[State.Model]
  app = try Session.open(model, model.options)
  if model.options.yolo
    app = State.noted(app, app.backend.yolo_warning.call())
  end

  for note in model.options.server_notes
    app = State.noted(app, note)
  end

  ok(State.effect(Logins.welcomed(server_notes(configured(app))), State.listen(app.signals)))
end

def update(model: State.Model, msg: State.Msg) -> TUI.Step[State.Model, State.Msg]
  app = Sides.fit(handled(model.with(now: Time.monotonic_ms, clock_s: Time.now_ms / 1000), msg))
  if app.serving != model.serving or app.opened != model.opened
    app = Status.tick(app.with(status_segments: [], reading_status: false, status_gone: false))
  end

  # The answer that streams changes on every delta: it is cut again when the stream rests.
  if not stream?(msg)
    app = app.with(entries: Transcript.wrapped(app.entries, app.width, State.folds(app)))
  end

  cmds = app.effects
  if app.exit.some? or app.failure.some?
    # The reader of the event stream and the command that waits on its channel end with the app.
    for task in State.option_list(app.stream)
      Task.cancel(task)
    end

    for feed in State.option_list(app.feed)
      feed.close
    end

    cmds = cmds.push(TUI.Cmd.Quit)
  end

  TUI.Step(model: app.with(effects: []), cmds: cmds)
end

def view(model: State.Model) -> TUI.Node
  left = Screen.view(Views.framed(model), model.theme)
  side = Views.beside(model)
  return left if side.empty?

  Screen.beside(left, side, model.theme)
end

def subscriptions(model: State.Model) -> List[TUI.Sub[State.Msg]]
  subs = [TUI.Sub.Events(->(event) { State.Msg.Key(event) })]
  if Status.polls?(model)
    subs = subs.push(TUI.Sub.Tick(Status.STATUS_MS, State.Msg.StatusTick))
  end

  if State.busy?(model)
    subs = subs.push(TUI.Sub.Tick(State.SPIN_MS, State.Msg.Spin))
  end

  if Sides.live?(model)
    subs = subs.push(TUI.Sub.Tick(Sides.LOG_MS, State.Msg.LogTick))
  end

  subs
end

private

def handled(app: State.Model, msg: State.Msg) -> State.Model
  case msg
    State.Msg.StatusTick -> Status.tick(app)
    State.Msg.StatusRead(opened, serving, generation, result) if opened == app.opened and serving == app.serving and generation == app.status_generation ->
      Status.read(app, result)

    State.Msg.StatusRead(_, _, _, _) -> app
    State.Msg.Key(TUI.Event.Resize(width, height)) -> Sides.resized(app, width, height)
    State.Msg.Key(event) -> Keys.on_key(app, event)
    State.Msg.Signal(signal) -> Session.signalled(app, signal)
    State.Msg.Edited(result) -> Editor.closed(app, result)
    State.Msg.Exported(result) -> Commands.exported(app, result)
    State.Msg.Note(text) -> State.noted(app, text)
    State.Msg.Mcp(text, status) -> Commands.mcp_reconnected(app, text, status)
    State.Msg.LogTick -> Sides.tick(app)
    State.Msg.LogRead(serial, result) -> Sides.read(app, serial, result)
    State.Msg.McpRead(serial, result) -> McpPanel.read(app, serial, result)
    State.Msg.McpLogRead(serial, name, result) -> McpPanel.log_read(app, serial, name, result)
    State.Msg.Copied(text, method, result, checked) -> Selecting.finished(app, text, method, result, checked)
    State.Msg.Answered(approval_id, result) ->
      outcome = Approvals.answered(app.approvals, approval_id, result, app.now)
      answered = Answering.unyolo(app.with(approvals: outcome.panel), approval_id, result)
      case outcome.note
        some(text) -> State.noted(answered, text)
        none -> answered
      end

    State.Msg.Stream(generation, items) if generation == app.generation and not app.outbox.empty? ->
      app.with(held: app.held + items)
    State.Msg.Stream(generation, items) if generation == app.generation -> Session.streamed(app, items)
    State.Msg.Stream(_, _) -> app
    State.Msg.Sent(opened, text, result) if opened == app.opened and not app.outbox.empty? ->
      Session.released(Turn.next_send(Turn.sent_reply(app.with(outbox: app.outbox.drop(1)), text, result)))
    State.Msg.Sent(_, _, _) -> app
    State.Msg.Stopped(what, result) -> Turn.stop_reply(app, what, result)
    State.Msg.Spin -> app.with(spin: (app.spin + 1) % State.SPINNER.size)
    State.Msg.Leveled(result) -> Level.level_reply(app, result)
    State.Msg.Moved(result) -> Commands.moved(app, result)
    State.Msg.LoggedIn(name, result) -> Logins.logged_in(app, name, result)
    State.Msg.DeviceStarted(name, serial, result) -> Logins.device_started(app, name, serial, result)
    State.Msg.DevicePolled(name, serial, result) -> Logins.device_polled(app, name, serial, result)
    State.Msg.Rechecked(generation, result) if generation == app.generation -> Session.rechecked(app, result)
    State.Msg.Rechecked(_, _) -> app
    State.Msg.Files(opened, result) if opened == app.opened -> Files.files_read(app.with(reading_files: false), result)
    State.Msg.Files(_, _) -> app
    State.Msg.Arguments(opened, command, result) if opened == app.opened ->
      Files.arguments_read(app.with(reading_arguments: false), command, result)
    State.Msg.Arguments(_, _, _) -> app
    State.Msg.ShellSent(command, result) -> Turn.shell_reply(app, command, result)
    State.Msg.Branch(opened, name) if opened == app.opened -> app.with(branch: name)
    State.Msg.Branch(_, _) -> app
  end
end

def stream?(msg: State.Msg) -> Bool
  case msg
    State.Msg.Stream(_, _) -> true
    _ -> false
  end
end
