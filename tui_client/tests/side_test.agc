# The side panel on the model: what opens it, that the transcript stays the conversation, how it follows the
# server log,
# and where its keys and clicks go. The model stands alone, with a fake server log; no terminal.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import App from "../src/app"
import Args from "../src/args"
import Session from "../src/session"
import Side from "../src/side"
import Transcript from "../src/transcript"

LOG = ["10:00:00 INFO started", "10:00:01 WARNING bad skill"]

def model_of(width: Int, height: Int, log: List[String] = []) -> App.Model
  options = Args.Options(
    state_dir: none,
    server_command: none,
    session: none,
    cwd: none,
    model: none,
    api: none,
    thinking: false,
  )

  lines = log
  if log.empty?
    lines = LOG
  end

  log_of = ->(_count: Int) { ok(Protocol.ServerLog(lines: lines, warnings: [], warning_count: 0)) }
  backend = Client.unreachable_backend().with(server_log: log_of)
  said = [
    Protocol.Message(role: Protocol.Role.User, text: "question"),
    Protocol.Message(role: Protocol.Role.Assistant, text: "hello there"),
  ]

  App.seed(backend, options, Channel.new(1), width, height).with(id: "s1", entries: Transcript.from_history(said))
end

def key(event: TUI.Key) -> App.Msg = App.Msg.Key(TUI.Event.Key(event, TUI.Mods()))

def ctrl(letter: String) -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.Ctrl(letter), TUI.Mods()))

def mouse(button: TUI.Mouse, x: Int) -> App.Msg = App.Msg.Key(TUI.Event.Mouse(button, x, 3, TUI.Mods()))

def mouse_at(button: TUI.Mouse, x: Int, y: Int, motion: Bool = false) -> App.Msg
  App.Msg.Key(TUI.Event.Mouse(button, x, y, TUI.Mods(motion: motion)))
end

def ran(model: App.Model, line: String) -> App.Model
  App.update(model.with(prompt: line, cursor: line.length), key(TUI.Key.Enter)).model
end

def texts(model: App.Model) -> List[String] = model.entries.map { |entry| entry.text }

# How many messages are on their way to the server, and how many commands the line started.
def local(model: App.Model, line: String) -> List[Int]
  step = App.update(model.with(prompt: line, cursor: line.length), key(TUI.Key.Enter))
  [step.model.outbox.size, step.cmds.size]
end

def screen(model: App.Model) -> List[String]
  cells = TUI.layout(App.view(model), model.screen_width, model.height)
  (0...model.height).to_a.map do |y| cells.select { |cell| cell.y == y }.map { |cell| cell.char }.join("") end
end

# Which columns the panel has, and the app: the panel beside the transcript from 100 columns (40% of the screen, 40
# to 80
# columns, with a column between), the whole screen for the app below.
def test_the_columns_of_the_panel_and_the_app() -> Result[Void]
  Test.eq(
    [99, 100, 150, 200, 300].map { |width| [Side.columns(width), Side.left(width, true), Side.left(width, false)] },
    [[99, 99, 99], [40, 59, 100], [60, 89, 150], [80, 119, 200], [80, 219, 300]],
  )
end

# `/logs`, `/help` and `/reload` open the panel and add nothing to the transcript, at a wide and at a narrow width.
def test_local_output_goes_to_the_panel_and_not_to_the_transcript() -> Result[Void]
  reloaded = Protocol.Reloaded(config: "unchanged", warnings: ["w"])
  for width in [120, 80]
    start = model_of(width, 20).with(backend: model_of(width, 20).backend.with(reload: -> { ok(reloaded) }))

    logs = ran(start, "/logs 5")
    try Test.eq(local(start, "/logs 5"), [0, 0])
    try Test.eq(texts(logs), texts(start))
    try Test.eq(logs.side.unwrap!.lines, LOG)
    try Test.eq(logs.side.unwrap!.live, some(5))
    try Test.eq(logs.width, Side.left(width, true))
    helped = ran(start, "/help")
    try Test.eq(texts(helped), texts(start))
    try Test.eq(helped.side.unwrap!.title, "Help")
    try Test.eq(local(start, "/help"), [0, 0])
    try Test.eq(local(start, "/reload"), [0, 0])
    reported = ran(start, "/reload")
    try Test.eq(texts(reported), texts(start))
    try Test.eq(reported.side.unwrap!.title, "Reload")
    try Test.assert(reported.side.unwrap!.lines.any? { |line| line.include?("warning: w") }, "#{reported.side}")
    try Test.assert(screen(logs).any? { |row| row.include?("WARNING bad skill") }, screen(logs).join("\n"))
  end

  ok()
end

# A wide screen has the transcript and the panel side by side; a narrow one has the panel in the transcript's place,
# and Esc gives it back.
def test_the_panel_sits_beside_the_transcript_or_over_it() -> Result[Void]
  wide = ran(model_of(120, 20), "/logs")
  row = screen(wide).find { |text| text.include?("hello there") }.unwrap!
  try Test.assert(row.index_of("hello there").unwrap! < 71 and row.include?("│"), row)
  try Test.assert(row.index_of("hello there").unwrap! < row.index_of("│").unwrap!, row)
  narrow = ran(model_of(80, 20), "/logs")
  try Test.assert(not screen(narrow).any? { |text| text.include?("hello there") }, "the transcript is covered")
  try Test.eq(narrow.width, 80)
  back = App.update(narrow, key(TUI.Key.Escape)).model
  try Test.eq(back.side.none?, true)
  try Test.assert(screen(back).any? { |text| text.include?("hello there") }, "Esc gives the transcript back")
  closed = App.update(wide, key(TUI.Key.Escape)).model
  try Test.eq(closed.side.none?, true)
  try Test.eq(closed.width, 120)
  try Test.eq(App.update(closed, ctrl("p")).model.side.some?, true)
  Test.eq(App.update(App.update(closed, ctrl("p")).model, ctrl("p")).model.side.none?, true)
end

# The open log follows the server: each tick reads it again, one read at a time, and its lines replace the panel's. A
# panel scrolled away from the end keeps what it shows until it is scrolled back to the end.
def test_the_log_follows_the_server_until_it_is_scrolled_away() -> Result[Void]
  long = (0...60).to_a.map { |n| "line #{n}" }
  start = ran(model_of(120, 12, long), "/logs 60")
  ticked = App.update(start, App.Msg.LogTick)
  try Test.eq(ticked.cmds.size, 1)
  try Test.eq(ticked.model.reading_side, true)
  try Test.eq(App.update(ticked.model, App.Msg.LogTick).cmds.size, 0)
  more = Protocol.ServerLog(lines: long + ["line 60"], warnings: [], warning_count: 0)
  serial = start.side_serial
  read = App.update(ticked.model, App.Msg.LogRead(serial, ok(more))).model
  try Test.eq(read.reading_side, false)
  try Test.eq(read.side.unwrap!.lines.last, "line 60")
  try Test.eq(App.update(read, App.Msg.LogRead(serial + 1, ok(more))).model.side.unwrap!.lines.size, 61)
  away = App.update(read, key(TUI.Key.PageUp)).model
  try Test.eq(away.side.unwrap!.follow, false)
  try Test.eq(App.update(away, App.Msg.LogTick).cmds.size, 0)
  kept = App.update(away, App.Msg.LogRead(serial, ok(more.with(lines: long)))).model
  try Test.eq(kept.side.unwrap!.lines.size, 61)
  end_again = away
  for _ in 0...10
    end_again = App.update(end_again, key(TUI.Key.PageDown)).model
  end

  Test.eq(end_again.side.unwrap!.follow, true)
end

# PgUp and PgDn go to the focused side: the panel when it is open, the transcript when a click (or F6) gave it
# the focus.
# The wheel goes to the side it is over.
def test_the_keys_and_the_wheel_go_to_the_side_that_has_them() -> Result[Void]
  long = (0...60).to_a.map { |n| "line #{n}" }
  opened = ran(model_of(120, 12, long), "/logs 60")
  paged = App.update(opened, key(TUI.Key.PageUp)).model
  try Test.eq(paged.side.unwrap!.follow, false)
  try Test.eq(paged.scroll, 0)
  focused = App.update(opened, key(TUI.Key.F(6))).model
  try Test.eq(focused.side.unwrap!.focused, false)
  try Test.eq(App.update(focused, key(TUI.Key.PageUp)).model.scroll > 0, true)
  try Test.eq(App.update(focused, key(TUI.Key.F(6))).model.side.unwrap!.focused, true)
  clicked = App.update(opened, mouse(TUI.Mouse.Left, 5)).model
  try Test.eq(clicked.side.unwrap!.focused, false)
  try Test.eq(App.update(clicked, mouse(TUI.Mouse.Left, 100)).model.side.unwrap!.focused, true)
  wheel = App.update(focused, mouse(TUI.Mouse.WheelUp, 100)).model
  try Test.eq(wheel.side.unwrap!.follow, false)
  try Test.eq(wheel.scroll, 0)
  Test.eq(App.update(focused, mouse(TUI.Mouse.WheelUp, 5)).model.scroll > 0, true)
end

# A resize across 100 columns moves the panel from beside the transcript to over it, and back.
def test_a_resize_moves_the_panel_between_beside_and_over() -> Result[Void]
  opened = ran(model_of(120, 20), "/logs")
  narrow = App.update(opened, App.Msg.Key(TUI.Event.Resize(80, 20))).model
  try Test.eq([narrow.width, narrow.screen_width], [80, 80])
  try Test.eq(narrow.side.some?, true)
  wide = App.update(narrow, App.Msg.Key(TUI.Event.Resize(140, 20))).model
  Test.eq([wide.width, wide.screen_width], [Side.left(140, true), 140])
end

# `/profile` alone lists the profiles in the panel; the transcript is the same.
def test_the_profile_list_goes_to_the_panel() -> Result[Void]
  session = Protocol.Session(
    id: "s1",
    cwd: ".",
    model: "m",
    last_event_id: 0,
    turn_id: none,
    turn_from_event_id: none,
    pending_approvals: [],
    history: [],
    provider: "local",
  )

  profiles = Protocol.ProfileList(profiles: [Protocol.Profile(name: "plan", source: "built-in")])
  start = model_of(120, 20)
  backend = start.backend.with(
    session: ->(_id: String) { ok(session) },
    list_profiles: ->(_id: String) { ok(profiles) },
  )

  listed = ran(start.with(backend: backend), "/profile")
  try Test.eq(texts(listed), texts(start))
  try Test.eq(listed.side.unwrap!.title, "Profiles")
  Test.assert(listed.side.unwrap!.lines.any? { |line| line.include?("plan") }, "#{listed.side}")
end

# A new session closes the panel and gives the app the whole screen back.
def test_a_new_session_closes_the_panel() -> Result[Void]
  opened = ran(model_of(120, 20), "/logs")
  try Test.eq(opened.width < 120, true)
  fresh = Session.fresh(opened)
  try Test.eq(fresh.side.none?, true)
  Test.eq(fresh.width, 120)
end

# A drag that begins in the transcript and ends over the panel selects up to the transcript's last column and
# copies, and
# the button is not left pressed.
def test_a_drag_from_the_transcript_over_the_panel_copies() -> Result[Void]
  written: Channel[String] = Channel.new(4)
  opened = ran(model_of(120, 12), "/logs").with(write: ->(sent: String) { _ = written.send(sent, 0) })
  rows = screen(opened)
  y = (0...rows.size).find { |at| rows[at].include?("hello there") }.unwrap!
  x = rows[y].index_of("hello there").unwrap!
  down = App.update(opened, mouse_at(TUI.Mouse.Left, x, y)).model
  try Test.eq(down.pressed.some?, true)
  dragged = App.update(down, mouse_at(TUI.Mouse.Left, 100, y, motion: true)).model
  try Test.eq(dragged.selection.some?, true)
  up = App.update(dragged, mouse_at(TUI.Mouse.Release, 100, y)).model
  try Test.eq(up.pressed.none?, true)
  try Test.assert(up.entries.last.text.include?("sent 11 characters to the terminal (OSC 52)"), up.entries.last.text)
  try Test.eq(written.recv(0).ok?, true)
  # A press over the panel selects nothing.
  Test.eq(App.update(opened, mouse_at(TUI.Mouse.Left, 100, y)).model.pressed.none?, true)
end

# `/help` ends with the keys, and the footer with the panel closed names Ctrl+P.
def test_help_lists_the_keys_and_the_closed_footer_names_the_panel() -> Result[Void]
  start = model_of(120, 20)
  try Test.assert(ran(start, "/help").side.unwrap!.lines.any? { |line| line.include?("F6") }, "keys in /help")
  try Test.assert(screen(start).last.include?("^P logs"), screen(start).last)
  logs = ran(start, "/logs")
  try Test.assert(screen(logs).any? { |row| row.include?("F6 focus") }, "the title names F6")
  Test.assert(not screen(logs).last.include?("^P logs"), "the open footer says close")
end

# Esc closes the panel first, whatever the focus, and stops the turn the second time.
def test_esc_closes_the_panel_before_it_stops_the_turn() -> Result[Void]
  opened = ran(model_of(120, 20), "/logs").with(turn: true)
  first = App.update(opened, key(TUI.Key.Escape))
  try Test.eq([first.model.side.none?, first.model.stopping], [true, false])
  try Test.eq(first.cmds.size, 0)
  second = App.update(first.model, key(TUI.Key.Escape))
  try Test.eq(second.model.stopping, true)
  # With the focus on the transcript, the first Esc closes the panel too and the second stops the turn.
  away = App.update(opened, key(TUI.Key.F(6))).model
  closed = App.update(away, key(TUI.Key.Escape)).model
  try Test.eq([closed.stopping, closed.side.none?], [false, true])
  Test.eq(App.update(closed, key(TUI.Key.Escape)).model.stopping, true)
end

# A read that brings the same lines changes nothing, one that fails says so in the panel until a read works, and the
# status line says what the panel's keys do while it is open.
def test_the_follow_keeps_the_same_lines_and_shows_a_failed_read() -> Result[Void]
  opened = ran(model_of(120, 20), "/logs")
  serial = opened.side_serial
  same = App.update(
    opened,
    App.Msg.LogRead(serial, ok(Protocol.ServerLog(lines: LOG, warnings: [], warning_count: 0))),
  )

  try Test.eq(same.model.side, opened.side)
  failed = App.update(opened, App.Msg.LogRead(serial, error("no server"))).model
  try Test.assert(failed.side.unwrap!.wrapped.any? { |row| row.include?("log not read: no server") }, "#{failed.side}")
  healed = App.update(
    failed,
    App.Msg.LogRead(serial, ok(Protocol.ServerLog(lines: LOG, warnings: [], warning_count: 0))),
  )

  try Test.eq(healed.model.side.unwrap!.note, "")
  try Test.assert(screen(opened).any? { |row| row.include?("Esc close panel") }, screen(opened).join("\n"))
  away = App.update(opened, key(TUI.Key.F(6))).model
  Test.assert(screen(away).any? { |row| row.include?("F6 panel") }, screen(away).join("\n"))
end
