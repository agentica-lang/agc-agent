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

# A title from an older server keeps no control or bidi character in its row.
def test_a_title_shows_no_control_or_bidi_character() -> Result[Void]
  odd = "fix#{String.from_code(0x202E)}it#{String.from_code(27)}[2J"
  rows = Picker.rows(Picker.Picker(sessions: [summary("s1", odd)]), 200, 3, 1000).map { |row| row.text }
  Test.eq(rows.any? { |row| row.include?("fix it [2J") }, true)
end

def test_a_login_row_shows_no_control_or_bidi_character() -> Result[Void]
  login = Protocol.LoginStatus(
    name: "p",
    label: "Lo#{String.from_code(0x202E)}cal",
    key_env: "K",
    from: "",
    coming: true,
  )

  picker = Picker.logins(Protocol.LoginList(providers: [login], first: false))
  rows = Picker.rows(picker, 200, 3, 1000).map { |row| row.text }
  Test.eq(rows.any? { |row| row.include?("Lo cal: coming") }, true)
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

# The model picker lists every provider/model pair, starts on the one in use and gives the pair picked.
def test_the_model_picker_offers_each_provider_and_model() -> Result[Void]
  list = Protocol.ProviderList(
    provider: "local",
    providers: [
      Protocol.ProviderInfo(name: "fireworks", api: "openai", models: ["a", "b"]),
      Protocol.ProviderInfo(name: "local", api: "openai", models: ["q"]),
    ],
  )

  picker = Picker.models(list, "fireworks/b")
  try Test.eq(Picker.shown(picker).map { |c| c.key }, ["fireworks/a", "fireworks/b", "local/q"])
  try Test.eq(Picker.key(picker, key(TUI.Key.Enter)), Picker.Step.Pick("fireworks/b"))
  Test.eq(Picker.rows(picker, 80, 6, 0).map { |row| row.text }.first, "pick a model (3 of 3)")
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
