## One session on the full screen, as an Elm program of agentica-tui: the `Model` holds the whole state, `update`
## takes the keys and the events of the server as messages and gives the next model with the work to start, and
## `view` draws a model. The event stream, the signals, the answers of approvals and the compactions run as commands,
## each giving one message, which `update` arms again; so do the sends, the stops, the level changes and the read of
## the files for `@`. The short calls to the server (session, list, update) run inside `update`, so the loop waits at
## most the client's call timeout (10 s) for each of them.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import Approvals from "approvals"
import Calls from "calls"
import Args from "args"
import Input from "input"
import Picker from "picker"
import Layout from "panel"
import Prompt from "prompt"
import Screen from "screen"
import Theme from "theme"
import Transcript from "transcript"
import Width from "width"
import Yolo from "pkg/client/yolo"

FEED_CAPACITY = 1024
## The most stream items one message carries, so a long stream still lets the keys in between draws.
FEED_BATCH = 256
WAIT_MS = 3_600_000
SEND_MS = 30_000
RECONNECT_MS = 300
MAX_RECONNECTS = 3
MAX_RESYNCS = 2
SCROLL_STEP = 3
## The key hints of the status line, most needed first: those that do not fit are left out.
HINTS = [
  "Enter send",
  "Esc stop",
  "^C quit",
  "^J newline",
  "Alt+Enter follow-up",
  "⇧Tab thinking level",
  "^T show thinking",
  "^O show tool output",
  "@ files",
  "/ commands (Esc Enter: as typed)",
  "↑ history",
  "PgUp/PgDn",
]
SPINNER = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
SPIN_MS = 80
## The thinking levels Shift+Tab goes through, none for the model's default.
LEVELS: List[Optional[String]] = [none, some("low"), some("medium"), some("high")]

struct Model
  server: Client.Server
  id: String
  ## The folder of the session.
  cwd: String = ""
  ## What `/new` makes a session with.
  options: Args.Options
  signals: Channel[System.Signal]
  width: Int
  height: Int
  entries: List[Transcript.Entry] = []
  prompt: String = ""
  ## The cursor in the prompt, a character index (clamped to the text when used).
  cursor: Int = 0
  ## Rows above the bottom of the transcript, 0 to follow its end.
  scroll: Int = 0
  turn: Bool = false
  ## A `!` command of the session runs.
  shell: Bool = false
  stopping: Bool = false
  ## The reader of the event stream and the channel it fills.
  stream: Optional[Task[Void]] = none
  feed: Optional[Channel[Client.Item]] = none
  generation: Int = 0
  last_event_id: Int = 0
  ## The highest event id already drawn, so a replay draws nothing twice.
  shown_id: Int = 0
  reconnects: Int = 0
  ## `resync` events in a row, with no other event between.
  resyncs: Int = 0
  ## The messages to send, in order, one at a time: the first is on its way. The stream waits in `held` until every
  ## reply came, so its events meet the state the replies give (the turn this client started, the message it queued).
  outbox: List[String] = []
  held: List[Client.Item] = []
  ## Messages for after the turn (Alt+Enter), sent together when it ends.
  follow_ups: List[String] = []
  ## The prompts sent, oldest first, and the one Up shows (none: the prompt being typed).
  history: List[String] = []
  recall: Optional[Int] = none
  ## The large pastes behind the tokens of the prompt, until it is sent.
  pastes: List[String] = []
  ## The files of the session's folder once read, the selected one of the `@` or `/` list, the first one it shows, and
  ## the word that Esc closed.
  files: Optional[List[String]] = none
  reading_files: Bool = false
  mention_selected: Int = 0
  mention_top: Int = 0
  mention_closed: Optional[Int] = none
  ## Esc came before the turn of a message sent started: the turn stops once the reply says it did.
  stop_wanted: Bool = false
  ## How many times a session was opened, so the reply to a send made before is dropped.
  opened: Int = 0
  ## The picker of `/resume`, `/tree` or `/fork`, open over the prompt.
  picker: Optional[Picker.Picker] = none
  ## The provider and model of the session, as `provider/model`, for the status line and the `/model` picker.
  serving: String = ""
  ## The tree the picker of `/tree` or `/fork` showed last, whose numbers `/tree N` and `/fork N` name.
  listed: Optional[Protocol.SessionTree] = none
  ## A branch, a fork or a copy is on its way: nothing is sent until its reply.
  moving: Bool = false
  ## The prompt holds the message a move went back before, selected: typing replaces it.
  prefilled: Bool = false
  ## The provider whose key the prompt asks for, and the key typed so far: drawn as dots, kept nowhere else, and
  ## cleared once it is sent or the ask is closed.
  key_for: Optional[String] = none
  secret: String = ""
  ## A login offered at the first start: closing it stores an empty key file, so it is offered once. With
  ## `login_only` (`finn login`), the app ends after the login.
  first_login: Bool = false
  login_only: Bool = false
  ## The model `/model` set, until the turn after it ends: a failed call there gets a warning.
  new_model: Optional[String] = none
  yolo: Yolo.Yolo
  ## The thinking of the model is drawn.
  thinking: Bool = false
  ## The output of the tool calls is shown whole.
  tools: Bool = false
  ## The thinking level the rules show, none for the model's default; the server's own is `confirmed`.
  effort: Optional[String] = none
  confirmed: Optional[String] = none
  ## The level whose change is on its way: one at a time, and the reply sends the latest one wanted.
  level_sending: Optional[String] = none
  ## The frame of the spinner while a turn runs.
  spin: Int = 0
  approvals: Approvals.Panel
  ## The colors of the screen.
  theme: Theme.Theme
  ## The monotonic ms and the wall clock s of the message being handled.
  now: Int = 0
  clock_s: Int = 0
  ## The commands the message being handled starts.
  effects: List[TUI.Cmd[Msg]] = []
  exit: Optional[Int] = none
  ## Why the client ends with an error.
  failure: Optional[String] = none
end

enum Msg
  Key(TUI.Event)
  ## A signal, none when the wait ended without one.
  Signal(Optional[System.Signal])
  ## The items of the stream of a generation, so the messages of an old stream are dropped.
  Stream(Int, List[Client.Item])
  ## The reply of the server to the answer of an approval.
  Answered(String, Result[Void])
  ## A note for the transcript (a compaction's end).
  Note(String)
  ## The server was checked again before the stream of a generation is read again.
  Rechecked(Int, Result[Void])
  ## The reply to a message sent: the `opened` count when it was sent, and the text.
  Sent(Int, String, Result[Protocol.MessageAccepted])
  ## The reply to a stop.
  Stopped(Result[Void])
  ## The spinner moves on.
  Spin
  ## The reply to a change of the thinking level.
  Leveled(Result[Void])
  ## The reply to a branch, a fork or a copy: the session to go on in.
  Moved(Result[Protocol.Branched])
  ## The reply to a login, with no key in it.
  LoggedIn(String, Result[Protocol.LoginStatus])
  ## The files of the session's folder, for the `opened` count when they were asked.
  Files(Int, Result[List[String]])
  ## The reply to a `!` command: the command, and whether it runs.
  ShellSent(String, Result[Protocol.ShellAccepted])
end

## Runs the session of `options` on `screen` until the user leaves or a signal ends it: the exit code.
def run(screen: TUI.Raw.Screen, server: Client.Server, options: Args.Options) -> Result[Int]
  started(screen, server, options, &opened)
end

## `finn login` on `screen`: the login of the provider of `options` (the picker when none), then the end.
def login(screen: TUI.Raw.Screen, server: Client.Server, options: Args.Options) -> Result[Int]
  started(screen, server, options, ->(model: Model) { login_only(model, options.provider) })
end

def started(
  screen: TUI.Raw.Screen,
  server: Client.Server,
  options: Args.Options,
  first: Fn[Model, Result[Model]],
) -> Result[Int]
  signals = try System.subscribe([System.Signal.Term, System.Signal.Hup, System.Signal.Int])
  palette = Theme.colors256?(System.env("TERM").unwrap_or(""), System.env("COLORTERM").unwrap_or(""))
  output = TUI.OutputMode.Colors256
  start = try first.call(seed(server, options, signals, TUI.Raw.width(screen), TUI.Raw.height(screen)))
  if not palette
    output = TUI.OutputMode.Normal
    start = start.with(theme: Theme.basic())
  end

  drive(TUI.Raw.backend(screen), start, output)
end

## Runs the app from the model `start` and its effects on `backend` until it ends: the exit code. The tests give it a
## fake terminal.
def drive(backend: TUI.Backend, start: Model, output: TUI.OutputMode = TUI.OutputMode.Colors256) -> Result[Int]
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

## The command that reads the next items of the stream `feed` of `generation`.
def read_feed(generation: Int, feed: Channel[Client.Item]) -> TUI.Cmd[Msg]
  TUI.Cmd.Run(-> { Msg.Stream(generation, drained(feed)) })
end

## The model before the session is opened.
def seed(
  server: Client.Server,
  options: Args.Options,
  signals: Channel[System.Signal],
  width: Int,
  height: Int,
) -> Model
  Model(
    server: server,
    id: "",
    options: options,
    signals: signals,
    width: width,
    height: height,
    thinking: options.thinking,
    approvals: Approvals.Panel(),
    yolo: Yolo.Yolo(on: options.yolo),
    theme: Theme.default(),
    now: Time.monotonic_ms,
    clock_s: Time.now_ms / 1000,
  )
end

## The session of the options opened, with the signals listened to; at the first start, the login picker.
def opened(model: Model) -> Result[Model]
  app = try open(model, model.options)
  if model.options.yolo
    app = noted(app, Client.yolo_warning(app.server))
  end

  ok(effect(welcomed(app), listen(app.signals)))
end

## `finn login`: the login picker on its own, until a login ends or it is closed.
def login_only(model: Model, provider: Optional[String]) -> Result[Model]
  app = effect(model.with(login_only: true), listen(model.signals))
  list = try Client.list_logins(app.server)
  for name in option_list(provider)
    return ok(named_login(app, list.providers, name))
  end

  ok(app.with(picker: some(Picker.logins(list))))
end

## The first start offers a login when the server has no key file and no key in the environment.
def welcomed(app: Model) -> Model
  case Client.list_logins(app.server)
    ok(list) if list.first ->
      shown = noted(app, "no provider is set up: pick one to give its key, or Esc to go on with the local server")
      shown.with(picker: some(Picker.logins(list)), first_login: true)
    _ -> app
  end
end

def update(model: Model, msg: Msg) -> TUI.Step[Model, Msg]
  app = handled(model.with(now: Time.monotonic_ms, clock_s: Time.now_ms / 1000), msg)
  # The answer that streams changes on every delta: it is cut again when the stream rests.
  if not stream?(msg)
    app = app.with(entries: Transcript.wrapped(app.entries, app.width, folds(app)))
  end

  cmds = app.effects
  if app.exit.some? or app.failure.some?
    # The reader of the event stream and the command that waits on its channel end with the app.
    for task in option_list(app.stream)
      Task.cancel(task)
    end

    for feed in option_list(app.feed)
      feed.close
    end

    cmds = cmds.push(TUI.Cmd.Quit)
  end

  TUI.Step(model: app.with(effects: []), cmds: cmds)
end

def view(model: Model) -> TUI.Node = Screen.view(framed(model), model.theme)

def subscriptions(model: Model) -> List[TUI.Sub[Msg]]
  keys = TUI.Sub.Events(->(event) { Msg.Key(event) })
  return [keys] if not busy?(model)

  [keys, TUI.Sub.Tick(SPIN_MS, Msg.Spin)]
end

private

def handled(app: Model, msg: Msg) -> Model
  case msg
    Msg.Key(TUI.Event.Resize(width, height)) -> app.with(width: width, height: height)
    Msg.Key(event) -> on_key(app, event)
    Msg.Signal(signal) -> signalled(app, signal)
    Msg.Note(text) -> noted(app, text)
    Msg.Answered(approval_id, result) ->
      outcome = Approvals.answered(app.approvals, approval_id, result, app.now)
      answered = unyolo(app.with(approvals: outcome.panel), approval_id, result)
      case outcome.note
        some(text) -> noted(answered, text)
        none -> answered
      end

    Msg.Stream(generation, items) if generation == app.generation and not app.outbox.empty? ->
      app.with(held: app.held + items)
    Msg.Stream(generation, items) if generation == app.generation -> streamed(app, items)
    Msg.Stream(_, _) -> app
    Msg.Sent(opened, text, result) if opened == app.opened and not app.outbox.empty? ->
      released(next_send(sent_reply(app.with(outbox: app.outbox.drop(1)), text, result)))
    Msg.Sent(_, _, _) -> app
    Msg.Stopped(result) -> stop_reply(app, result)
    Msg.Spin -> app.with(spin: (app.spin + 1) % SPINNER.size)
    Msg.Leveled(result) -> level_reply(app, result)
    Msg.Moved(result) -> moved(app, result)
    Msg.LoggedIn(name, result) -> logged_in(app, name, result)
    Msg.Rechecked(generation, result) if generation == app.generation -> rechecked(app, result)
    Msg.Rechecked(_, _) -> app
    Msg.Files(opened, result) if opened == app.opened -> files_read(app.with(reading_files: false), result)
    Msg.Files(_, _) -> app
    Msg.ShellSent(command, result) -> shell_reply(app, command, result)
  end
end

# A signal ends the client; a wait that ended without one waits again.
def signalled(app: Model, signal: Optional[System.Signal]) -> Model
  case signal
    some(got) -> app.with(exit: some(128 + System.signal_number(got)))
    none if app.signals.closed? -> app
    none -> effect(app, listen(app.signals))
  end
end

def rechecked(app: Model, result: Result[Void]) -> Model
  case result
    ok(_) -> subscribe(app, app.last_event_id)
    error(e) -> app.with(failure: some(e.message))
  end
end

def stream?(msg: Msg) -> Bool
  case msg
    Msg.Stream(_, _) -> true
    _ -> false
  end
end

def effect(app: Model, cmd: TUI.Cmd[Msg]) -> Model = app.with(effects: app.effects.push(cmd))

def listen(signals: Channel[System.Signal]) -> TUI.Cmd[Msg]
  TUI.Cmd.Run(
    -> {
      case signals.recv(WAIT_MS)
        ok(signal) -> Msg.Signal(some(signal))
        error(_) -> Msg.Signal(none)
      end
    },
  )
end

def drained(feed: Channel[Client.Item]) -> List[Client.Item]
  items: List[Client.Item] = []
  got = feed.recv(WAIT_MS)
  while got.ok? and items.size < FEED_BATCH
    items = items.push(got.unwrap!)
    got = feed.recv(0)
  end

  items
end

# The items of the current stream, then the next read of it while it goes on.
def streamed(app: Model, items: List[Client.Item]) -> Model
  generation = app.generation
  done = app
  for item in items
    done = on_stream(done, item)
    break if done.failure.some? or done.generation != generation
  end

  ended = items.any? { |item| ended?(item) }
  return done if ended or done.failure.some? or done.generation != generation or done.feed.none?

  effect(done, read_feed(generation, done.feed.unwrap!))
end

def ended?(item: Client.Item) -> Bool
  case item
    Client.Item.Ended(_) -> true
    _ -> false
  end
end

def open(app: Model, options: Args.Options) -> Result[Model]
  case options.session
    some(id) -> resume(app, id)
    none -> create(app)
  end
end

def create(app: Model) -> Result[Model]
  options = app.options
  cwd = case options.cwd
    some(dir) -> dir
    none -> try Path.cwd()
  end

  request = Protocol.NewSession(cwd: cwd, model: options.model, api: options.api, provider: options.provider)
  id = try Client.create_session(app.server, request)
  serving = serving_of(try Client.session(app.server, id))
  ok(subscribe(noted(app.with(id: id, cwd: cwd, opened: app.opened + 1, serving: serving), "session #{id}"), 0))
end

def resume(app: Model, id: String) -> Result[Model]
  ok(noted(attach(app.with(id: id), try Client.session(app.server, id), false), "session #{id}"))
end

# Draws the history of the session and reads the events after it; while a turn runs, from the start of the turn, unless
# `skip_replay` (a server that no longer has that start).
def attach(app: Model, session: Protocol.Session, skip_replay: Bool) -> Model
  from = session.last_event_id
  if not skip_replay
    from = session.turn_from_event_id.unwrap_or(session.last_event_id)
  end

  entries = Transcript.from_history(session.history)
  fresh = app.with(
    serving: serving_of(session),
    opened: app.opened + 1,
    cwd: session.cwd,
    entries: entries,
    history: entries.select { |entry| entry.kind == Transcript.Kind.User }.map { |entry| entry.text },
    files: none,
    reading_files: false,
    turn: session.turn_id.some?,
    shell: session.shell_id.some?,
    effort: wanted_level(app, session.effort),
    confirmed: session.effort,
    stopping: false,
    shown_id: from,
    approvals: Approvals.replaced(app.approvals, session.pending_approvals, app.now),
    yolo: Yolo.attached(app.yolo, session.turn_id, not skip_replay),
  )

  subscribed = subscribe(fresh, from)
  return subscribed if session.turn_id.some?

  # The end of the turn they waited for was not seen.
  after_turn(subscribed, Protocol.StopReason.EndTurn)
end

# A new reader of the stream from `from`; the old one stops, and its channel is closed so its last read ends.
def subscribe(app: Model, from: Int) -> Model
  for task in option_list(app.stream)
    Task.cancel(task)
  end

  for old in option_list(app.feed)
    old.close
  end

  generation = app.generation + 1
  feed: Channel[Client.Item] = Channel.new(FEED_CAPACITY)
  reader = Client.Feed(
    server: app.server,
    session_id: app.id,
    last_event_id: from,
    tell: ->(item) { feed.send(item, SEND_MS) },
  )

  started = app.with(
    stream: some(Client.start(reader)),
    feed: some(feed),
    generation: generation,
    last_event_id: from,
    held: [],
  )

  effect(started, read_feed(generation, feed))
end

def on_key(app: Model, event: TUI.Event) -> Model
  for name in option_list(app.key_for)
    return on_secret_key(app, name, event) if not ctrl_c?(event)
  end

  for picker in option_list(app.picker)
    return on_picker_key(app, picker, event) if not ctrl_c?(event)
  end

  case Approvals.decision(app.approvals, event, app.now, not panel(app).empty?)
    some(decision) -> return answer(app, decision)
    none -> nil
  end

  return app if Approvals.captures?(app.approvals, event)

  for found in option_list(mention_list(app))
    return on_mention_key(app, found, event) if mention_key?(app, found, event)
  end

  on_prompt_key(unselected(app, event), event)
end

# A typed character, a paste or Backspace replaces a selected prompt; any other key keeps it as text.
def unselected(app: Model, event: TUI.Event) -> Model
  return app if not app.prefilled

  case event
    TUI.Event.Char(_, _), TUI.Event.Paste(_), TUI.Event.Key(TUI.Key.Backspace, _) ->
      app.with(prompt: "", cursor: 0, prefilled: false)
    _ -> app.with(prefilled: false)
  end
end

def on_prompt_key(app: Model, event: TUI.Event) -> Model
  case event
    TUI.Event.Key(TUI.Key.Ctrl("c"), _) -> app.with(exit: some(0))
    TUI.Event.Key(TUI.Key.Enter, mods) if mods.alt -> follow_up(app)
    TUI.Event.Key(TUI.Key.Enter, _) -> send(app)
    TUI.Event.Key(TUI.Key.Up, _) if app.prompt == "" or app.recall.some? -> recalled(app, -1)
    TUI.Event.Key(TUI.Key.Down, _) if app.recall.some? -> recalled(app, 1)
    TUI.Event.Key(TUI.Key.Ctrl("t"), _) ->
      shown = app.with(thinking: not app.thinking, entries: Transcript.unfold_thinking(app.entries))
      noted(shown, "thinking blocks: #{shown_name(shown.thinking)}")
    TUI.Event.Key(TUI.Key.Ctrl("o"), _) ->
      shown = app.with(tools: not app.tools, entries: Transcript.unfold_tools(app.entries))
      noted(shown, "tool output: #{shown_name(shown.tools)}")
    TUI.Event.Key(TUI.Key.Ctrl("j"), _) -> typed(app, "\n")
    TUI.Event.Key(TUI.Key.Backspace, _) ->
      at = cursor(app)
      app.with(prompt: Prompt.backspace(app.prompt, at), cursor: [at - 1, 0].max.unwrap!, recall: none)
    TUI.Event.Key(TUI.Key.Left, _) -> app.with(cursor: [cursor(app) - 1, 0].max.unwrap!)
    TUI.Event.Key(TUI.Key.Right, _) -> app.with(cursor: Prompt.clamp(app.prompt, cursor(app) + 1))
    TUI.Event.Key(TUI.Key.Home, _) -> app.with(cursor: 0)
    TUI.Event.Key(TUI.Key.End, _) -> app.with(cursor: app.prompt.length)
    TUI.Event.Mouse(TUI.Mouse.Left, x, y, mods) if not mods.motion -> clicked(app, x, y)
    TUI.Event.Key(TUI.Key.Tab, _) -> app.with(approvals: Approvals.toggled(app.approvals, app.now))
    TUI.Event.Key(TUI.Key.BackTab, _) -> leveled(app)
    TUI.Event.Key(TUI.Key.Escape, _) if app.approvals.focused ->
      app.with(approvals: Approvals.toggled(app.approvals, app.now))
    TUI.Event.Key(TUI.Key.Escape, _) if not app.follow_ups.empty? -> stop(put_back(app))
    TUI.Event.Key(TUI.Key.Escape, _) -> stop(app)
    TUI.Event.Key(TUI.Key.PageUp, _) -> scrolled(app, page(app))
    TUI.Event.Key(TUI.Key.PageDown, _) -> scrolled(app, -page(app))
    TUI.Event.Mouse(TUI.Mouse.WheelUp, _, _, _) -> scrolled(app, SCROLL_STEP)
    TUI.Event.Mouse(TUI.Mouse.WheelDown, _, _, _) -> scrolled(app, -SCROLL_STEP)
    TUI.Event.Char(char, _) -> typed(app, char)
    TUI.Event.Paste(text) -> pasted(app, Prompt.pasted(text))
    _ -> app
  end
end

def cursor(app: Model) -> Int = Prompt.clamp(app.prompt, app.cursor)

def typed(app: Model, piece: String) -> Model
  at = cursor(app)
  edited = app.with(prompt: Prompt.insert(app.prompt, at, piece), cursor: at + piece.length, recall: none)
  # A list Esc closed opens again for a new prompt.
  if app.prompt == ""
    edited = edited.with(mention_closed: none, mention_selected: 0, mention_top: 0)
  end

  return edited if piece != "@" or edited.reading_files or app.id == ""

  read_files(edited)
end

# A large paste goes in as a token, which the send puts back.
def pasted(app: Model, text: String) -> Model
  return typed(app, text) if not Input.large?(text)

  pastes = app.pastes.push(text)
  typed(app.with(pastes: pastes), Input.token(pastes.size, text))
end

# Up shows the prompt sent before the one shown, Down the one after; past the newest the prompt is empty again.
def recalled(app: Model, step: Int) -> Model
  return app if app.history.empty?

  at = app.recall.unwrap_or(app.history.size) + step
  return app if at < 0

  return app.with(prompt: "", cursor: 0, recall: none) if at >= app.history.size

  text = app.history[at]
  app.with(prompt: text, cursor: text.length, recall: some(at))
end

# Alt+Enter: while a turn runs (or a message that starts one is on its way), the text waits for the turn's end.
def follow_up(app: Model) -> Model
  text = app.prompt.strip
  # A command runs now, as with Enter: it is no message for the model.
  return send(app) if text == "" or (not app.turn and app.outbox.empty?) or Client.parse_command(text).some?
  return noted(app, "a ! command runs between turns: send it once the turn ends") if Client.parse_shell(text).some?

  whole = expanded(app, text)
  waiting = app.with(prompt: "", cursor: 0, recall: none, follow_ups: app.follow_ups.push(whole), pastes: [])
  waiting.with(history: remembered(waiting.history, whole))
end

# Esc puts the follow-ups back in the prompt, before what it holds.
def put_back(app: Model) -> Model
  text = (app.follow_ups + [app.prompt].select { |t| t.strip != "" }).join("\n")
  noted(app.with(prompt: text, cursor: text.length, follow_ups: []), "follow-ups back in the prompt")
end

# The follow-ups go as one message once the turn ended by itself; a stopped turn puts them back in the prompt.
def after_turn(app: Model, reason: Protocol.StopReason) -> Model
  return app if app.follow_ups.empty?
  return put_back(app) if reason == Protocol.StopReason.Cancelled

  text = app.follow_ups.join("\n\n")
  queued = app.with(follow_ups: [], outbox: app.outbox.push(text))
  return queued if not app.outbox.empty?

  sending(queued, text)
end

def expanded(app: Model, text: String) -> String = Input.expanded(text, app.pastes)

def remembered(history: List[String], text: String) -> List[String]
  return history if not history.empty? and history.last == text

  history.push(text)
end

# The files of the session's folder come from the server each time an `@` is typed; the list shows the ones read last.
def read_files(app: Model) -> Model
  server = app.server
  id = app.id
  opened = app.opened
  effect(app.with(reading_files: true), TUI.Cmd.Run(-> { Msg.Files(opened, Client.files(server, id)) }))
end

def files_read(app: Model, result: Result[List[String]]) -> Model
  case result
    ok(files) -> app.with(files: some(files))
    error(e) -> noted(app, "error: the files were not listed: #{e.message}")
  end
end

# The list under the editor: the commands while the prompt is `/` and part of a name that some command starts with,
# else the files while the cursor ends an `@` word and the files are read; none once Esc closed it.
def mention_list(app: Model) -> Optional[Input.Mention]
  # A prompt Up recalled shows none: Up and Down go on through the history. Nor does a list without room, or under an
  # approval, which takes the panel.
  return none if app.picker.some? or app.recall.some? or not app.approvals.pending.empty? or list_room(app) <= 0

  found = Input.command_word(app.prompt, cursor(app))
  if found.none? or mention_choices(app, found.unwrap!).empty?
    found = none
    if app.files.some?
      found = Input.mention(app.prompt, cursor(app))
    end
  end

  return none if found.none? or app.mention_closed == some(found.unwrap!.start)

  found
end

def mention_key?(app: Model, found: Input.Mention, event: TUI.Event) -> Bool
  case event
    TUI.Event.Key(TUI.Key.Tab, _) -> true
    TUI.Event.Key(TUI.Key.Up, _) -> true
    TUI.Event.Key(TUI.Key.Down, _) -> true
    TUI.Event.Key(TUI.Key.Escape, _) -> true
    TUI.Event.Key(TUI.Key.Enter, mods) -> not mods.alt and completes?(app, found)
    _ -> false
  end
end

# Enter on part of a command's name completes it as Tab does; on a whole name it runs the command, and after `/` alone
# or under the file list it sends the prompt.
def completes?(app: Model, found: Input.Mention) -> Bool
  return false if found.source != Input.Source.Commands or found.query == ""

  word = "/#{found.query}"
  not mention_choices(app, found).any? { |choice| choice.value.strip == word }
end

# The rows under the editor that the list may take.
def list_room(app: Model) -> Int
  Screen.panel_room(app.height, Prompt.view(app.prompt, cursor(app), app.width, app.height).rows.size)
end

def mention_choices(app: Model, found: Input.Mention) -> List[Input.Choice]
  case found.source
    Input.Source.Commands -> Input.commands(Client.listed(), found.query)
    Input.Source.Files ->
      Input.matches(app.files.unwrap_or([]), found.query).map { |p| Input.Choice(value: p, label: p) }
  end
end

# Tab, or Enter on part of a command name, puts the selected choice in place of the word; Up and Down move, Esc closes
# the list.
def on_mention_key(app: Model, found: Input.Mention, event: TUI.Event) -> Model
  choices = mention_choices(app, found)
  selected = [[app.mention_selected, choices.size - 1].min.unwrap!, 0].max.unwrap!
  case event
    TUI.Event.Key(TUI.Key.Up, _) -> selected_choice(app, [selected - 1, 0].max.unwrap!, choices.size)
    TUI.Event.Key(TUI.Key.Down, _) -> selected_choice(app, [selected + 1, choices.size - 1].min.unwrap!, choices.size)
    TUI.Event.Key(TUI.Key.Escape, _) -> app.with(mention_closed: some(found.start))
    _ if choices.empty? -> app
    _ ->
      at = cursor(app)
      text = Input.completed(app.prompt, at, found, choices[selected].value)
      app.with(prompt: text, cursor: at + text.length - app.prompt.length, mention_selected: 0, mention_top: 0)
  end
end

def selected_choice(app: Model, selected: Int, size: Int) -> Model
  top = Input.window(app.mention_top, selected, list_room(app), size)
  app.with(mention_selected: selected, mention_top: top)
end

# A click on the transcript opens or closes a thinking block or a tool call; on a key of the approval panel it is
# that key (with the same rules); in the prompt it moves the cursor. The click is matched against the regions of the
# model as drawn.
def clicked(app: Model, x: Int, y: Int) -> Model = clicked_on(app, framed(app), x, y)

def clicked_on(app: Model, frame: Screen.Frame, x: Int, y: Int) -> Model
  case Screen.hit(frame, x, y)
    Screen.Hit.Entry(index) -> app.with(entries: Transcript.toggle(app.entries, index, folds(app)))
    Screen.Hit.Key(event) -> on_key(app, event)
    Screen.Hit.Prompt(column, row) ->
      app.with(cursor: Prompt.index_at(app.prompt, cursor(app), frame.width, frame.height, column, row))
    Screen.Hit.Nothing -> app
  end
end

def ctrl_c?(event: TUI.Event) -> Bool
  case event
    TUI.Event.Key(TUI.Key.Ctrl("c"), _) -> true
    _ -> false
  end
end

def on_picker_key(app: Model, picker: Picker.Picker, event: TUI.Event) -> Model
  case Picker.key(picker, event)
    Picker.Step.Stay(next_picker) -> app.with(picker: some(next_picker))
    Picker.Step.Close if picker.kind == Picker.Kind.Logins -> login_closed(app.with(picker: none))
    Picker.Step.Close -> app.with(picker: none)
    Picker.Step.Pick(key) if picker.kind == Picker.Kind.Logins -> login_picked(app.with(picker: none), picker, key)
    Picker.Step.Pick(key) -> picked(app.with(picker: none), picker.kind, key)
  end
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end

def page(app: Model) -> Int = [app.height / 2, 1].max.unwrap!

def scrolled(app: Model, rows: Int) -> Model = app.with(scroll: [app.scroll + rows, 0].max.unwrap!)

def send(app: Model) -> Model
  typed_text = app.prompt.strip
  return app if typed_text == ""

  text = expanded(app, typed_text)
  base = app.with(history: remembered(app.history, text), recall: none, cursor: 0, mention_closed: none)
  secret_line = ["/login", "/logout"].any? { |name| typed_text.start_with?(name) }
  if secret_line
    # A key typed on a `/login` or `/logout` line by mistake is not kept: not remembered, its pastes dropped.
    base = base.with(history: app.history, pastes: [])
  end

  case Client.parse_command(typed_text)
    some(ok(command)) if not app.moving or local?(command) ->
      return on_command(base.with(prompt: "", scroll: 0), command)
    some(error(e)) if secret_line -> return noted(base.with(prompt: ""), e.message)
    some(error(e)) -> return noted(app, e.message)
    _ -> nil
  end

  return noted(app, "the session is moving: wait for it") if app.moving

  for request in option_list(Client.parse_shell(text))
    return shell_send(base.with(prompt: "", scroll: 0, pastes: []), request)
  end

  queued = base.with(prompt: "", scroll: 0, outbox: app.outbox.push(text), pastes: [])
  return queued if not app.outbox.empty?

  sending(queued, text)
end

def shell_send(app: Model, request: Protocol.RunShell) -> Model
  server = app.server
  id = app.id
  effect(app, TUI.Cmd.Run(-> { Msg.ShellSent(request.command, Client.shell(server, id, request)) }))
end

# Its `shell_started` and `shell_finished` draw the command; a refusal goes back to an empty prompt, and one that may
# have run (a timeout) stays only in the note, so it does not run twice.
def shell_reply(app: Model, command: String, result: Result[Protocol.ShellAccepted]) -> Model
  case result
    ok(_) -> app
    error(e) if e.kind == Client.KIND_TIMEOUT ->
      noted(app, "the command may have run (#{e.message}): #{Client.printable(command)}")
    error(e) ->
      failed = noted(app, "the command did not run: #{e.message}: #{Client.printable(command)}")
      return failed if app.prompt != ""

      text = "!#{command}"
      failed.with(prompt: text, cursor: text.length)
  end
end

# A command that does not touch the session, which goes on while it moves.
def local?(command: Client.Command) -> Bool
  case command
    Client.Command.Quit, Client.Command.Help, Client.Command.Cost -> true
    Client.Command.Login(_), Client.Command.Logout(_) -> true
    _ -> false
  end
end

def sending(app: Model, text: String) -> Model
  server = app.server
  id = app.id
  opened = app.opened
  effect(app, TUI.Cmd.Run(-> { Msg.Sent(opened, text, Client.send_message(server, id, text)) }))
end

# The next message of the outbox goes once the reply to the one before came, so the server gets them in order.
def next_send(app: Model) -> Model
  return app.with(stop_wanted: false) if app.outbox.empty?

  sending(app, app.outbox[0])
end

# A message sent while a turn runs is queued; its `message_queued` event shows it. A message that was not sent goes
# back to an empty prompt; one that may have been sent (a timeout) stays only in the note, so it is not sent twice.
def sent_reply(app: Model, text: String, result: Result[Protocol.MessageAccepted]) -> Model
  case result
    ok(accepted) if accepted.message_id.some? ->
      queued = app.with(yolo: Yolo.accepted(app.yolo, accepted))
      return queued if not app.stop_wanted

      # The message went into a turn that runs (another client's): that is the turn Esc asked to stop.
      stop(queued.with(turn: true, stop_wanted: false), some(accepted.turn_id))
    ok(accepted) ->
      entries = Transcript.add(app.entries, Transcript.Kind.User, text)
      started = app.with(entries: entries, turn: true, stopping: false, yolo: Yolo.accepted(app.yolo, accepted))
      return started if not app.stop_wanted

      stop(started.with(stop_wanted: false), some(accepted.turn_id))
    # The text stays in the note: put back in the prompt, it would take the keys typed after it.
    error(e) if e.kind == Client.KIND_TIMEOUT ->
      noted(app, "error: the message may not have been sent (#{e.message}): #{Client.printable(text)}")
    error(e) ->
      failed = noted(app, "error: the message was not sent: #{e.message}: #{Client.printable(text)}")
      return failed if app.prompt != ""

      failed.with(prompt: text, cursor: text.length)
  end
end

def stop_reply(app: Model, result: Result[Void]) -> Model
  case result
    ok(_) -> app
    error(e) -> noted(app.with(stopping: false), "error: the stop was not sent: #{e.message}")
  end
end

# The stream held while messages were sent goes on once every reply came.
def released(app: Model) -> Model
  return app if not app.outbox.empty? or app.held.empty?

  streamed(app.with(held: []), app.held)
end

def on_command(app: Model, command: Client.Command) -> Model
  case command
    Client.Command.Quit -> app.with(exit: some(0))
    Client.Command.Stop -> stop_command(app)
    Client.Command.Help -> app.with(entries: app.entries + Client.help().map { |line| note_entry(line) })
    Client.Command.Cost -> noted(app, "/cost comes with the model catalog")
    Client.Command.New -> switch_command(app, none)
    Client.Command.Resume(none) -> tried(app, picking(app))
    Client.Command.Resume(choice) -> switch_command(app, choice)
    Client.Command.Tree(choice) -> tried(app, tree_command(app, Picker.Kind.Tree, choice))
    Client.Command.Fork(choice) -> tried(app, tree_command(app, Picker.Kind.Fork, choice))
    Client.Command.Clone -> move(app, Picker.Kind.Fork, none)
    Client.Command.Model(model) -> model_command(app, model)
    Client.Command.Thinking(level) -> thinking_command(app, level)
    Client.Command.Compact -> compact_command(app)
    Client.Command.Login(name) -> login_command(app, name)
    Client.Command.Logout(name) -> tried(app, logout_command(app, name))
  end
end

def login_command(app: Model, name: Optional[String]) -> Model
  for given in option_list(name)
    return tried(app, named_from_server(app, given))
  end

  tried(app, login_picking(app))
end

def named_from_server(app: Model, name: String) -> Result[Model]
  ok(named_login(app, (try Client.list_logins(app.server)).providers, name))
end

def login_picking(app: Model) -> Result[Model]
  ok(app.with(picker: some(Picker.logins(try Client.list_logins(app.server)))))
end

def login_picked(app: Model, picker: Picker.Picker, name: String) -> Model = named_login(app, picker.logins, name)

# A name that is no login is not shown again: it may be a key typed in the wrong place.
def named_login(app: Model, logins: List[Protocol.LoginStatus], name: String) -> Model
  found = logins.select { |l| l.name == name }
  return login_closed(noted(app, "no login has that name: /login lists them")) if found.empty?
  return login_closed(noted(app, "#{found[0].label}: coming, there is no login for it yet")) if found[0].coming

  asking(app, name)
end

def asking(app: Model, name: String) -> Model
  noted(app.with(key_for: some(name), secret: ""), "the key of #{name}: typed hidden, Enter checks it, Esc cancels")
end

# The key goes only into the command that sends it; the model keeps no copy.
def on_secret_key(app: Model, name: String, event: TUI.Event) -> Model
  case event
    TUI.Event.Char(char, _) -> app.with(secret: app.secret + char)
    TUI.Event.Paste(text) -> app.with(secret: app.secret + Prompt.pasted(text).strip)
    TUI.Event.Key(TUI.Key.Backspace, _) ->
      app.with(secret: app.secret.slice(0, [app.secret.length - 1, 0].max.unwrap!))
    TUI.Event.Key(TUI.Key.Escape, _) -> login_closed(noted(app.with(key_for: none, secret: ""), "no key given"))
    TUI.Event.Key(TUI.Key.Enter, _) if not app.secret.strip.empty? ->
      server = app.server
      key = app.secret.strip
      checking = noted(app.with(key_for: none, secret: ""), "checking the key of #{name}")
      effect(checking, TUI.Cmd.Run(-> { Msg.LoggedIn(name, Client.login(server, name, key)) }))
    _ -> app
  end
end

def logged_in(app: Model, name: String, result: Result[Protocol.LoginStatus]) -> Model
  done = case result
    ok(status) if status.from == "env" ->
      noted(app, "#{name}: the key is stored, but #{status.key_env} is set and wins over it")
    ok(status) -> noted(app, "#{name} is set up (#{status.key_env} would also work): /model lists its models")
    error(e) -> noted(app, "error: #{e.message}")
  end

  return done.with(first_login: false) if not app.login_only
  return done.with(exit: some(0)) if result.ok?

  done.with(exit: some(1))
end

# A first-start login closed with no key stores an empty key file, so it is offered once; `finn login` ends.
def login_closed(app: Model) -> Model
  return app.with(exit: some(1)) if app.login_only
  return app if not app.first_login

  _ = Client.skip_login(app.server)
  noted(app.with(first_login: false), "/login sets up a provider later")
end

def logout_command(app: Model, name: Optional[String]) -> Result[Model]
  try Client.logout(app.server, name)
  removed = name.map { |n| "the key of #{n} is removed" }.unwrap_or("every stored key is removed")
  ok(noted(app, removed))
end

def note_entry(text: String) -> Transcript.Entry = Transcript.Entry(kind: Transcript.Kind.Notice, text: text)

def stop_command(app: Model) -> Model
  return noted(app, "no turn is running") if not busy?(app)

  stop(app)
end

# A command that failed says why; the session goes on.
def tried(app: Model, result: Result[Model]) -> Model
  case result
    ok(next_app) -> next_app
    error(e) -> noted(app, "error: #{e.message}")
  end
end

# The state of no session yet, with the stream that `subscribe` replaces; the follow-ups not sent wait in the prompt.
def fresh(app: Model) -> Model
  kept = app.with(prompt: "", cursor: 0)
  if not app.follow_ups.empty?
    kept = put_back(app)
  end

  seed(app.server, app.options, app.signals, app.width, app.height).with(
    prompt: kept.prompt,
    cursor: kept.cursor,
    thinking: app.thinking,
    tools: app.tools,
    theme: app.theme,
    stream: app.stream,
    feed: app.feed,
    generation: app.generation,
    now: app.now,
    clock_s: app.clock_s,
    effects: app.effects,
    opened: app.opened,
  )
end

# A new session (no choice), or the session `/resume` chose.
def switch_command(app: Model, choice: Optional[String]) -> Model
  return noted(app, "a turn is running: Esc stops it first") if app.turn
  return noted(app, "a message is being sent: wait for its reply first") if not app.outbox.empty?

  case choice
    some(picked) -> tried(app, switched(app, picked))
    none -> tried(app, create(fresh(app)))
  end
end

def picking(app: Model) -> Result[Model]
  list = try Client.list_sessions(app.server)
  return ok(noted(app, "no sessions")) if list.sessions.empty?

  ok(app.with(picker: some(Picker.Picker(sessions: list.sessions))))
end

def picked(app: Model, kind: Picker.Kind, key: String) -> Model
  return model_command(app, some(key)) if kind == Picker.Kind.Models

  case key.to_i
    ok(entry) if kind != Picker.Kind.Sessions -> move(app, kind, some(entry))
    _ -> switch_command(app, some(key))
  end
end

# The picker of the tree without a choice; else the move to the message the choice names in the tree the picker
# showed last (`/tree 2`, `/fork 1+`), so a message another client adds since does not change what a number names.
def tree_command(app: Model, kind: Picker.Kind, choice: Optional[String]) -> Result[Model]
  for picked in option_list(choice)
    return ok(noted(app, "open the list first: /tree")) if app.listed.none?

    return ok(move(app, kind, some(try Client.tree_entry(app.listed.unwrap!, picked))))
  end

  tree = try Client.tree(app.server, app.id)
  return ok(noted(app, "no messages yet")) if tree.nodes.empty?

  ok(app.with(picker: some(Picker.Picker(tree: Client.tree_rows(tree), kind: kind)), listed: some(tree)))
end

# A branch of this session from `entry` (`Kind.Tree`), or a new session from it (`Kind.Fork`), a copy when none. A
# command asks for it and `moved` opens the session it gives.
def move(app: Model, kind: Picker.Kind, entry: Optional[Int]) -> Model
  return noted(app, "a turn is running: Esc stops it first") if app.turn
  return noted(app, "a message is being sent: wait for its reply first") if not app.outbox.empty?
  return noted(app, "the session is moving: wait for it") if app.moving

  server = app.server
  id = app.id
  moving = app.with(moving: true)
  case kind
    Picker.Kind.Tree ->
      at = entry.unwrap_or(0)
      effect(moving, TUI.Cmd.Run(-> { Msg.Moved(Client.branch(server, id, at)) }))
    _ -> effect(moving, TUI.Cmd.Run(-> { Msg.Moved(Client.fork(server, id, entry)) }))
  end
end

# The session is drawn again from its start; the message it went back before waits in the prompt.
def moved(app: Model, result: Result[Protocol.Branched]) -> Model
  case result
    ok(done) ->
      opened = tried(app.with(moving: false), resume(fresh(app), done.id))
      return opened if done.text.empty?

      # Follow-ups put back in the prompt stay after the message; typing then adds to both.
      if opened.prompt != ""
        both = "#{done.text}\n#{opened.prompt}"
        return noted(opened.with(prompt: both, cursor: both.length), "went back before a message: it is in the prompt")
      end

      filled = opened.with(prompt: done.text, cursor: done.text.length, prefilled: true)
      noted(filled, "went back before a message: it is in the prompt (typing replaces it, an arrow keeps it)")
    error(e) -> noted(app.with(moving: false), "error: #{e.message}")
  end
end

def switched(app: Model, choice: String) -> Result[Model]
  resume(fresh(app), try Client.pick(try Client.list_sessions(app.server), choice))
end

def thinking_command(app: Model, level: Optional[String]) -> Model
  case level
    some(text) ->
      tried(app, changed(app, Protocol.UpdateSession(effort: level), "thinking #{text} from the next turn"))
    none -> tried(app, shown_thinking(app))
  end
end

def shown_thinking(app: Model) -> Result[Model]
  session = try Client.session(app.server, app.id)
  ok(noted(app, "thinking #{session.effort.unwrap_or("as the model's default")}"))
end

# `/model` opens the picker; `/model provider/model` moves the session to that provider when one has that name, else
# `/model NAME` changes the model.
def model_command(app: Model, given: Optional[String]) -> Model
  case given
    some(text) -> tried(app, model_changed(app, text))
    none -> tried(app, model_picking(app))
  end
end

def model_picking(app: Model) -> Result[Model]
  list = try Client.list_providers(app.server)
  ok(app.with(picker: some(Picker.models(list, app.serving))))
end

def model_changed(app: Model, text: String) -> Result[Model]
  current = app.serving.split("/")[0]
  change = Client.model_change(try Client.list_providers(app.server), current, text)
  done = try changed(app, change, "model #{text} from the next turn")
  ok(done.with(serving: serving_of(try Client.session(app.server, app.id))))
end

def changed(app: Model, change: Protocol.UpdateSession, done: String) -> Result[Model]
  try Client.update_session(app.server, app.id, change)
  shown = noted(app, done)
  for effort in option_list(change.effort)
    shown = shown.with(effort: level_of(effort), confirmed: level_of(effort))
  end

  return ok(shown) if change.model.none?

  ok(shown.with(new_model: change.model))
end

# The summary takes as long as a turn: a command asks for it and gives the outcome as a note.
def compact_command(app: Model) -> Model
  server = app.server
  id = app.id
  noted(effect(app, TUI.Cmd.Run(-> { Msg.Note(compacted(server, id)) })), "compacting the history")
end

def compacted(server: Client.Server, id: String) -> String
  case Client.compact(server, id)
    ok(folded) if folded -> "compacted"
    ok(_) -> "nothing to compact yet"
    error(e) -> "error: #{e.message}"
  end
end

## Stops what runs; with `turn_id`, only that turn, so a stop asked before a message's turn started cannot reach the
## turn after it.
def stop(app: Model, turn_id: Optional[String] = none) -> Model
  return noted(app.with(stop_wanted: true), "the turn stops once it starts") if not app.turn and not app.outbox.empty?
  return app if not busy?(app) or app.stopping

  server = app.server
  id = app.id
  stopping = "stopping the turn"
  if not app.turn
    stopping = "stopping the command"
  end

  effect(noted(app.with(stopping: true), stopping), TUI.Cmd.Run(-> { Msg.Stopped(Client.stop(server, id, turn_id)) }))
end

# The answer is sent by a command, so the keys go on; its reply comes back as a message.
def answer(app: Model, decision: Protocol.Decision) -> Model
  sent(app, app.approvals.pending[0].approval_id, decision).with(approvals: Approvals.sending(app.approvals))
end

def sent(app: Model, approval_id: String, decision: Protocol.Decision) -> Model
  server = app.server
  id = app.id
  effect(app, TUI.Cmd.Run(-> { Msg.Answered(approval_id, Client.approve(server, id, approval_id, decision)) }))
end

def allowed(app: Model, request: Protocol.ApprovalRequested) -> Model
  allowing = sent(app, request.approval_id, Protocol.Decision.Allow).with(yolo: Yolo.allowing(app.yolo, request))
  noted(allowing, "--yolo allows #{request.tool}: #{request.preview}")
end

# An allow of `--yolo` that was not sent leaves its approval to the panel.
def unyolo(app: Model, approval_id: String, result: Result[Void]) -> Model
  back = Yolo.unsent(app.yolo, approval_id, result)
  rest = app.with(yolo: Yolo.resolved(app.yolo, approval_id))
  case back
    some(request) -> rest.with(approvals: Approvals.requested(rest.approvals, request, app.now))
    none -> rest
  end
end

def resolved(app: Model, approval_id: String) -> Model
  app.with(
    approvals: Approvals.resolved(app.approvals, approval_id, app.now),
    yolo: Yolo.resolved(app.yolo, approval_id),
  )
end

def noted(app: Model, text: String) -> Model = app.with(entries: Transcript.note(app.entries, text))

def on_stream(app: Model, item: Client.Item) -> Model
  case item
    Client.Item.Opened -> app.with(reconnects: 0)
    Client.Item.Event(_, Protocol.Event.Resync) -> resync(app)
    Client.Item.Event(id, event) -> on_event(app.with(resyncs: 0), id, event)
    Client.Item.Skipped(reason) -> noted(app, reason)
    Client.Item.Ended(reason) -> reconnect(app, reason)
  end
end

def on_event(app: Model, id: Optional[Int], event: Protocol.Event) -> Model
  seen = id.unwrap_or(app.last_event_id)
  return app.with(last_event_id: seen) if id.some? and seen <= app.shown_id

  shown = app.with(last_event_id: seen, shown_id: seen)
  case event
    Protocol.Event.TextDelta(delta) ->
      shown.with(entries: Transcript.add(shown.entries, Transcript.Kind.Assistant, delta.text))
    Protocol.Event.ThinkingDelta(delta) ->
      shown.with(entries: Transcript.add(shown.entries, Transcript.Kind.Thinking, delta.text))
    Protocol.Event.TurnStarted(started) ->
      shown.with(turn: true, yolo: Yolo.running(shown.yolo, some(started.turn_id)))
    Protocol.Event.TurnFinished(done) ->
      ended = shown.with(turn: false, stopping: false, new_model: none, yolo: Yolo.running(shown.yolo, none))
      after_turn(finished(ended, done.stop_reason), done.stop_reason)
    Protocol.Event.ApprovalRequested(request) if Yolo.allows?(shown.yolo) -> allowed(shown, request)
    Protocol.Event.ApprovalRequested(request) ->
      shown.with(approvals: Approvals.requested(shown.approvals, request, app.now))
    Protocol.Event.ApprovalResolved(done) ->
      decided = "approval #{done.approval_id}: #{Protocol.decision_name(done.decision)}"
      noted(resolved(shown, done.approval_id), "#{decided} (#{Protocol.source_name(done.source)})")
    Protocol.Event.ToolStarted(tool) -> shown.with(entries: Transcript.tool_started(shown.entries, tool))
    Protocol.Event.ToolFinished(tool) -> shown.with(entries: Transcript.tool_finished(shown.entries, tool))
    Protocol.Event.ShellStarted(started) ->
      tool = Protocol.ToolStarted(call_id: started.shell_id, name: Calls.BASH, summary: started.command)
      shown.with(shell: true, entries: Transcript.tool_started(shown.entries, tool))
    Protocol.Event.ShellFinished(done) ->
      # Started again in place, so a command whose start was not seen still draws as one.
      start = Protocol.ToolStarted(call_id: done.shell_id, name: Calls.BASH, summary: done.command)
      tool = Protocol.ToolFinished(
        call_id: done.shell_id,
        ok: done.ok,
        summary: "",
        duration_ms: done.duration_ms,
        output: some(done.output),
      )

      aside = ""
      if not done.context
        aside = "not sent to the model"
      end

      # A command that a restart cut has no duration.
      timed = done.duration_ms > 0
      entries = Transcript.tool_finished(Transcript.tool_started(shown.entries, start), tool, aside, timed)
      shown.with(shell: false, stopping: false, entries: entries)
    # An error (a write of `shell_finished` that failed) also ends a command: no other event of it comes.
    Protocol.Event.Error(failure) ->
      failed = noted(shown.with(shell: false), "error: #{failure.kind}: #{failure.message}")
      case shown.new_model
        some(model) -> noted(failed.with(new_model: none), "warning: #{Client.model_warning(model)}")
        none -> failed
      end

    Protocol.Event.MessageQueued(queued) ->
      steered = shown.with(yolo: Yolo.steered(shown.yolo, queued))
      noted(steered, "queued: #{Client.printable(queued.text)}")
    _ -> shown
  end
end

def busy?(app: Model) -> Bool = app.turn or app.shell

def folds(app: Model) -> Transcript.Folds = Transcript.Folds(thinking: app.thinking, tools: app.tools)

def shown_name(shown: Bool) -> String
  return "shown" if shown

  "folded"
end

def finished(app: Model, reason: Protocol.StopReason) -> Model
  case reason
    Protocol.StopReason.EndTurn -> app
    Protocol.StopReason.Cancelled -> noted(app, "stopped")
    _ -> noted(app, "the turn ended: #{Protocol.stop_reason_name(reason)}")
  end
end

def resync(app: Model) -> Model
  return app.with(failure: some("the server keeps asking to read the session again")) if app.resyncs >= MAX_RESYNCS

  case Client.session(app.server, app.id)
    ok(session) -> attach(app.with(resyncs: app.resyncs + 1), session, app.resyncs >= 1)
    error(e) -> app.with(failure: some(e.message))
  end
end

# The stream is read again after a pause that grows, once the server is checked to be the same version.
def reconnect(app: Model, reason: String) -> Model
  reconnects = app.reconnects + 1
  return app.with(failure: some("lost the event stream: #{reason}")) if reconnects > MAX_RECONNECTS

  server = app.server
  generation = app.generation
  pause = RECONNECT_MS * reconnects
  back = TUI.Cmd.Run(
    -> {
      Task.sleep(pause)
      Msg.Rechecked(generation, Client.recheck(server))
    },
  )

  effect(app.with(reconnects: reconnects), back)
end

def framed(app: Model) -> Screen.Frame
  prompt = Prompt.view(app.prompt, cursor(app), app.width, app.height)
  for name in option_list(app.key_for)
    hidden = "key of #{name}: #{"•" * app.secret.length}"
    prompt = Prompt.view(hidden, hidden.length, app.width, app.height)
  end

  parts = Screen.Parts(
    prompt: prompt,
    picker: ->(room: Int) { picker_rows(app, room) },
    panel: ->(room: Int) { approval_rows(app, room) },
    label: label(app),
    level: app.effort,
    status: status(app, app.width),
    queued: app.follow_ups.map { |text| "follow-up: #{Client.printable(text)}" },
  )

  Screen.frame(
    app.width,
    app.height,
    Transcript.tail(app.entries, app.width, folds(app), app.height + app.scroll),
    app.scroll,
    parts,
  )
end

# The rows of the approval panel, without the transcript: a key needs only these.
def panel(app: Model) -> List[Layout.Row]
  rows = Prompt.view(app.prompt, cursor(app), app.width, app.height).rows.size
  approval_rows(app, Screen.panel_room(app.height, rows))
end

# The session picker of `/resume`, in the editor's place.
def picker_rows(app: Model, room: Int) -> List[Layout.Row]
  case app.picker
    some(picker) -> Picker.rows(picker, app.width, room, app.clock_s)
    none -> []
  end
end

# The approval asked, under the editor; none while the picker is open.
def approval_rows(app: Model, room: Int) -> List[Layout.Row]
  return [] if app.picker.some?

  asked = Approvals.rows(app.approvals, app.width, room)
  return asked if not asked.empty?

  case mention_list(app)
    some(found) ->
      choices = mention_choices(app, found)
      selected = [[app.mention_selected, choices.size - 1].min.unwrap!, 0].max.unwrap!
      Input.rows(choices, selected, Input.window(app.mention_top, selected, room, choices.size), app.width, room)
    none -> []
  end
end

# The spinner and what the turn does, in the top rule.
def label(app: Model) -> String
  return "#{SPINNER[app.spin]} Stopping" if app.stopping
  return "#{SPINNER[app.spin]} Working" if busy?(app)

  ""
end

# Shift+Tab: the next thinking level; the rules take its color at once.
def leveled(app: Model) -> Model
  at = LEVELS.find_index { |level| level == app.effort }.unwrap_or(0)
  wanted = app.with(effort: LEVELS[(at + 1) % LEVELS.size])
  return wanted if wanted.level_sending.some?

  send_level(wanted)
end

def send_level(app: Model) -> Model
  name = level_name(app.effort)
  server = app.server
  id = app.id
  change = Protocol.UpdateSession(effort: some(name))
  effect(
    app.with(level_sending: some(name)),
    TUI.Cmd.Run(-> { Msg.Leveled(Client.update_session(server, id, change)) }),
  )
end

# A level wanted while the change was on its way goes next; the note comes once the level settles, and a failure
# with nothing newer wanted goes back to the server's level.
def level_reply(app: Model, result: Result[Void]) -> Model
  # A reply after /new or a switch belongs to the session before.
  return app if app.level_sending.none?

  sent = app.level_sending.unwrap_or("")
  done = app.with(level_sending: none)
  if result.ok?
    done = done.with(confirmed: level_of(sent))
  end

  return send_level(done) if level_name(app.effort) != sent

  case result
    ok(_) -> noted(done, "thinking #{sent} from the next turn")
    error(e) -> noted(done.with(effort: done.confirmed), "error: the thinking level was not set: #{e.message}")
  end
end

# A level wanted while its change is on its way stays across a new read of the session.
def wanted_level(app: Model, server: Optional[String]) -> Optional[String]
  return app.effort if app.level_sending.some?

  server
end

def level_of(effort: String) -> Optional[String]
  return none if effort == Protocol.EFFORT_DEFAULT

  some(effort)
end

def level_name(level: Optional[String]) -> String = level.unwrap_or(Protocol.EFFORT_DEFAULT)

def serving_of(session: Protocol.Session) -> String = "#{session.provider}/#{session.model}"

# `provider/model` as `(provider) model`.
def footer_model(serving: String) -> String
  case serving.index_of("/")
    some(at) -> "(#{serving.slice(0, at)}) #{serving.slice(at + 1, serving.length - at - 1)}"
    none -> serving
  end
end

# What the turn does is in the top rule; the status line says when the client is ready.
def status(app: Model, width: Int) -> String
  parts: List[String] = []
  if app.options.yolo
    parts = parts.push("YOLO")
  end

  if not busy?(app)
    parts = parts.push("ready")
  end

  if not app.approvals.pending.empty?
    parts = parts.push("approval waiting")
  end

  if not app.serving.empty?
    parts = parts.push(footer_model(app.serving))
  end

  text = " #{parts.join(" · ")}"
  for hint in HINTS
    more = "#{text} · #{hint}"
    if text == " "
      more = " #{hint}"
    end

    break if Width.text(more) > width

    text = more
  end

  text + " " * [width - Width.text(text), 0].max.unwrap!
end
