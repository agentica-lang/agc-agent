## One session on the full screen, as an Elm program of agentica-tui: the `Model` holds the whole state, `update`
## takes the keys and the events of the server as messages and gives the next model with the work to start, and
## `view` draws a model. The event stream, the signals, the answers of approvals and the compactions run as commands,
## each giving one message, which `update` arms again. The short calls to the server (send, stop, session, list,
## update) run inside `update`, so the loop waits at most the client's call timeout (10 s) for each of them.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import Approvals from "approvals"
import Args from "args"
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
YOLO_WARNING = "--yolo: the tool calls of turns sent from here run without asking"
## The key hints of the status line, most needed first: those that do not fit are left out.
HINTS = ["Enter send", "Esc stop", "^C quit", "^J newline", "⇧Tab level", "^T thinking", "^O tools", "PgUp/PgDn"]
SPINNER = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
SPIN_MS = 80
## The thinking levels Shift+Tab goes through, none for the model's default.
LEVELS: List[Optional[String]] = [none, some("low"), some("medium"), some("high")]

struct Model
  server: Client.Server
  id: String
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
  ## Esc came before the turn of a message sent started: the turn stops once the reply says it did.
  stop_wanted: Bool = false
  ## How many times a session was opened, so the reply to a send made before is dropped.
  opened: Int = 0
  ## The picker of `/resume`, `/tree` or `/fork`, open over the prompt.
  picker: Optional[Picker.Picker] = none
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
end

## Runs the session of `options` on `screen` until the user leaves or a signal ends it: the exit code.
def run(screen: TUI.Raw.Screen, server: Client.Server, options: Args.Options) -> Result[Int]
  signals = try System.subscribe([System.Signal.Term, System.Signal.Hup, System.Signal.Int])
  palette = Theme.colors256?(System.env("TERM").unwrap_or(""), System.env("COLORTERM").unwrap_or(""))
  output = TUI.OutputMode.Colors256
  start = try opened(seed(server, options, signals, TUI.Raw.width(screen), TUI.Raw.height(screen)))
  if not palette
    output = TUI.OutputMode.Normal
    start = start.with(theme: Theme.basic())
  end

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

  last = try TUI.Raw.program(screen, app)
  case last.failure
    some(reason) -> error(reason, kind: "tui.session")
    none -> ok(last.exit.unwrap_or(0))
  end
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

## The session of the options opened, with the signals listened to.
def opened(model: Model) -> Result[Model]
  app = try open(model, model.options)
  if model.options.yolo
    app = noted(app, YOLO_WARNING)
  end

  ok(effect(app, listen(app.signals)))
end

def update(model: Model, msg: Msg) -> TUI.Step[Model, Msg]
  app = handled(model.with(now: Time.monotonic_ms, clock_s: Time.now_ms / 1000), msg)
  # The answer that streams changes on every delta: it is cut again when the stream rests.
  if not stream?(msg)
    app = app.with(entries: Transcript.wrapped(app.entries, app.width, folds(app)))
  end

  cmds = app.effects
  if app.exit.some? or app.failure.some?
    cmds = cmds.push(TUI.Cmd.Quit)
  end

  TUI.Step(model: app.with(effects: []), cmds: cmds)
end

def view(model: Model) -> TUI.Node = Screen.view(framed(model), model.theme)

def subscriptions(model: Model) -> List[TUI.Sub[Msg]]
  keys = TUI.Sub.Events(->(event) { Msg.Key(event) })
  return [keys] if not model.turn

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
    Msg.Rechecked(generation, result) if generation == app.generation -> rechecked(app, result)
    Msg.Rechecked(_, _) -> app
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

# The next items of the stream: the first that comes, and those that wait after it.
def read_feed(generation: Int, feed: Channel[Client.Item]) -> TUI.Cmd[Msg]
  TUI.Cmd.Run(-> { Msg.Stream(generation, drained(feed)) })
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

  request = Protocol.NewSession(cwd: cwd, model: options.model, api: options.api)
  id = try Client.create_session(app.server, request)
  ok(subscribe(noted(app.with(id: id, opened: app.opened + 1), "session #{id}"), 0))
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

  fresh = app.with(
    opened: app.opened + 1,
    entries: Transcript.from_history(session.history),
    turn: session.turn_id.some?,
    effort: wanted_level(app, session.effort),
    confirmed: session.effort,
    stopping: false,
    shown_id: from,
    approvals: Approvals.replaced(app.approvals, session.pending_approvals, app.now),
    yolo: Yolo.attached(app.yolo, session.turn_id, not skip_replay),
  )

  subscribe(fresh, from)
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
  for picker in option_list(app.picker)
    return on_picker_key(app, picker, event) if not ctrl_c?(event)
  end

  case Approvals.decision(app.approvals, event, app.now, not panel(app).empty?)
    some(decision) -> return answer(app, decision)
    none -> nil
  end

  return app if Approvals.captures?(app.approvals, event)

  case event
    TUI.Event.Key(TUI.Key.Ctrl("c"), _) -> app.with(exit: some(0))
    TUI.Event.Key(TUI.Key.Enter, _) -> send(app)
    TUI.Event.Key(TUI.Key.Ctrl("t"), _) ->
      shown = app.with(thinking: not app.thinking, entries: Transcript.unfold_thinking(app.entries))
      noted(shown, "thinking blocks: #{shown_name(shown.thinking)}")
    TUI.Event.Key(TUI.Key.Ctrl("o"), _) ->
      shown = app.with(tools: not app.tools, entries: Transcript.unfold_tools(app.entries))
      noted(shown, "tool output: #{shown_name(shown.tools)}")
    TUI.Event.Key(TUI.Key.Ctrl("j"), _) -> typed(app, "\n")
    TUI.Event.Key(TUI.Key.Backspace, _) ->
      at = cursor(app)
      app.with(prompt: Prompt.backspace(app.prompt, at), cursor: [at - 1, 0].max.unwrap!)
    TUI.Event.Key(TUI.Key.Left, _) -> app.with(cursor: [cursor(app) - 1, 0].max.unwrap!)
    TUI.Event.Key(TUI.Key.Right, _) -> app.with(cursor: Prompt.clamp(app.prompt, cursor(app) + 1))
    TUI.Event.Key(TUI.Key.Home, _) -> app.with(cursor: 0)
    TUI.Event.Key(TUI.Key.End, _) -> app.with(cursor: app.prompt.length)
    TUI.Event.Mouse(TUI.Mouse.Left, x, y, mods) if not mods.motion -> clicked(app, x, y)
    TUI.Event.Key(TUI.Key.Tab, _) -> app.with(approvals: Approvals.toggled(app.approvals, app.now))
    TUI.Event.Key(TUI.Key.BackTab, _) -> leveled(app)
    TUI.Event.Key(TUI.Key.Escape, _) if app.approvals.focused ->
      app.with(approvals: Approvals.toggled(app.approvals, app.now))
    TUI.Event.Key(TUI.Key.Escape, _) -> stop(app)
    TUI.Event.Key(TUI.Key.PageUp, _) -> scrolled(app, page(app))
    TUI.Event.Key(TUI.Key.PageDown, _) -> scrolled(app, -page(app))
    TUI.Event.Mouse(TUI.Mouse.WheelUp, _, _, _) -> scrolled(app, SCROLL_STEP)
    TUI.Event.Mouse(TUI.Mouse.WheelDown, _, _, _) -> scrolled(app, -SCROLL_STEP)
    TUI.Event.Char(char, _) -> typed(app, char)
    TUI.Event.Paste(text) -> typed(app, Prompt.pasted(text))
    _ -> app
  end
end

def cursor(app: Model) -> Int = Prompt.clamp(app.prompt, app.cursor)

def typed(app: Model, piece: String) -> Model
  at = cursor(app)
  app.with(prompt: Prompt.insert(app.prompt, at, piece), cursor: at + piece.length)
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
    Picker.Step.Close -> app.with(picker: none)
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
  text = app.prompt.strip
  return app if text == ""

  case Client.parse_command(text)
    some(ok(command)) -> return on_command(app.with(prompt: "", scroll: 0), command)
    some(error(e)) -> return noted(app, e.message)
    _ -> nil
  end

  queued = app.with(prompt: "", scroll: 0, outbox: app.outbox.push(text))
  return queued if not app.outbox.empty?

  sending(queued, text)
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
# back to an empty prompt.
def sent_reply(app: Model, text: String, result: Result[Protocol.MessageAccepted]) -> Model
  case result
    ok(accepted) if accepted.message_id.some? ->
      queued = app.with(yolo: Yolo.accepted(app.yolo, accepted))
      return queued if not app.stop_wanted

      # The message went into a turn that runs (another client's): that is the turn Esc asked to stop.
      stop(queued.with(turn: true, stop_wanted: false))
    ok(accepted) ->
      entries = Transcript.add(app.entries, Transcript.Kind.User, text)
      started = app.with(entries: entries, turn: true, stopping: false, yolo: Yolo.accepted(app.yolo, accepted))
      return started if not app.stop_wanted

      stop(started.with(stop_wanted: false))
    # The text stays in the note: put back in the prompt, it would take the keys typed after it.
    error(e) if e.kind == Client.KIND_TIMEOUT ->
      noted(app, "error: the message may not have been sent (#{e.message}): #{Client.printable(text)}")
    error(e) -> noted(app, "error: the message was not sent: #{e.message}: #{Client.printable(text)}")
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
    Client.Command.Help -> app.with(entries: app.entries + Client.HELP.map { |line| note_entry(line) })
    Client.Command.Cost -> noted(app, "/cost comes with the model catalog")
    Client.Command.New -> switch_command(app, none)
    Client.Command.Resume(none) -> tried(app, picking(app))
    Client.Command.Resume(choice) -> switch_command(app, choice)
    Client.Command.Tree(choice) -> tried(app, tree_command(app, Picker.Kind.Tree, choice))
    Client.Command.Fork(choice) -> tried(app, tree_command(app, Picker.Kind.Fork, choice))
    Client.Command.Clone -> move(app, Picker.Kind.Fork, none)
    Client.Command.Model(model) -> setting_command(app, "model", model, Protocol.UpdateSession(model: model))
    Client.Command.Thinking(level) -> setting_command(app, "thinking", level, Protocol.UpdateSession(effort: level))
    Client.Command.Compact -> compact_command(app)
  end
end

def note_entry(text: String) -> Transcript.Entry = Transcript.Entry(kind: Transcript.Kind.Notice, text: text)

def stop_command(app: Model) -> Model
  return noted(app, "no turn is running") if not app.turn

  stop(app)
end

# A command that failed says why; the session goes on.
def tried(app: Model, result: Result[Model]) -> Model
  case result
    ok(next_app) -> next_app
    error(e) -> noted(app, "error: #{e.message}")
  end
end

# The state of no session yet, with the stream that `subscribe` replaces.
def fresh(app: Model) -> Model
  seed(app.server, app.options, app.signals, app.width, app.height).with(
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
  case key.to_i
    ok(entry) if kind != Picker.Kind.Sessions -> move(app, kind, some(entry))
    _ -> switch_command(app, some(key))
  end
end

# The picker of the tree without a choice; else the move to the message the choice names (`/tree 2`, `/fork 1+`).
def tree_command(app: Model, kind: Picker.Kind, choice: Optional[String]) -> Result[Model]
  tree = try Client.tree(app.server, app.id)
  for picked in option_list(choice)
    return ok(move(app, kind, some(try Client.tree_entry(tree, picked))))
  end

  return ok(noted(app, "no messages yet")) if tree.nodes.empty?

  ok(app.with(picker: some(Picker.Picker(tree: Client.tree_rows(tree), kind: kind))))
end

# A branch of this session from `entry` (`Kind.Tree`), or a new session from it (`Kind.Fork`), a copy when none. A
# command asks for it and `moved` opens the session it gives.
def move(app: Model, kind: Picker.Kind, entry: Optional[Int]) -> Model
  return noted(app, "a turn is running: Esc stops it first") if app.turn
  return noted(app, "a message is being sent: wait for its reply first") if not app.outbox.empty?

  server = app.server
  id = app.id
  case kind
    Picker.Kind.Tree ->
      at = entry.unwrap_or(0)
      effect(app, TUI.Cmd.Run(-> { Msg.Moved(Client.branch(server, id, at)) }))
    _ -> effect(app, TUI.Cmd.Run(-> { Msg.Moved(Client.fork(server, id, entry)) }))
  end
end

# The session is drawn again from its start; the message it went back before waits in the prompt.
def moved(app: Model, result: Result[Protocol.Branched]) -> Model
  case result
    ok(done) ->
      opened = tried(app, resume(fresh(app), done.id))
      return opened if done.text.empty?

      noted(
        opened.with(prompt: done.text, cursor: done.text.length),
        "went back before a message: it is in the prompt",
      )
    error(e) -> noted(app, "error: #{e.message}")
  end
end

def switched(app: Model, choice: String) -> Result[Model]
  resume(fresh(app), try Client.pick(try Client.list_sessions(app.server), choice))
end

def setting_command(app: Model, name: String, value: Optional[String], change: Protocol.UpdateSession) -> Model
  case value
    some(text) -> tried(app, changed(app, change, "#{name} #{text} from the next turn"))
    none -> tried(app, shown_setting(app, name))
  end
end

def shown_setting(app: Model, name: String) -> Result[Model]
  session = try Client.session(app.server, app.id)
  return ok(noted(app, "model #{session.model}")) if name == "model"

  ok(noted(app, "thinking #{session.effort.unwrap_or("as the model's default")}"))
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

def stop(app: Model) -> Model
  return noted(app.with(stop_wanted: true), "the turn stops once it starts") if not app.turn and not app.outbox.empty?
  return app if not app.turn or app.stopping

  server = app.server
  id = app.id
  effect(
    noted(app.with(stopping: true), "stopping the turn"),
    TUI.Cmd.Run(-> { Msg.Stopped(Client.stop(server, id)) }),
  )
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
      finished(ended, done.stop_reason)
    Protocol.Event.ApprovalRequested(request) if Yolo.allows?(shown.yolo) -> allowed(shown, request)
    Protocol.Event.ApprovalRequested(request) ->
      shown.with(approvals: Approvals.requested(shown.approvals, request, app.now))
    Protocol.Event.ApprovalResolved(done) ->
      decided = "approval #{done.approval_id}: #{Protocol.decision_name(done.decision)}"
      noted(resolved(shown, done.approval_id), "#{decided} (#{Protocol.source_name(done.source)})")
    Protocol.Event.ToolStarted(tool) -> shown.with(entries: Transcript.tool_started(shown.entries, tool))
    Protocol.Event.ToolFinished(tool) -> shown.with(entries: Transcript.tool_finished(shown.entries, tool))
    Protocol.Event.Error(failure) ->
      failed = noted(shown, "error: #{failure.kind}: #{failure.message}")
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
  parts = Screen.Parts(
    prompt: Prompt.view(app.prompt, cursor(app), app.width, app.height),
    picker: ->(room: Int) { picker_rows(app, room) },
    panel: ->(room: Int) { approval_rows(app, room) },
    label: label(app),
    level: app.effort,
    status: status(app, app.width),
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

  Approvals.rows(app.approvals, app.width, room)
end

# The spinner and what the turn does, in the top rule.
def label(app: Model) -> String
  return "#{SPINNER[app.spin]} Stopping" if app.stopping
  return "#{SPINNER[app.spin]} Working" if app.turn

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

# What the turn does is in the top rule; the status line says when the client is ready.
def status(app: Model, width: Int) -> String
  parts: List[String] = []
  if app.options.yolo
    parts = parts.push("YOLO")
  end

  if not app.turn
    parts = parts.push("ready")
  end

  if not app.approvals.pending.empty?
    parts = parts.push("approval waiting")
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
