import TUI from "pkg/tui/tui"
import Components from "../src/components"
import Layout from "../src/panel"
import Prompt from "../src/prompt"
import Screen from "../src/screen"
import Theme from "../src/theme"
import Transcript from "../src/transcript"

# The regions stack from the top: the end of the transcript, the prompt between two rules (the top one with the
# label, both in the color of the level), the panel, the place and the status line; a click lands on what the same
# frame drew.
def test_the_frame_draws_and_hits_the_same_regions() -> Result[Void]
  entries = Transcript.note(Transcript.note(Transcript.note([], "one"), "two"), "three")
  tab = TUI.Event.Key(TUI.Key.Tab, TUI.Mods())
  button = Layout.Button(from: 0, to: 3, event: tab)
  parts = parts_of(Prompt.view("hi", 1, 20, 8)).with(
    panel: ->(_room: Int) { [Layout.Row(text: "Tab", buttons: [button])] },
    label: "⠋ Working",
    level: some("high"),
    place: "~/x (main)",
  )

  frame = Screen.frame(20, 9, Transcript.lines(entries, 20, Transcript.Folds()), 0, parts)
  try Test.eq(rows(frame), ["two", "", "three", "── ⠋ Working ───────", "hi", "─" * 20, "Tab", "~/x (main)", "ready"])
  hits = (0...9).to_a.map { |y| Screen.hit(frame, 1, y) }
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
      Screen.Hit.Nothing,
    ],
  )

  cells = TUI.layout(Screen.view(frame, Theme.default()), 20, 9)
  try Test.eq((try cells.find { |cell| cell.y == 4 and cell.x == 2 }).style, TUI.Style(reverse: true))
  Test.eq((try cells.find { |cell| cell.y == 5 and cell.x == 0 }).style, Theme.default().rules.high)
end

# A picker takes the prompt's place between the rules; on a screen too short for both, the place row goes first.
def test_a_picker_replaces_the_prompt() -> Result[Void]
  picker = ->(_room: Int) { [Layout.Row(text: "› s1"), Layout.Row(text: "  s2")] }
  frame = Screen.frame(10, 7, [], 0, parts_of(Prompt.view("typed", 5, 10, 7)).with(picker: picker))
  try Test.eq(rows(frame), ["", "─" * 10, "› s1", "s2", "─" * 10, "", "ready"])
  short = Screen.frame(10, 5, [], 0, parts_of(Prompt.view("typed", 5, 10, 5)).with(picker: picker, place: "~/x"))
  try Test.eq(rows(short), ["─" * 10, "› s1", "s2", "─" * 10, "ready"])
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
    Transcript.lines(Transcript.note([], "hi"), 10, Transcript.Folds()),
    0,
    parts_of(Prompt.view("", 0, 10, 6)),
  )

  cells = TUI.layout(Screen.view(frame, theme), 10, 6)
  try Test.eq((try cells.find { |cell| cell.y == 0 and cell.x == 1 }).style, TUI.Style(fg: TUI.Color.Red))
  Test.eq((try cells.find { |cell| cell.y == 5 and cell.x == 0 }).style, TUI.Style(bold: true))
end

# The 256-color theme only where the terminal says it shows them.
def test_the_palette_follows_the_terminal() -> Result[Void]
  checks = [["xterm-256color", ""], ["xterm", ""], ["xterm", "truecolor"]].map { |env|
    Theme.colors256?(env[0], env[1])
  }

  Test.eq(checks, [true, false, true])
end

# A full prompt row keeps its last column for the cursor, even after a wide character.
def test_the_cursor_after_a_full_row_ending_in_a_wide_character() -> Result[Void]
  prompt = Prompt.view("ab中", 3, 6, 4)
  try Test.eq([prompt.rows, [prompt.cursor_x.to_s]], [[" ab中"], ["5"]])
  frame = Screen.frame(6, 4, [], 0, parts_of(prompt))
  cells = TUI.layout(Screen.view(frame, Theme.default()), 6, 4)
  try Test.eq((try cells.find { |cell| cell.y == 1 and cell.x == 3 }).char, "中")
  Test.eq((try cells.find { |cell| cell.y == 1 and cell.x == 5 }).style, TUI.Style(reverse: true))
end

# The banner draws through `Components.notice`: the same text in the banner style.
def test_the_banner_draws_through_notice() -> Result[Void]
  theme = Theme.default()
  frame = Screen.frame(12, 8, [], 0, parts_of(Prompt.view("", 0, 12, 8)).with(banner: ["oops"]))
  cells = TUI.layout(Screen.view(frame, theme), 12, 8)
  wanted = TUI.layout(Components.notice(frame.banner[0], theme), 12, 1)
  for cell in wanted
    found = try cells.find { |c| c.x == cell.x and c.y == 0 }
    try Test.eq(found.char, cell.char)
    try Test.eq(found.style, cell.style)
  end

  try Test.eq((try cells.find { |cell| cell.x == 1 and cell.y == 0 }).style, theme.banner.text)
  Test.eq(frame.banner.size, 1)
end

# The row of the cursor draws through `Components.input_row`: the same cells, with the cursor in the cursor style.
def test_the_cursor_row_draws_through_input_row() -> Result[Void]
  theme = Theme.default()
  prompt = Prompt.view("hi", 1, 12, 8)
  frame = Screen.frame(12, 8, [], 0, parts_of(prompt))
  cells = TUI.layout(Screen.view(frame, theme), 12, 8)
  at = frame.area + frame.queued.size + 1 + prompt.cursor_y
  wanted = TUI.layout(Components.input_row(prompt.rows[prompt.cursor_y], prompt.cursor_x, 12, theme), 12, 1)
  for cell in wanted
    found = try cells.find { |c| c.x == cell.x and c.y == at }
    try Test.eq(found.char, cell.char)
    try Test.eq(found.style, cell.style)
  end

  cursor = try cells.find { |cell| cell.x == prompt.cursor_x and cell.y == at }
  try Test.eq(cursor.style, theme.editor.cursor)
  Test.eq(prompt.rows.size, 1)
end

def parts_of(prompt: Prompt.View) -> Screen.Parts
  Screen.Parts(prompt: prompt, picker: &nothing, panel: &nothing, label: "", level: none, status: "ready")
end

def nothing(_room: Int) -> List[Layout.Row] = []

def rows(frame: Screen.Frame) -> List[String]
  cells = TUI.layout(Screen.view(frame, Theme.default()), frame.width, frame.height)
  (0...frame.height).to_a.map do |y| cells.select { |cell| cell.y == y }.map { |cell| cell.char }.join("").strip end
end
