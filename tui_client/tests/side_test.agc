# The side panel on the model: what opens it, that the transcript stays the conversation, how it follows the
# server log,
# and where its keys and clicks go. The model stands alone, with a fake server log; no terminal.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import App from "../src/app"
import Args from "../src/args"
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

def ran(model: App.Model, line: String) -> App.Model
  App.update(model.with(prompt: line, cursor: line.length), key(TUI.Key.Enter)).model
end

def texts(model: App.Model) -> List[String] = model.entries.map { |entry| entry.text }

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
    try Test.eq(texts(logs), texts(start))
    try Test.eq(logs.side.unwrap!.lines, LOG)
    try Test.eq(logs.side.unwrap!.live, some(5))
    try Test.eq(logs.width, Side.left(width, true))
    helped = ran(start, "/help")
    try Test.eq(texts(helped), texts(start))
    try Test.eq(helped.side.unwrap!.title, "Help")
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

# PgUp and PgDn go to the focused side: the panel when it is open, the transcript when a click (or Ctrl+B) gave it
# the focus.
# The wheel goes to the side it is over.
def test_the_keys_and_the_wheel_go_to_the_side_that_has_them() -> Result[Void]
  long = (0...60).to_a.map { |n| "line #{n}" }
  opened = ran(model_of(120, 12, long), "/logs 60")
  paged = App.update(opened, key(TUI.Key.PageUp)).model
  try Test.eq(paged.side.unwrap!.follow, false)
  try Test.eq(paged.scroll, 0)
  focused = App.update(opened, ctrl("b")).model
  try Test.eq(focused.side.unwrap!.focused, false)
  try Test.eq(App.update(focused, key(TUI.Key.PageUp)).model.scroll > 0, true)
  try Test.eq(App.update(focused, ctrl("b")).model.side.unwrap!.focused, true)
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
