import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import Picker from "../src/picker"

def test_keys_move_filter_and_pick() -> Result[Void]
  picker = Picker.Picker(sessions: [summary("s3", "fix the tests"), summary("s2", "write docs"), summary("s1", "")])
  down = stay(Picker.key(stay(Picker.key(picker, key(TUI.Key.Down))), key(TUI.Key.Down)))
  try Test.eq(down.selected, 2)
  try Test.eq(stay(Picker.key(down, key(TUI.Key.Down))).selected, 2)
  try Test.eq(stay(Picker.key(picker, key(TUI.Key.Up))).selected, 0)
  try Test.eq(Picker.key(down, key(TUI.Key.Enter)), Picker.Step.Pick("s1"))
  try Test.eq(Picker.key(down, key(TUI.Key.Escape)), Picker.Step.Close)
  wheel = stay(Picker.key(picker, TUI.Event.Mouse(TUI.Mouse.WheelDown, 0, 0, TUI.Mods())))
  try Test.eq(wheel.selected, 1)
  filtered = stay(Picker.key(stay(Picker.key(down, char("D"))), char("o")))
  try Test.eq([filtered.filter, filtered.selected.to_s], ["Do", "0"])
  try Test.eq(Picker.shown(filtered).map { |c| c.key }, ["s2"])
  try Test.eq(Picker.key(filtered, key(TUI.Key.Enter)), Picker.Step.Pick("s2"))
  back = stay(Picker.key(filtered, key(TUI.Key.Backspace)))
  try Test.eq(back.filter, "D")
  try Test.eq(stay(Picker.key(back, TUI.Event.Paste("o\tw\nri"))).filter, "Do w ri")
  none_left = stay(Picker.key(filtered, char("x")))
  Test.eq(Picker.key(none_left, key(TUI.Key.Enter)), Picker.Step.Stay(none_left))
end

def test_rows_keep_the_selected_session_in_sight() -> Result[Void]
  sessions = (1..20).map { |n| summary("s#{n}", "task #{n}") }
  picker = Picker.Picker(sessions: sessions, selected: 14)
  rows = Picker.rows(picker, 200, 6, 1000 + 7200).map { |row| row.text }
  try Test.eq(rows.size, 6)
  try Test.eq(rows[0], "resume a session (20 of 20)")
  try Test.eq(rows[4], "› s15  /w/s15  m  2h  task 15")
  try Test.eq(rows[5], Picker.KEYS.join(" · "))
  Test.eq(
    ["now", "5m", "3h", "2d"],
    [Picker.ago(100, 90), Picker.ago(400, 100), Picker.ago(11000, 0), Picker.ago(200000, 0)],
  )
end

private

def summary(id: String, title: String) -> Protocol.SessionSummary
  Protocol.SessionSummary(id: id, cwd: "/w/#{id}", model: "m", api: "openai", updated_s: 1000, title: title)
end

def stay(step: Picker.Step) -> Picker.Picker
  case step
    Picker.Step.Stay(picker) -> picker
    _ -> Picker.Picker(sessions: [], filter: "not stayed")
  end
end

def key(k: TUI.Key) -> TUI.Event = TUI.Event.Key(k, TUI.Mods())

def char(c: String) -> TUI.Event = TUI.Event.Char(c, TUI.Mods())
