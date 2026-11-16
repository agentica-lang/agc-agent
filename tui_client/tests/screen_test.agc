import TUI from "pkg/tui/tui"
import Layout from "../src/panel"
import Prompt from "../src/prompt"
import Screen from "../src/screen"
import Theme from "../src/theme"
import Transcript from "../src/transcript"

# The regions stack from the top: the end of the transcript, the panel, the status line and the prompt with its
# cursor; a click lands on what the same frame drew.
def test_the_frame_draws_and_hits_the_same_regions() -> Result[Void]
  entries = Transcript.note(Transcript.note(Transcript.note([], "one"), "two"), "three")
  tab = TUI.Event.Key(TUI.Key.Tab, TUI.Mods())
  button = Layout.Button(from: 0, to: 3, event: tab)
  panel = ->(_room: Int) { [Layout.Row(text: "Tab", buttons: [button])] }
  frame = Screen.frame(20, 6, Transcript.lines(entries, 20, false), 0, panel, " ready", Prompt.view("hi", 1, 20, 6))
  try Test.eq(rows(frame), ["· two", "", "· three", "Tab", "ready", "> hi"])
  try Test.eq([Screen.hit(frame, 0, 1), Screen.hit(frame, 0, 2)], [Screen.Hit.Entry(-1), Screen.Hit.Entry(2)])
  try Test.eq(Screen.hit(frame, 1, 3), Screen.Hit.Key(tab))
  try Test.eq(Screen.hit(frame, 1, 4), Screen.Hit.Nothing)
  try Test.eq(Screen.hit(frame, 3, 5), Screen.Hit.Prompt(3, 0))
  cursor = TUI.layout(Screen.view(frame, Theme.default()), 20, 6).find { |cell| cell.y == 5 and cell.x == 3 }
  Test.eq((try cursor).style, TUI.Style(reverse: true))
end

# Each region draws with its own colors of the theme.
def test_the_theme_colors_each_region() -> Result[Void]
  base = Theme.default()
  theme = base.with(
    footer: base.footer.with(status: TUI.Style(bold: true)),
    transcript: base.transcript.with(notice: TUI.Style(fg: TUI.Color.Red)),
  )

  frame = Screen.frame(
    10,
    3,
    Transcript.lines(Transcript.note([], "hi"), 10, false),
    0,
    ->(_room: Int) { [] },
    "ok",
    Prompt.view("", 0, 10, 3),
  )

  cells = TUI.layout(Screen.view(frame, theme), 10, 3)
  try Test.eq((try cells.find { |cell| cell.y == 0 and cell.x == 2 }).style, TUI.Style(fg: TUI.Color.Red))
  Test.eq((try cells.find { |cell| cell.y == 1 and cell.x == 0 }).style, TUI.Style(bold: true))
end

def rows(frame: Screen.Frame) -> List[String]
  cells = TUI.layout(Screen.view(frame, Theme.default()), frame.width, frame.height)
  (0...frame.height).to_a.map do |y| cells.select { |cell| cell.y == y }.map { |cell| cell.char }.join("").strip end
end
