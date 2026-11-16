## What the screen shows, top to bottom, each region apart: the transcript, the follow-ups waiting, the prompt between
## two rules (or the session picker in its place), the panel under it (an approval) and the status line. `frame` places them on a screen of a size, `view` draws a
## frame as a view tree, and `hit` tells what a click at a cell of the same frame is on, so a click meets what was
## drawn. Pure.

import TUI from "pkg/tui/tui"
import Layout from "panel"
import Markdown from "markdown"
import Prompt from "prompt"
import Theme from "theme"
import Transcript from "transcript"
import Width from "width"

## The rows around the transcript: the editor between two rules, the panel under it, then the status line.
CHROME = 3
RULE = "─"
LEAD = "── "

## What goes around the transcript.
struct Parts
  prompt: Prompt.View
  ## A picker in the editor's place, in the rows it gets; no rows shows the prompt.
  picker: Fn[Int, List[Layout.Row]]
  ## The panel under the editor (an approval), in the rows it gets.
  panel: Fn[Int, List[Layout.Row]]
  ## What the top rule says ("" when idle), and the thinking level its color shows (none for the model's default).
  label: String
  level: Optional[String]
  status: String
  ## The messages waiting for the end of the turn, one row each above the editor.
  queued: List[String] = []
end

## Where each region is: `area` transcript rows (the `transcript` lines shown, from the top), the top rule, the
## picker or else the prompt, the bottom rule, the `panel` rows and the status line.
struct Frame
  width: Int
  height: Int
  transcript: List[Transcript.Line]
  area: Int
  queued: List[String]
  label: String
  level: Optional[String]
  picker: List[Layout.Row]
  prompt: Prompt.View
  panel: List[Layout.Row]
  status: String
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

## The rows the panel may take under an editor of `editor_rows` rows, leaving the rules and the status line (the
## transcript may get none).
def panel_room(height: Int, editor_rows: Int) -> Int = height - editor_rows - CHROME

## The regions on a screen of `width` by `height`; the transcript shows the end of `lines`, `scroll` rows up from it.
def frame(width: Int, height: Int, lines: List[Transcript.Line], scroll: Int, parts: Parts) -> Frame
  picker = parts.picker.call([height - CHROME - 1, 0].max.unwrap!)
  editor = parts.prompt.rows.size
  if not picker.empty?
    editor = picker.size
  end

  asked = parts.panel.call(panel_room(height, editor))
  queued = parts.queued.take([height - editor - asked.size - CHROME, 0].max.unwrap!)
  area = [height - editor - asked.size - queued.size - CHROME, 0].max.unwrap!
  hidden = [lines.size - area, 0].max.unwrap!
  top = [hidden - [scroll, hidden].min.unwrap!, 0].max.unwrap!
  Frame(
    width: width,
    height: height,
    transcript: lines.drop(top).take(area),
    area: area,
    queued: queued.map { |text| Width.cut(" #{text}", width)[0] },
    label: parts.label,
    level: parts.level,
    picker: picker,
    prompt: parts.prompt,
    panel: asked,
    status: parts.status,
  )
end

def view(frame: Frame, theme: Theme.Theme) -> TUI.Node
  rows = frame.transcript.map { |line| transcript_row(line, theme.transcript) }
  blank = (rows.size...frame.area).to_a.map { |_| TUI.line([]) }
  rule = rule_style(frame.level, theme.rules)
  editor = frame.picker.map { |row| panel_row(row, theme.panel) }
  if frame.picker.empty?
    editor = (0...frame.prompt.rows.size).to_a.map { |y| prompt_row(frame.prompt, y, frame.width, theme.editor) }
  end

  top = TUI.line([TUI.span(rule_text(frame.label, frame.width), rule)])
  bottom = TUI.line([TUI.span(rule_text("", frame.width), rule)])
  panel = frame.panel.map { |row| panel_row(row, theme.panel) }
  footer = TUI.line([TUI.span(frame.status, theme.footer.status)])
  queued = frame.queued.map { |text| TUI.line([TUI.span(text, theme.transcript.notice)]) }
  TUI.col(rows + blank + queued + [top] + editor + [bottom] + panel + [footer])
end

def hit(frame: Frame, x: Int, y: Int) -> Hit
  return Hit.Entry(frame.transcript[y].entry) if y >= 0 and y < frame.transcript.size

  editor_top = frame.area + frame.queued.size + 1
  editor = editor_rows(frame)
  if y >= editor_top and y < editor_top + editor
    return Hit.Prompt(x, y - editor_top) if frame.picker.empty?

    return button(frame.picker[y - editor_top], x)
  end

  panel_top = editor_top + editor + 1
  return button(frame.panel[y - panel_top], x) if y >= panel_top and y < panel_top + frame.panel.size

  Hit.Nothing
end

def style(kind: Transcript.Kind, look: Markdown.Look, colors: Theme.TranscriptColors) -> TUI.Style
  case look
    Markdown.Look.Title -> colors.tool
    Markdown.Look.Arg -> arg_style(kind, colors)
    Markdown.Look.Muted -> colors.output
    Markdown.Look.Removed -> colors.removed
    Markdown.Look.Added -> colors.added
    _ -> text_style(kind, look, colors)
  end
end

private

def editor_rows(frame: Frame) -> Int
  return frame.prompt.rows.size if frame.picker.empty?

  frame.picker.size
end

def button(row: Layout.Row, x: Int) -> Hit
  case Layout.hit(row, x)
    some(event) -> Hit.Key(event)
    none -> Hit.Nothing
  end
end

# A full-width rule, with `label` after its lead when there is one.
def rule_text(label: String, width: Int) -> String
  text = RULE * width
  if label != ""
    text = "#{LEAD}#{label} #{text}"
  end

  Width.cut(text, width)[0]
end

def rule_style(level: Optional[String], colors: Theme.RuleColors) -> TUI.Style
  case level.unwrap_or("")
    "low" -> colors.low
    "medium" -> colors.medium
    "high" -> colors.high
    _ -> colors.default
  end
end

def panel_row(row: Layout.Row, colors: Theme.PanelColors) -> TUI.Node
  TUI.line([TUI.span(row.text, panel_style(row.look, colors))])
end

# The argument of a tool call, tinted by how the call went.
def arg_style(kind: Transcript.Kind, colors: Theme.TranscriptColors) -> TUI.Style
  case kind
    Transcript.Kind.ToolFailed -> colors.arg_failed
    Transcript.Kind.Tool -> colors.arg_done
    _ -> colors.arg_running
  end
end

def text_style(kind: Transcript.Kind, look: Markdown.Look, colors: Theme.TranscriptColors) -> TUI.Style
  case kind
    Transcript.Kind.User -> colors.user
    Transcript.Kind.Notice -> colors.notice
    Transcript.Kind.Thinking -> colors.thinking
    Transcript.Kind.Assistant ->
      case look
        Markdown.Look.Bold -> colors.bold
        Markdown.Look.Heading -> colors.heading
        Markdown.Look.Code -> colors.code
        _ -> colors.assistant
      end

    _ -> colors.tool
  end
end

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
