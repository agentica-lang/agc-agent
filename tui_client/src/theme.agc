## Every color the client draws with, one record per region of the screen. Pure.

import TUI from "pkg/tui/tui"

## The transcript: each kind of entry, and the looks of the markdown of an answer.
struct TranscriptColors
  user: TUI.Style
  assistant: TUI.Style
  bold: TUI.Style
  heading: TUI.Style
  code: TUI.Style
  thinking: TUI.Style
  notice: TUI.Style
  ## The title of a tool call (`$`, `read`), its argument while it runs, after it ran well or failed, its output
  ## and the removed and added lines of its diff.
  tool: TUI.Style
  arg_running: TUI.Style
  arg_done: TUI.Style
  arg_failed: TUI.Style
  output: TUI.Style
  removed: TUI.Style
  added: TUI.Style
end

## The panel over the prompt (an approval, the session picker).
struct PanelColors
  ## The head and the key rows.
  head: TUI.Style
  text: TUI.Style
  selected: TUI.Style
  removed: TUI.Style
  added: TUI.Style
end

## The banner of warnings at the top of the screen.
struct BannerColors
  text: TUI.Style
end

struct FooterColors
  status: TUI.Style
  ## One style per named status segment (`state`, `usage`, `rate`, `hints`, `model`, `chatgpt.quota` and an
  ## extension's names), keyed by the lowercased segment name; a name missing here draws in `status`.
  segments: Map[String, TUI.Style] = {}
end

## The prompt.
struct EditorColors
  text: TUI.Style
  cursor: TUI.Style
end

## The rules around the editor: their color shows the thinking level of the session.
struct RuleColors
  ## The model's own default.
  default: TUI.Style
  low: TUI.Style
  medium: TUI.Style
  high: TUI.Style
end

struct Theme
  transcript: TranscriptColors
  panel: PanelColors
  banner: BannerColors
  footer: FooterColors
  editor: EditorColors
  rules: RuleColors
end

## The colors the client draws with, a dark theme of the 256-color palette.
def default() -> Theme
  Theme(
    transcript: TranscriptColors(
      user: TUI.Style(fg: TUI.Color.Index(255), bg: TUI.Color.Index(236), bold: true),
      assistant: TUI.Style(),
      bold: TUI.Style(bold: true),
      heading: TUI.Style(fg: TUI.Color.Index(221), bold: true),
      code: TUI.Style(fg: TUI.Color.Index(141)),
      thinking: TUI.Style(fg: TUI.Color.Index(245), italic: true),
      notice: TUI.Style(fg: TUI.Color.Index(245)),
      tool: TUI.Style(fg: TUI.Color.Index(255), bold: true),
      arg_running: TUI.Style(fg: TUI.Color.Index(250), bg: TUI.Color.Index(237)),
      arg_done: TUI.Style(fg: TUI.Color.Index(250), bg: TUI.Color.Index(22)),
      arg_failed: TUI.Style(fg: TUI.Color.Index(250), bg: TUI.Color.Index(52)),
      output: TUI.Style(fg: TUI.Color.Index(245)),
      removed: TUI.Style(fg: TUI.Color.Index(203)),
      added: TUI.Style(fg: TUI.Color.Index(114)),
    ),
    panel: PanelColors(
      head: TUI.Style(fg: TUI.Color.Index(221), bold: true),
      text: TUI.Style(),
      selected: TUI.Style(bg: TUI.Color.Index(24)),
      removed: TUI.Style(fg: TUI.Color.Index(203)),
      added: TUI.Style(fg: TUI.Color.Index(114)),
    ),
    banner: BannerColors(text: TUI.Style(fg: TUI.Color.Index(16), bg: TUI.Color.Index(221))),
    footer: FooterColors(status: TUI.Style(fg: TUI.Color.Index(245))),
    editor: EditorColors(text: TUI.Style(), cursor: TUI.Style(reverse: true)),
    rules: RuleColors(
      default: TUI.Style(fg: TUI.Color.Index(240)),
      low: TUI.Style(fg: TUI.Color.Index(67)),
      medium: TUI.Style(fg: TUI.Color.Index(69)),
      high: TUI.Style(fg: TUI.Color.Index(141)),
    ),
  )
end

## The colors for a terminal of the eight named colors.
def basic() -> Theme
  Theme(
    transcript: TranscriptColors(
      user: TUI.Style(bold: true),
      assistant: TUI.Style(),
      bold: TUI.Style(bold: true),
      heading: TUI.Style(fg: TUI.Color.Yellow, bold: true),
      code: TUI.Style(fg: TUI.Color.Magenta),
      thinking: TUI.Style(dim: true, italic: true),
      notice: TUI.Style(dim: true),
      tool: TUI.Style(bold: true),
      arg_running: TUI.Style(dim: true),
      arg_done: TUI.Style(fg: TUI.Color.Green),
      arg_failed: TUI.Style(fg: TUI.Color.Red),
      output: TUI.Style(dim: true),
      removed: TUI.Style(fg: TUI.Color.Red),
      added: TUI.Style(fg: TUI.Color.Green),
    ),
    panel: PanelColors(
      head: TUI.Style(fg: TUI.Color.Yellow, bold: true),
      text: TUI.Style(),
      selected: TUI.Style(reverse: true),
      removed: TUI.Style(fg: TUI.Color.Red),
      added: TUI.Style(fg: TUI.Color.Green),
    ),
    banner: BannerColors(text: TUI.Style(fg: TUI.Color.Black, bg: TUI.Color.Yellow)),
    footer: FooterColors(status: TUI.Style(dim: true)),
    editor: EditorColors(text: TUI.Style(), cursor: TUI.Style(reverse: true)),
    rules: RuleColors(
      default: TUI.Style(dim: true),
      low: TUI.Style(fg: TUI.Color.Cyan),
      medium: TUI.Style(fg: TUI.Color.Blue),
      high: TUI.Style(fg: TUI.Color.Magenta),
    ),
  )
end

## The style of one named status segment: its entry of `colors.segments` (keyed by the lowercased name), or
## `colors.status` when no rule named it. Filler (separators, padding and the place row) always uses `status`.
def footer_style(colors: FooterColors, name: String) -> TUI.Style
  colors.segments.get(name.strip.downcase).unwrap_or(colors.status)
end

## Whether a terminal shows the 256-color palette, from its `TERM` and `COLORTERM`.
def colors256?(term: String, colorterm: String) -> Bool = term.include?("256color") or colorterm != ""
