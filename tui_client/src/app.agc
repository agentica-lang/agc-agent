## One session on the full screen: the loop that reads the keys and the events of the server, keeps the state in one
## immutable `App` and draws it after each batch of inputs.

import TUI from "pkg/tui/tui"
import Protocol from "pkg/protocol/protocol"
import Args from "args"
import Client from "client"
import Feed from "feed"
import Inbox from "inbox"
import Prompt from "prompt"
import Transcript from "transcript"

INBOX_CAPACITY = 1024
WAIT_MS = 3_600_000
SEND_MS = 30_000
RECONNECT_MS = 300
MAX_RECONNECTS = 3
SCROLL_STEP = 3
HINTS = "Enter send · Ctrl+J newline · Esc stop · PgUp/PgDn scroll · Ctrl+C quit"

## Runs the session of `options` on `screen` until the user leaves.
def run(screen: TUI.Screen, server: Client.Server, options: Args.Options) -> Result[Void]
  try TUI.set_input_mode(screen, TUI.InputMode.Esc, true)
  inbox: Channel[Inbox.Input] = Channel.new(INBOX_CAPACITY)
  _ = Task.spawn(-> { read_keys(screen, inbox) })
  app = try open(App(screen: screen, server: server, id: "", inbox: inbox), options)
  loop(app)
end

private

struct App
  screen: TUI.Screen
  server: Client.Server
  id: String
  inbox: Channel[Inbox.Input]
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
  quit: Bool = false
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
    some(id) -> attach(app.with(id: id), try Client.session(app.server, id))
    none ->
      cwd = case options.cwd
        some(dir) -> dir
        none -> try Path.cwd()
      end

      request = Protocol.NewSession(cwd: cwd, model: options.model, api: options.api)
      ok(subscribe(app.with(id: try Client.create_session(app.server, request)), 0))
  end
end

# Draws the history of the session and reads the events after it; while a turn runs, from the start of the turn.
def attach(app: App, session: Protocol.Session) -> Result[App]
  from = session.turn_from_event_id.unwrap_or(session.last_event_id)
  fresh = app.with(
    entries: Transcript.from_history(session.history),
    turn: session.turn_id.some?,
    stopping: false,
    shown_id: from,
  )

  ok(subscribe(fresh, from))
end

def subscribe(app: App, from: Int) -> App
  if app.stream.some?
    Task.cancel(app.stream.unwrap!)
  end

  generation = app.generation + 1
  feed = Feed.Feed(
    server: app.server,
    session_id: app.id,
    last_event_id: from,
    generation: generation,
    inbox: app.inbox,
  )

  app.with(stream: some(Feed.start(feed)), generation: generation, last_event_id: from)
end

def loop(start: App) -> Result[Void]
  app = start
  try draw(app)
  while not app.quit
    case app.inbox.recv(WAIT_MS)
      ok(input) ->
        app = try handle(app, input)
        while not app.quit
          case app.inbox.recv(0)
            ok(more) -> app = try handle(app, more)
            error(_) -> break
          end
        end

        try draw(app)

      error(_) -> next
    end
  end

  ok()
end

def handle(app: App, input: Inbox.Input) -> Result[App]
  case input
    Inbox.Input.Terminal(event) -> ok(on_key(app, event))
    Inbox.Input.Closed(reason) -> error("the terminal closed: #{reason}", kind: "tui.terminal")
    Inbox.Input.Stream(generation, item) if generation == app.generation -> on_stream(app, item)
    Inbox.Input.Stream(_, _) -> ok(app)
  end
end

def on_key(app: App, event: TUI.Event) -> App
  case event
    TUI.Event.Key(TUI.Key.Ctrl("c"), _) -> app.with(quit: true)
    TUI.Event.Key(TUI.Key.Enter, _) -> send(app)
    TUI.Event.Key(TUI.Key.Ctrl("j"), _) -> app.with(prompt: Prompt.insert(app.prompt, "\n"))
    TUI.Event.Key(TUI.Key.Backspace, _) -> app.with(prompt: Prompt.backspace(app.prompt))
    TUI.Event.Key(TUI.Key.Escape, _) -> stop(app)
    TUI.Event.Key(TUI.Key.PageUp, _) -> scrolled(app, page(app))
    TUI.Event.Key(TUI.Key.PageDown, _) -> scrolled(app, -page(app))
    TUI.Event.Mouse(TUI.Mouse.WheelUp, _, _, _) -> scrolled(app, SCROLL_STEP)
    TUI.Event.Mouse(TUI.Mouse.WheelDown, _, _, _) -> scrolled(app, -SCROLL_STEP)
    TUI.Event.Char(char, _) -> app.with(prompt: Prompt.insert(app.prompt, char))
    _ -> app
  end
end

def page(app: App) -> Int = [TUI.height(app.screen) / 2, 1].max.unwrap!

def scrolled(app: App, rows: Int) -> App = app.with(scroll: [app.scroll + rows, 0].max.unwrap!)

def send(app: App) -> App
  text = app.prompt.strip
  return app if text == ""
  return noted(app, "a turn is running: Esc stops it") if app.turn

  case Client.send_message(app.server, app.id, text)
    ok(_) ->
      entries = Transcript.add(app.entries, Transcript.Kind.User, text)
      app.with(entries: entries, prompt: "", turn: true, stopping: false, scroll: 0)
    error(e) if e.kind == Protocol.KIND_SESSION_BUSY -> noted(app.with(turn: true), "a turn is already running")
    error(e) -> noted(app, "error: #{e.message}")
  end
end

def stop(app: App) -> App
  return app if not app.turn or app.stopping

  case Client.stop(app.server, app.id)
    ok(_) -> noted(app.with(stopping: true), "stopping the turn")
    error(e) -> noted(app, "error: the stop was not sent: #{e.message}")
  end
end

def noted(app: App, text: String) -> App = app.with(entries: Transcript.note(app.entries, text))

def on_stream(app: App, item: Inbox.Item) -> Result[App]
  case item
    Inbox.Item.Opened -> ok(app.with(reconnects: 0))
    Inbox.Item.Event(_, Protocol.Event.Resync) -> attach(app, try Client.session(app.server, app.id))
    Inbox.Item.Event(id, event) -> ok(on_event(app, id, event))
    Inbox.Item.Ended(reason) -> reconnect(app, reason)
  end
end

def on_event(app: App, id: Optional[Int], event: Protocol.Event) -> App
  seen = id.unwrap_or(app.last_event_id)
  return app.with(last_event_id: seen) if id.some? and seen <= app.shown_id

  shown = app.with(last_event_id: seen, shown_id: seen)
  case event
    Protocol.Event.TextDelta(delta) ->
      shown.with(entries: Transcript.add(shown.entries, Transcript.Kind.Assistant, delta.text))
    Protocol.Event.TurnStarted(_) -> shown.with(turn: true)
    Protocol.Event.TurnFinished(done) -> finished(shown.with(turn: false, stopping: false), done.stop_reason)
    Protocol.Event.Error(failure) -> noted(shown, "error: #{failure.kind}: #{failure.message}")
    _ -> shown
  end
end

def finished(app: App, reason: Protocol.StopReason) -> App
  case reason
    Protocol.StopReason.EndTurn -> app
    Protocol.StopReason.Cancelled -> noted(app, "stopped")
    _ -> noted(app, "the turn ended: #{Protocol.stop_reason_name(reason)}")
  end
end

def reconnect(app: App, reason: String) -> Result[App]
  reconnects = app.reconnects + 1
  return error("lost the event stream: #{reason}", kind: "tui.stream") if reconnects > MAX_RECONNECTS

  Task.sleep(RECONNECT_MS * reconnects)
  ok(subscribe(app.with(reconnects: reconnects), app.last_event_id))
end

def draw(app: App) -> Result[Void]
  screen = app.screen
  width = TUI.width(screen)
  height = TUI.height(screen)
  try TUI.clear(screen)
  prompt = Prompt.rows(app.prompt, width)
  area = [height - prompt.size - 1, 0].max.unwrap!
  lines = Transcript.lines(app.entries, width)
  top = [lines.size - area - [app.scroll, [lines.size - area, 0].max.unwrap!].min.unwrap!, 0].max.unwrap!
  y = 0
  for line in lines.drop(top).take(area)
    _ = try TUI.write(screen, 0, y, line.text, style(line.kind))
    y = y + 1
  end

  _ = try TUI.write(screen, 0, area, status(app, width), TUI.Style(attrs: [TUI.Attr.Reverse]))
  y = area + 1
  for row in prompt
    _ = try TUI.write(screen, 0, y, row)
    y = y + 1
  end

  last = prompt[prompt.size - 1]
  try TUI.set_cursor(screen, [last.length, width - 1].min.unwrap!, area + prompt.size)
  TUI.present(screen)
end

def status(app: App, width: Int) -> String
  state = "ready"
  if app.stopping
    state = "stopping"
  elsif app.turn
    state = "working"
  end

  text = " #{state} · #{HINTS}"
  text + " " * [width - text.length, 0].max.unwrap!
end

def style(kind: Transcript.Kind) -> TUI.Style
  case kind
    Transcript.Kind.User -> TUI.Style(fg: TUI.Color.Cyan, attrs: [TUI.Attr.Bold])
    Transcript.Kind.Notice -> TUI.Style(fg: TUI.Color.Yellow)
    Transcript.Kind.Thinking -> TUI.Style(attrs: [TUI.Attr.Dim])
    Transcript.Kind.Assistant -> TUI.Style()
  end
end
