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
  tool: TUI.Style
  tool_failed: TUI.Style
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

struct FooterColors
  status: TUI.Style
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
  footer: FooterColors
  editor: EditorColors
  rules: RuleColors
end

## The colors the client draws with, a dark theme of the 256-color palette.
def default() -> Theme
  Theme(
    transcript: TranscriptColors(
      user: TUI.Style(fg: TUI.Color.Index(255), bold: true),
      assistant: TUI.Style(),
      bold: TUI.Style(bold: true),
      heading: TUI.Style(fg: TUI.Color.Index(221), bold: true),
      code: TUI.Style(fg: TUI.Color.Index(141)),
      thinking: TUI.Style(fg: TUI.Color.Index(245), italic: true),
      notice: TUI.Style(fg: TUI.Color.Index(245)),
      tool: TUI.Style(fg: TUI.Color.Index(110)),
      tool_failed: TUI.Style(fg: TUI.Color.Index(203)),
    ),
    panel: PanelColors(
      head: TUI.Style(fg: TUI.Color.Index(221), bold: true),
      text: TUI.Style(),
      selected: TUI.Style(bg: TUI.Color.Index(24)),
      removed: TUI.Style(fg: TUI.Color.Index(203)),
      added: TUI.Style(fg: TUI.Color.Index(114)),
    ),
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
