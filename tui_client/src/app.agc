## One session on the full screen: the loop that reads the keys and the events of the server, keeps the state in one
## immutable `App` and draws it after each batch of inputs.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import Approvals from "approvals"
import Args from "args"
import Inbox from "inbox"
import Markdown from "markdown"
import Picker from "picker"
import Layout from "panel"
import Prompt from "prompt"
import Transcript from "transcript"
import Width from "width"

INBOX_CAPACITY = 1024
WAIT_MS = 3_600_000
SEND_MS = 30_000
RECONNECT_MS = 300
MAX_RECONNECTS = 3
MAX_RESYNCS = 2
SCROLL_STEP = 3
HINTS = "Enter send · ^J newline · ^T thinking · Esc stop · PgUp/PgDn · ^C quit"

## Runs the session of `options` on `screen` until the user leaves or a signal ends it: the exit code.
def run(screen: TUI.Screen, server: Client.Server, options: Args.Options) -> Result[Int]
  try TUI.set_input_mode(screen, TUI.InputMode.Esc, true)
  inbox: Channel[Inbox.Input] = Channel.new(INBOX_CAPACITY)
  signals = try System.subscribe([System.Signal.Term, System.Signal.Hup, System.Signal.Int])
  _ = Task.spawn(-> { watch_signals(signals, inbox) })
  _ = Task.spawn(-> { read_keys(screen, inbox) })
  app = try open(
    App(
      screen: screen,
      server: server,
      id: "",
      inbox: inbox,
      options: options,
      thinking: options.thinking,
      approvals: Approvals.Panel(),
    ),
    options,
  )

  loop(app)
end

private

struct App
  screen: TUI.Screen
  server: Client.Server
  id: String
  inbox: Channel[Inbox.Input]
  ## What `/new` makes a session with.
  options: Args.Options
  entries: List[Transcript.Entry] = []
  prompt: String = ""
  ## Rows above the bottom of the transcript, 0 to follow its end.
  scroll: Int = 0
  turn: Bool = false
  stopping: Bool = false
  stream: Optional[Task[Void]] = none
  generation: Int = 0
  last_event_id: Int = 0
  ## The highest event id already drawn, so a replay draws nothing twice.
  shown_id: Int = 0
  reconnects: Int = 0
  ## `resync` events in a row, with no other event between.
  resyncs: Int = 0
  ## The session picker of `/resume`, open over the prompt.
  picker: Optional[Picker.Picker] = none
  ## The model `/model` set, until the turn after it ends: a failed call there gets a warning.
  new_model: Optional[String] = none
  ## A draw failed and the transcript says so; later failures are not noted again.
  draw_failed: Bool = false
  ## The thinking of the model is drawn.
  thinking: Bool = false
  approvals: Approvals.Panel
  exit: Optional[Int] = none
end

struct Row
  text: String
  style: TUI.Style
end

def watch_signals(signals: Channel[System.Signal], inbox: Channel[Inbox.Input]) -> Void
  while true
    case signals.recv(WAIT_MS)
      ok(signal) -> _ = inbox.send(Inbox.Input.Signal(signal), SEND_MS)
      error(_) -> break if signals.closed?
    end
  end
end

def read_keys(screen: TUI.Screen, inbox: Channel[Inbox.Input]) -> Void
  while true
    case TUI.poll_event(screen)
      ok(event) -> break if not inbox.send(Inbox.Input.Terminal(event), SEND_MS).ok?
      error(e) ->
        _ = inbox.send(Inbox.Input.Closed(e.message), SEND_MS)
        break
    end
  end
end

def open(app: App, options: Args.Options) -> Result[App]
  case options.session
    some(id) -> resume(app, id)
    none -> create(app)
  end
end

def create(app: App) -> Result[App]
  options = app.options
  cwd = case options.cwd
    some(dir) -> dir
    none -> try Path.cwd()
  end

  request = Protocol.NewSession(cwd: cwd, model: options.model, api: options.api)
  id = try Client.create_session(app.server, request)
  ok(subscribe(noted(app.with(id: id), "session #{id}"), 0))
end

def resume(app: App, id: String) -> Result[App]
  ok(noted(attach(app.with(id: id), try Client.session(app.server, id), false), "session #{id}"))
end

# Draws the history of the session and reads the events after it; while a turn runs, from the start of the turn, unless
# `skip_replay` (a server that no longer has that start).
def attach(app: App, session: Protocol.Session, skip_replay: Bool) -> App
  from = session.last_event_id
  if not skip_replay
    from = session.turn_from_event_id.unwrap_or(session.last_event_id)
  end

  fresh = app.with(
    entries: Transcript.from_history(session.history),
    turn: session.turn_id.some?,
    stopping: false,
    shown_id: from,
    approvals: Approvals.replaced(app.approvals, session.pending_approvals, Time.monotonic_ms),
  )

  subscribe(fresh, from)
end

def subscribe(app: App, from: Int) -> App
  if app.stream.some?
    Task.cancel(app.stream.unwrap!)
  end

  generation = app.generation + 1
  inbox = app.inbox
  feed = Client.Feed(
    server: app.server,
    session_id: app.id,
    last_event_id: from,
    tell: ->(item) { inbox.send(Inbox.Input.Stream(generation, item), SEND_MS) },
  )

  app.with(stream: some(Client.start(feed)), generation: generation, last_event_id: from)
end

def loop(start: App) -> Result[Int]
  app = start
  app = drawn(app)
  while app.exit.none?
    case app.inbox.recv(WAIT_MS)
      ok(input) ->
        app = try handle(app, input)
        while app.exit.none?
          case app.inbox.recv(0)
            ok(more) -> app = try handle(app, more)
            error(_) -> break
          end
        end

        app = drawn(app)

      error(_) -> next
    end
  end

  ok(app.exit.unwrap!)
end

def handle(app: App, input: Inbox.Input) -> Result[App]
  case input
    Inbox.Input.Terminal(event) -> ok(on_key(app, event))
    Inbox.Input.Note(text) -> ok(noted(app, text))
    Inbox.Input.Signal(signal) -> ok(app.with(exit: some(128 + System.signal_number(signal))))
    Inbox.Input.Answered(approval_id, result) ->
      outcome = Approvals.answered(app.approvals, approval_id, result, Time.monotonic_ms)
      answered = app.with(approvals: outcome.panel)
      case outcome.note
        some(text) -> ok(noted(answered, text))
        none -> ok(answered)
      end

    Inbox.Input.Closed(reason) -> error("the terminal closed: #{reason}", kind: "tui.terminal")
    Inbox.Input.Stream(generation, item) if generation == app.generation -> on_stream(app, item)
    Inbox.Input.Stream(_, _) -> ok(app)
  end
end

def on_key(app: App, event: TUI.Event) -> App
  for picker in option_list(app.picker)
    return on_picker_key(app, picker, event) if not ctrl_c?(event)
  end

  case Approvals.decision(app.approvals, event, Time.monotonic_ms, not panel(app).empty?)
    some(decision) -> return answer(app, decision)
    none -> nil
  end

  return app if Approvals.captures?(app.approvals, event)

  case event
    TUI.Event.Key(TUI.Key.Ctrl("c"), _) -> app.with(exit: some(0))
    TUI.Event.Key(TUI.Key.Enter, _) -> send(app)
    TUI.Event.Key(TUI.Key.Ctrl("t"), _) -> app.with(thinking: not app.thinking)
    TUI.Event.Key(TUI.Key.Ctrl("j"), _) -> app.with(prompt: Prompt.insert(app.prompt, "\n"))
    TUI.Event.Key(TUI.Key.Backspace, _) -> app.with(prompt: Prompt.backspace(app.prompt))
    TUI.Event.Key(TUI.Key.Tab, _) -> app.with(approvals: Approvals.toggled(app.approvals))
    TUI.Event.Key(TUI.Key.Escape, _) if app.approvals.focused -> app.with(approvals: Approvals.toggled(app.approvals))
    TUI.Event.Key(TUI.Key.Escape, _) -> stop(app)
    TUI.Event.Key(TUI.Key.PageUp, _) -> scrolled(app, page(app))
    TUI.Event.Key(TUI.Key.PageDown, _) -> scrolled(app, -page(app))
    TUI.Event.Mouse(TUI.Mouse.WheelUp, _, _, _) -> scrolled(app, SCROLL_STEP)
    TUI.Event.Mouse(TUI.Mouse.WheelDown, _, _, _) -> scrolled(app, -SCROLL_STEP)
    TUI.Event.Char(char, _) -> app.with(prompt: Prompt.insert(app.prompt, char))
    _ -> app
  end
end

def ctrl_c?(event: TUI.Event) -> Bool
  case event
    TUI.Event.Key(TUI.Key.Ctrl("c"), _) -> true
    _ -> false
  end
end

def on_picker_key(app: App, picker: Picker.Picker, event: TUI.Event) -> App
  case Picker.key(picker, event)
    Picker.Step.Stay(next_picker) -> app.with(picker: some(next_picker))
    Picker.Step.Close -> app.with(picker: none)
    Picker.Step.Pick(id) -> switch_command(app.with(picker: none), some(id))
  end
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end

def page(app: App) -> Int = [TUI.height(app.screen) / 2, 1].max.unwrap!

def scrolled(app: App, rows: Int) -> App = app.with(scroll: [app.scroll + rows, 0].max.unwrap!)

def send(app: App) -> App
  text = app.prompt.strip
  return app if text == ""

  case Client.parse_command(text)
    some(ok(command)) -> return on_command(app.with(prompt: "", scroll: 0), command)
    some(error(e)) -> return noted(app, e.message)
    _ -> nil
  end

  return noted(app, "a turn is running: Esc stops it") if app.turn

  case Client.send_message(app.server, app.id, text)
    ok(_) ->
      entries = Transcript.add(app.entries, Transcript.Kind.User, text)
      app.with(entries: entries, prompt: "", turn: true, stopping: false, scroll: 0)
    error(e) if e.kind == Protocol.KIND_SESSION_BUSY -> noted(app.with(turn: true), "a turn is already running")
    error(e) -> noted(app, "error: #{e.message}")
  end
end

def on_command(app: App, command: Client.Command) -> App
  case command
    Client.Command.Quit -> app.with(exit: some(0))
    Client.Command.Stop -> stop_command(app)
    Client.Command.Help -> app.with(entries: app.entries + Client.HELP.map { |line| note_entry(line) })
    Client.Command.Cost -> noted(app, "/cost comes with the model catalog")
    Client.Command.New -> switch_command(app, none)
    Client.Command.Resume(none) -> tried(app, picking(app))
    Client.Command.Resume(choice) -> switch_command(app, choice)
    Client.Command.Model(model) -> setting_command(app, "model", model, Protocol.UpdateSession(model: model))
    Client.Command.Thinking(level) -> setting_command(app, "thinking", level, Protocol.UpdateSession(effort: level))
    Client.Command.Compact -> compact_command(app)
  end
end

def note_entry(text: String) -> Transcript.Entry = Transcript.Entry(kind: Transcript.Kind.Notice, text: text)

def stop_command(app: App) -> App
  return noted(app, "no turn is running") if not app.turn

  stop(app)
end

# A command that failed says why; the session goes on.
def tried(app: App, result: Result[App]) -> App
  case result
    ok(next_app) -> next_app
    error(e) -> noted(app, "error: #{e.message}")
  end
end

# The state of no session yet, with the stream that `subscribe` replaces.
def fresh(app: App) -> App
  App(
    screen: app.screen,
    server: app.server,
    id: "",
    inbox: app.inbox,
    options: app.options,
    thinking: app.thinking,
    approvals: Approvals.Panel(),
    stream: app.stream,
    generation: app.generation,
  )
end

# A new session (no choice), or the session `/resume` chose.
def switch_command(app: App, choice: Optional[String]) -> App
  return noted(app, "a turn is running: Esc stops it first") if app.turn

  case choice
    some(picked) -> tried(app, switched(app, picked))
    none -> tried(app, create(fresh(app)))
  end
end

def picking(app: App) -> Result[App]
  list = try Client.list_sessions(app.server)
  return ok(noted(app, "no sessions")) if list.sessions.empty?

  ok(app.with(picker: some(Picker.Picker(sessions: list.sessions))))
end

def switched(app: App, choice: String) -> Result[App]
  resume(fresh(app), try Client.pick(try Client.list_sessions(app.server), choice))
end

def setting_command(app: App, name: String, value: Optional[String], change: Protocol.UpdateSession) -> App
  case value
    some(text) -> tried(app, changed(app, change, "#{name} #{text} from the next turn"))
    none -> tried(app, shown_setting(app, name))
  end
end

def shown_setting(app: App, name: String) -> Result[App]
  session = try Client.session(app.server, app.id)
  return ok(noted(app, "model #{session.model}")) if name == "model"

  ok(noted(app, "thinking #{session.effort.unwrap_or("as the model's default")}"))
end

def changed(app: App, change: Protocol.UpdateSession, done: String) -> Result[App]
  try Client.update_session(app.server, app.id, change)
  shown = noted(app, done)
  return ok(shown) if change.model.none?

  ok(shown.with(new_model: change.model))
end

# The summary takes as long as a turn: a task asks for it and puts the outcome on the inbox.
def compact_command(app: App) -> App
  server = app.server
  id = app.id
  inbox = app.inbox
  _ = Task.spawn(-> { _ = inbox.send(Inbox.Input.Note(compacted(server, id)), SEND_MS) })
  noted(app, "compacting the history")
end

def compacted(server: Client.Server, id: String) -> String
  case Client.compact(server, id)
    ok(folded) if folded -> "compacted"
    ok(_) -> "nothing to compact yet"
    error(e) -> "error: #{e.message}"
  end
end

def stop(app: App) -> App
  return app if not app.turn or app.stopping

  case Client.stop(app.server, app.id)
    ok(_) -> noted(app.with(stopping: true), "stopping the turn")
    error(e) -> noted(app, "error: the stop was not sent: #{e.message}")
  end
end

# The answer is sent by a task, so the keys go on; its reply comes back on the inbox.
def answer(app: App, decision: Protocol.Decision) -> App
  server = app.server
  id = app.id
  inbox = app.inbox
  approval_id = app.approvals.pending[0].approval_id
  _ = Task.spawn(
    -> {
      result = Client.approve(server, id, approval_id, decision)
      _ = inbox.send(Inbox.Input.Answered(approval_id, result), SEND_MS)
    },
  )

  app.with(approvals: Approvals.sending(app.approvals))
end

def resolved(app: App, approval_id: String) -> App
  app.with(approvals: Approvals.resolved(app.approvals, approval_id, Time.monotonic_ms))
end

def noted(app: App, text: String) -> App = app.with(entries: Transcript.note(app.entries, text))

def on_stream(app: App, item: Client.Item) -> Result[App]
  case item
    Client.Item.Opened -> ok(app.with(reconnects: 0))
    Client.Item.Event(_, Protocol.Event.Resync) -> resync(app)
    Client.Item.Event(id, event) -> ok(on_event(app.with(resyncs: 0), id, event))
    Client.Item.Skipped(reason) -> ok(noted(app, reason))
    Client.Item.Ended(reason) -> reconnect(app, reason)
  end
end

def on_event(app: App, id: Optional[Int], event: Protocol.Event) -> App
  seen = id.unwrap_or(app.last_event_id)
  return app.with(last_event_id: seen) if id.some? and seen <= app.shown_id

  shown = app.with(last_event_id: seen, shown_id: seen)
  case event
    Protocol.Event.TextDelta(delta) ->
      shown.with(entries: Transcript.add(shown.entries, Transcript.Kind.Assistant, delta.text))
    Protocol.Event.ThinkingDelta(delta) ->
      shown.with(entries: Transcript.add(shown.entries, Transcript.Kind.Thinking, delta.text))
    Protocol.Event.TurnStarted(_) -> shown.with(turn: true)
    Protocol.Event.TurnFinished(done) ->
      finished(shown.with(turn: false, stopping: false, new_model: none), done.stop_reason)
    Protocol.Event.ApprovalRequested(request) ->
      shown.with(approvals: Approvals.requested(shown.approvals, request, Time.monotonic_ms))
    Protocol.Event.ApprovalResolved(done) ->
      decided = "approval #{done.approval_id}: #{Protocol.decision_name(done.decision)}"
      noted(resolved(shown, done.approval_id), "#{decided} (#{Protocol.source_name(done.source)})")
    Protocol.Event.ToolStarted(tool) ->
      text = "⚙ #{tool.name} #{tool.summary}"
      shown.with(entries: Transcript.tool(shown.entries, tool.call_id, Transcript.Kind.Tool, text))
    Protocol.Event.ToolFinished(tool) -> shown.with(entries: tool_finished(shown.entries, tool))
    Protocol.Event.Error(failure) ->
      failed = noted(shown, "error: #{failure.kind}: #{failure.message}")
      case shown.new_model
        some(model) -> noted(failed.with(new_model: none), "warning: #{Client.model_warning(model)}")
        none -> failed
      end

    _ -> shown
  end
end

def tool_finished(entries: List[Transcript.Entry], tool: Protocol.ToolFinished) -> List[Transcript.Entry]
  timing = "#{tool.summary} (#{tool.duration_ms} ms)"
  return Transcript.tool(entries, tool.call_id, Transcript.Kind.Tool, "✓ #{timing}") if tool.ok

  Transcript.tool(entries, tool.call_id, Transcript.Kind.ToolFailed, "✗ #{timing}")
end

def finished(app: App, reason: Protocol.StopReason) -> App
  case reason
    Protocol.StopReason.EndTurn -> app
    Protocol.StopReason.Cancelled -> noted(app, "stopped")
    _ -> noted(app, "the turn ended: #{Protocol.stop_reason_name(reason)}")
  end
end

def resync(app: App) -> Result[App]
  return error("the server keeps asking to read the session again", kind: "tui.resync") if app.resyncs >= MAX_RESYNCS

  session = try Client.session(app.server, app.id)
  ok(attach(app.with(resyncs: app.resyncs + 1), session, app.resyncs >= 1))
end

def reconnect(app: App, reason: String) -> Result[App]
  reconnects = app.reconnects + 1
  return error("lost the event stream: #{reason}", kind: "tui.stream") if reconnects > MAX_RECONNECTS

  Task.sleep(RECONNECT_MS * reconnects)
  ok(subscribe(app.with(reconnects: reconnects), app.last_event_id))
end

# A draw that fails leaves the old screen; the client goes on, and the transcript says so once.
def drawn(app: App) -> App
  case draw(app)
    ok(_) -> app
    error(_) if app.draw_failed -> app
    error(e) -> noted(app.with(draw_failed: true), "error: the screen was not drawn: #{e.message}")
  end
end

# The rows of the panel over the prompt now: the session picker, else the approval asked.
def panel(app: App) -> List[Layout.Row]
  width = TUI.width(app.screen)
  room = TUI.height(app.screen) - Prompt.rows(app.prompt, width).size - 2
  case app.picker
    some(picker) -> Picker.rows(picker, width, room, Time.now_ms / 1000)
    none -> Approvals.rows(app.approvals, width, room)
  end
end

# Every write is clipped to the screen, which may be smaller than the panel and the prompt.
def draw(app: App) -> Result[Void]
  screen = app.screen
  width = TUI.width(screen)
  height = TUI.height(screen)
  try TUI.clear(screen)
  prompt = Prompt.rows(app.prompt, width)
  asked = panel(app)
  area = [height - prompt.size - asked.size - 1, 0].max.unwrap!
  lines = Transcript.lines(app.entries, width, app.thinking)
  top = [lines.size - area - [app.scroll, [lines.size - area, 0].max.unwrap!].min.unwrap!, 0].max.unwrap!
  y = 0
  for line in lines.drop(top).take(area)
    x = 0
    for span in line.spans
      written = try put(screen, x, y, span.text, style(line.kind, span.look))
      x = x + written
    end

    y = y + 1
  end

  y = area
  for row in asked
    _ = try put(screen, 0, y, row.text, row.style)
    y = y + 1
  end

  _ = try put(screen, 0, y, status(app, width), TUI.Style(attrs: [TUI.Attr.Reverse]))
  y = y + 1
  for row in prompt
    _ = try put(screen, 0, y, row, TUI.Style())
    y = y + 1
  end

  last = prompt[prompt.size - 1]
  if y - 1 < height and width > 0
    try TUI.set_cursor(screen, [Width.text(last), width - 1].min.unwrap!, y - 1)
  end

  TUI.present(screen)
end

def put(screen: TUI.Screen, x: Int, y: Int, text: String, style: TUI.Style) -> Result[Int]
  return ok(0) if y < 0 or y >= TUI.height(screen) or x >= TUI.width(screen)

  TUI.write(screen, x, y, text, style)
end

def status(app: App, width: Int) -> String
  state = "ready"
  if app.stopping
    state = "stopping"
  elsif app.turn
    state = "working"
  end

  if not app.approvals.pending.empty?
    state = "#{state} · approval waiting"
  end

  text = " #{state} · #{HINTS}"
  text + " " * [width - Width.text(text), 0].max.unwrap!
end

def style(kind: Transcript.Kind, look: Markdown.Look) -> TUI.Style
  case kind
    Transcript.Kind.User -> TUI.Style(fg: TUI.Color.Cyan, attrs: [TUI.Attr.Bold])
    Transcript.Kind.Notice -> TUI.Style(fg: TUI.Color.Yellow)
    Transcript.Kind.Tool -> TUI.Style(fg: TUI.Color.Blue)
    Transcript.Kind.ToolFailed -> TUI.Style(fg: TUI.Color.Red)
    Transcript.Kind.Thinking -> TUI.Style(attrs: [TUI.Attr.Dim])
    Transcript.Kind.Assistant ->
      case look
        Markdown.Look.Plain -> TUI.Style()
        Markdown.Look.Bold -> TUI.Style(attrs: [TUI.Attr.Bold])
        Markdown.Look.Heading -> TUI.Style(fg: TUI.Color.Magenta, attrs: [TUI.Attr.Bold, TUI.Attr.Underline])
        Markdown.Look.Code -> TUI.Style(fg: TUI.Color.Green)
      end
  end
end
