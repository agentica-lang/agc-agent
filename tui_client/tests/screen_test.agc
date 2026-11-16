import TUI from "pkg/tui/tui"
import Layout from "../src/panel"
import Prompt from "../src/prompt"
import Screen from "../src/screen"
import Theme from "../src/theme"
import Transcript from "../src/transcript"

# The regions stack from the top: the end of the transcript, the prompt between two rules (the top one with the
# label, both in the color of the level), the panel and the status line; a click lands on what the same frame drew.
def test_the_frame_draws_and_hits_the_same_regions() -> Result[Void]
  entries = Transcript.note(Transcript.note(Transcript.note([], "one"), "two"), "three")
  tab = TUI.Event.Key(TUI.Key.Tab, TUI.Mods())
  button = Layout.Button(from: 0, to: 3, event: tab)
  parts = parts_of(Prompt.view("hi", 1, 20, 8)).with(
    panel: ->(_room: Int) { [Layout.Row(text: "Tab", buttons: [button])] },
    label: "⠋ Working",
    level: some("high"),
  )

  frame = Screen.frame(20, 8, Transcript.lines(entries, 20, false), 0, parts)
  try Test.eq(rows(frame), ["two", "", "three", "── ⠋ Working ───────", "hi", "─" * 20, "Tab", "ready"])
  hits = (0...8).to_a.map { |y| Screen.hit(frame, 1, y) }
  try Test.eq(
    hits,
    [
      Screen.Hit.Entry(1),
      Screen.Hit.Entry(-1),
      Screen.Hit.Entry(2),
      Screen.Hit.Nothing,
      Screen.Hit.Prompt(1, 0),
      Screen.Hit.Nothing,
      Screen.Hit.Key(tab),
      Screen.Hit.Nothing,
    ],
  )

  cells = TUI.layout(Screen.view(frame, Theme.default()), 20, 8)
  try Test.eq((try cells.find { |cell| cell.y == 4 and cell.x == 2 }).style, TUI.Style(reverse: true))
  Test.eq((try cells.find { |cell| cell.y == 5 and cell.x == 0 }).style, Theme.default().rules.high)
end

# A picker takes the prompt's place between the rules.
def test_a_picker_replaces_the_prompt() -> Result[Void]
  picker = ->(_room: Int) { [Layout.Row(text: "› s1"), Layout.Row(text: "  s2")] }
  frame = Screen.frame(10, 6, [], 0, parts_of(Prompt.view("typed", 5, 10, 6)).with(picker: picker))
  try Test.eq(rows(frame), ["", "─" * 10, "› s1", "s2", "─" * 10, "ready"])
  Test.eq(Screen.hit(frame, 1, 2), Screen.Hit.Nothing)
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
    6,
    Transcript.lines(Transcript.note([], "hi"), 10, false),
    0,
    parts_of(Prompt.view("", 0, 10, 6)),
  )

  cells = TUI.layout(Screen.view(frame, theme), 10, 6)
  try Test.eq((try cells.find { |cell| cell.y == 0 and cell.x == 1 }).style, TUI.Style(fg: TUI.Color.Red))
  Test.eq((try cells.find { |cell| cell.y == 5 and cell.x == 0 }).style, TUI.Style(bold: true))
end

def parts_of(prompt: Prompt.View) -> Screen.Parts
  Screen.Parts(prompt: prompt, picker: &nothing, panel: &nothing, label: "", level: none, status: "ready")
end

def nothing(_room: Int) -> List[Layout.Row] = []

def rows(frame: Screen.Frame) -> List[String]
  cells = TUI.layout(Screen.view(frame, Theme.default()), frame.width, frame.height)
  (0...frame.height).to_a.map do |y| cells.select { |cell| cell.y == y }.map { |cell| cell.char }.join("").strip end
end
