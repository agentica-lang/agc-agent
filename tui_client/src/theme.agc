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

struct Theme
  transcript: TranscriptColors
  panel: PanelColors
  footer: FooterColors
  editor: EditorColors
end

## The colors the client draws with.
def default() -> Theme
  Theme(
    transcript: TranscriptColors(
      user: TUI.Style(fg: TUI.Color.Cyan, bold: true),
      assistant: TUI.Style(),
      bold: TUI.Style(bold: true),
      heading: TUI.Style(fg: TUI.Color.Magenta, bold: true, underline: true),
      code: TUI.Style(fg: TUI.Color.Green),
      thinking: TUI.Style(dim: true),
      notice: TUI.Style(fg: TUI.Color.Yellow),
      tool: TUI.Style(fg: TUI.Color.Blue),
      tool_failed: TUI.Style(fg: TUI.Color.Red),
    ),
    panel: PanelColors(
      head: TUI.Style(fg: TUI.Color.Yellow, bold: true),
      text: TUI.Style(),
      selected: TUI.Style(reverse: true),
      removed: TUI.Style(fg: TUI.Color.Red),
      added: TUI.Style(fg: TUI.Color.Green),
    ),
    footer: FooterColors(status: TUI.Style(reverse: true)),
    editor: EditorColors(text: TUI.Style(), cursor: TUI.Style(reverse: true)),
  )
end
