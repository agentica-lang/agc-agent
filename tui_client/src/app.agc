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
import Screen from "screen"
import Theme from "theme"
import Transcript from "transcript"
import State from "state"
import Level from "level"
import Answering from "answering"
import Files from "files"
import Logins from "logins"
import Turn from "turn"
import Session from "session"
import Commands from "commands"
import Editor from "editor"
import Views from "views"
import Keys from "keys"

export State.Model
export State.Msg
export State.seed
export Logins.welcomed
export Session.read_feed

## Runs the session of `options` on `screen` until the user leaves or a signal ends it: the exit code.
def run(screen: TUI.Raw.Screen, backend: Client.Backend, options: Args.Options) -> Result[Int]
  started(screen, backend, options, &opened)
end

## `finn login` on `screen`: the login of the provider of `options` (the picker when none), then the end.
def login(screen: TUI.Raw.Screen, backend: Client.Backend, options: Args.Options) -> Result[Int]
  started(screen, backend, options, ->(model: State.Model) { Logins.login_only(model, options.provider) })
end

def started(
  screen: TUI.Raw.Screen,
  backend: Client.Backend,
  options: Args.Options,
  first: Fn[State.Model, Result[State.Model]],
) -> Result[Int]
  signals = try System.subscribe([System.Signal.Term, System.Signal.Hup, System.Signal.Int])
  palette = Theme.colors256?(System.env("TERM").unwrap_or(""), System.env("COLORTERM").unwrap_or(""))
  output = TUI.OutputMode.Colors256
  edits = case Client.state_dir(Args.launch(options))
    ok(dir) -> Editor.folder_of(dir, Time.now_ms / 1000)
    error(_) -> ""
  end

  seeded = State.seed(backend, options, signals, TUI.Raw.width(screen), TUI.Raw.height(screen)).with(edits: edits)
  start = try first.call(seeded)
  if not palette
    output = TUI.OutputMode.Normal
    start = start.with(theme: Theme.basic())
  end

  drive(TUI.Raw.backend(screen), start, output)
end

## Runs the app from the model `start` and its effects on `backend` until it ends: the exit code. The tests give it a
## fake terminal.
def drive(backend: TUI.Backend, start: State.Model, output: TUI.OutputMode = TUI.OutputMode.Colors256) -> Result[Int]
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

  last = try TUI.Raw.program(backend, app)
  case last.failure
    some(reason) -> error(reason, kind: "tui.session")
    none -> ok(last.exit.unwrap_or(0))
  end
end

## The session of the options opened, with the signals listened to; at the first start, the login picker.
def opened(model: State.Model) -> Result[State.Model]
  app = try Session.open(model, model.options)
  if model.options.yolo
    app = State.noted(app, app.backend.yolo_warning.call())
  end

  ok(State.effect(Logins.welcomed(app), State.listen(app.signals)))
end

def update(model: State.Model, msg: State.Msg) -> TUI.Step[State.Model, State.Msg]
  app = handled(model.with(now: Time.monotonic_ms, clock_s: Time.now_ms / 1000), msg)
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

def view(model: State.Model) -> TUI.Node = Screen.view(Views.framed(model), model.theme)

def subscriptions(model: State.Model) -> List[TUI.Sub[State.Msg]]
  keys = TUI.Sub.Events(->(event) { State.Msg.Key(event) })
  return [keys] if not State.busy?(model)

  [keys, TUI.Sub.Tick(State.SPIN_MS, State.Msg.Spin)]
end

private

def handled(app: State.Model, msg: State.Msg) -> State.Model
  case msg
    State.Msg.Key(TUI.Event.Resize(width, height)) -> app.with(width: width, height: height)
    State.Msg.Key(event) -> Keys.on_key(app, event)
    State.Msg.Signal(signal) -> Session.signalled(app, signal)
    State.Msg.Edited(result) -> Editor.closed(app, result)
    State.Msg.Note(text) -> State.noted(app, text)
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
