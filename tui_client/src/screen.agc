## What the screen shows, top to bottom, each region apart: the transcript, the panel over the prompt (an approval or
## the session picker), the status line and the prompt. `frame` places them on a screen of a size, `view` draws a
## frame as a view tree, and `hit` tells what a click at a cell of the same frame is on, so a click meets what was
## drawn. Pure.

import TUI from "pkg/tui/tui"
import Layout from "panel"
import Markdown from "markdown"
import Prompt from "prompt"
import Theme from "theme"
import Transcript from "transcript"
import Width from "width"

## Where each region is: `area` transcript rows (the `transcript` lines shown, from the top), the `panel` rows after
## them, the status line, then the prompt rows.
struct Frame
  width: Int
  height: Int
  transcript: List[Transcript.Line]
  area: Int
  panel: List[Layout.Row]
  status: String
  prompt: Prompt.View
end

## What a click is on.
enum Hit
  ## The transcript entry of a row (-1 for the row between two entries).
  Entry(Int)
  ## A button of the panel, as the key it stands for.
  Key(TUI.Event)
  ## Column x of row y of the prompt view.
  Prompt(Int, Int)
  Nothing
end

## The rows the panel may take over a prompt of `prompt_rows` rows, leaving the status line and one transcript row.
def panel_room(height: Int, prompt_rows: Int) -> Int = height - prompt_rows - 2

## The regions on a screen of `width` by `height`: `panel` gives the panel rows for the room it has; the transcript
## shows the end of `lines`, `scroll` rows up from it.
def frame(
  width: Int,
  height: Int,
  lines: List[Transcript.Line],
  scroll: Int,
  panel: Fn[Int, List[Layout.Row]],
  status: String,
  prompt: Prompt.View,
) -> Frame
  asked = panel.call(panel_room(height, prompt.rows.size))
  area = [height - prompt.rows.size - asked.size - 1, 0].max.unwrap!
  hidden = [lines.size - area, 0].max.unwrap!
  top = [hidden - [scroll, hidden].min.unwrap!, 0].max.unwrap!
  Frame(
    width: width,
    height: height,
    transcript: lines.drop(top).take(area),
    area: area,
    panel: asked,
    status: status,
    prompt: prompt,
  )
end

def view(frame: Frame, theme: Theme.Theme) -> TUI.Node
  rows = frame.transcript.map { |line| transcript_row(line, theme.transcript) }
  blank = (rows.size...frame.area).to_a.map { |_| TUI.line([]) }
  panel = frame.panel.map { |row| TUI.line([TUI.span(row.text, panel_style(row.look, theme.panel))]) }
  footer = [TUI.line([TUI.span(frame.status, theme.footer.status)])]
  editor = (0...frame.prompt.rows.size).to_a.map { |y| prompt_row(frame.prompt, y, frame.width, theme.editor) }
  TUI.col(rows + blank + panel + footer + editor)
end

def hit(frame: Frame, x: Int, y: Int) -> Hit
  return Hit.Entry(frame.transcript[y].entry) if y >= 0 and y < frame.transcript.size

  panel_top = frame.area
  if y >= panel_top and y < panel_top + frame.panel.size
    case Layout.hit(frame.panel[y - panel_top], x)
      some(event) -> return Hit.Key(event)
      none -> return Hit.Nothing
    end
  end

  prompt_top = panel_top + frame.panel.size + 1
  return Hit.Nothing if y < prompt_top

  Hit.Prompt(x, y - prompt_top)
end

def style(kind: Transcript.Kind, look: Markdown.Look, colors: Theme.TranscriptColors) -> TUI.Style
  case kind
    Transcript.Kind.User -> colors.user
    Transcript.Kind.Notice -> colors.notice
    Transcript.Kind.Tool -> colors.tool
    Transcript.Kind.ToolFailed -> colors.tool_failed
    Transcript.Kind.Thinking -> colors.thinking
    Transcript.Kind.Assistant ->
      case look
        Markdown.Look.Plain -> colors.assistant
        Markdown.Look.Bold -> colors.bold
        Markdown.Look.Heading -> colors.heading
        Markdown.Look.Code -> colors.code
      end
  end
end

private

def transcript_row(line: Transcript.Line, colors: Theme.TranscriptColors) -> TUI.Node
  TUI.line(line.spans.map { |span| TUI.span(span.text, style(line.kind, span.look, colors)) })
end

def panel_style(look: Layout.Look, colors: Theme.PanelColors) -> TUI.Style
  case look
    Layout.Look.Head -> colors.head
    Layout.Look.Plain -> colors.text
    Layout.Look.Selected -> colors.selected
    Layout.Look.Removed -> colors.removed
    Layout.Look.Added -> colors.added
  end
end

# The row of the cursor shows the character under it reversed (a space past the end of the text), in the last column
# at most.
def prompt_row(prompt: Prompt.View, y: Int, width: Int, colors: Theme.EditorColors) -> TUI.Node
  text = prompt.rows[y]
  return TUI.line([TUI.span(text, colors.text)]) if y != prompt.cursor_y

  parts = Width.cut(text, [prompt.cursor_x, width - 1].min.unwrap!)
  return TUI.line([TUI.span(parts[0], colors.text), TUI.span(" ", colors.cursor)]) if parts[1] == ""

  under = parts[1].slice(0, 1)
  rest = parts[1].slice(1, parts[1].length - 1)
  TUI.line([TUI.span(parts[0], colors.text), TUI.span(under, colors.cursor), TUI.span(rest, colors.text)])
end
