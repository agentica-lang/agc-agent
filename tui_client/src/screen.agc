## What the screen shows, top to bottom, each region apart: the banner of warnings, the transcript, the follow-ups
## waiting, the prompt between two rules (or the session picker in its place), the panel under it (an approval), the
## place row (folder, branch, session) and the status line. `frame` places them on a screen of a size, `view` draws a
## frame as a view tree, and `hit` tells what a click at a cell of the same frame is on, so a click meets what was
## drawn. Pure.

import Client from "pkg/client/client"
import TUI from "pkg/tui/tui"
import Components from "components"
import Footer from "footer"
import Layout from "panel"
import Markdown from "markdown"
import Prompt from "prompt"
import Select from "select"
import Side from "side"
import Theme from "theme"
import Transcript from "transcript"
import Width from "width"

## The rows around the transcript: the editor between two rules, the panel under it, then the status. The place row
## above the status takes a row only when the editor and the panel leave one.
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
  status: List[Footer.Span]
  ## The messages waiting for the end of the turn, one row each above the editor.
  queued: List[String] = []
  ## The row above the status: where the session is.
  place: String = ""
  ## The banner at the top of the screen, one row each; none shows no banner.
  banner: List[String] = []
  ## The side panel that takes the transcript's place (on a narrow screen); none leaves the transcript.
  cover: Optional[Side.Side] = none
  ## The keys in effect, for the hints of the panel.
  keys: Optional[Client.Bindings] = none
end

## Where each region is: `area` transcript rows (the `transcript` lines shown, from the top), the top rule, the
## picker or else the prompt, the bottom rule, the `panel` rows, the place and the status line.
struct Frame
  width: Int
  height: Int
  transcript: List[Transcript.Line]
  ## The number of the row at the top of `transcript`: in the lines given to `frame`, and counted from the first row of
  ## the transcript once `Views.located` (or `framed`, with a selection) has it.
  top: Int
  ## The columns of each row of `transcript` that a selection covers (from, to), or an empty list.
  marks: List[List[Int]] = []
  area: Int
  queued: List[String]
  label: String
  level: Optional[String]
  picker: List[Layout.Row]
  prompt: Prompt.View
  panel: List[Layout.Row]
  ## The place row, none on a screen too short for it.
  place: List[String]
  status: List[Footer.Span]
  ## The banner rows above the transcript, as many as the screen has room for.
  banner: List[String] = []
  ## The rows of the side panel in the transcript's place, which then shows no lines.
  cover: List[Layout.Row] = []
end

## What a click is on.
enum Hit
  ## The transcript entry of a row (-1 for the row between two entries).
  Entry(Int)
  ## A button of the panel, as the key it stands for.
  Key(TUI.Event)
  ## A row of the banner.
  Banner
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
  place: List[String] = []
  if height - editor - asked.size - CHROME > 0
    place = [parts.place]
  end

  queued = parts.queued.take([height - editor - asked.size - place.size - CHROME, 0].max.unwrap!)
  room = [height - editor - asked.size - place.size - queued.size - CHROME, 0].max.unwrap!
  banner = parts.banner.take(room)
  area = room - banner.size
  hidden = [lines.size - area, 0].max.unwrap!
  top = [hidden - [scroll, hidden].min.unwrap!, 0].max.unwrap!
  shown = lines.drop(top).take(area)
  cover: List[Layout.Row] = []
  for side in option_list(parts.cover)
    cover = Side.rows(side, width, area, false, parts.keys.unwrap_or(Client.defaults()))
    shown = []
  end

  Frame(
    width: width,
    height: height,
    cover: cover,
    transcript: shown,
    top: top,
    area: area,
    queued: queued.map { |text| Width.cut(" #{text}", width)[0] },
    label: parts.label,
    level: parts.level,
    picker: picker,
    prompt: parts.prompt,
    panel: asked,
    place: place,
    status: parts.status,
    banner: (0...banner.size).to_a.map { |i| banner_text(banner[i], width, i == 0) },
  )
end

def view(frame: Frame, theme: Theme.Theme) -> TUI.Node
  rows = (0...frame.transcript.size).to_a.map { |y|
    chosen_row(frame.transcript[y], theme.transcript, mark_of(frame, y))
  }

  if not frame.cover.empty?
    rows = frame.cover.map { |row| panel_row(row, theme.panel) }
  end

  shown = frame.banner.map { |text| Components.notice(text, theme) }
  blank = (rows.size...frame.area).to_a.map { |_| TUI.line([]) }
  rule = rule_style(frame.level, theme.rules)
  editor = frame.picker.map { |row| panel_row(row, theme.panel) }
  if frame.picker.empty?
    editor = (0...frame.prompt.rows.size).to_a.map { |y| prompt_row(frame.prompt, y, frame.width, theme) }
  end

  top = TUI.line([TUI.span(rule_text(frame.label, frame.width), rule)])
  bottom = TUI.line([TUI.span(rule_text("", frame.width), rule)])
  panel = frame.panel.map { |row| panel_row(row, theme.panel) }
  placed = frame.place.map { |text| TUI.line([TUI.span(text, theme.footer.status)]) }
  footer = placed + [status_line(frame.status, theme)]
  queued = frame.queued.map { |text| TUI.line([TUI.span(text, theme.transcript.notice)]) }
  TUI.col(shown + rows + blank + queued + [top] + editor + [bottom] + panel + footer)
end

## `left` with the side panel beside it, a column of its own between them: the rows of the panel, the full height.
def beside(left: TUI.Node, side: List[Layout.Row], theme: Theme.Theme) -> TUI.Node
  rows = side.map { |row| panel_row(row, theme.panel) }
  TUI.row([left] + Components.sidebar_segments(rows, theme))
end

## The row of the transcript area that screen row `y` is: the banner above it is taken off.
def below_banner(frame: Frame, y: Int) -> Int = y - frame.banner.size

def hit(frame: Frame, x: Int, screen_y: Int) -> Hit
  return Hit.Banner if screen_y >= 0 and screen_y < frame.banner.size

  y = below_banner(frame, screen_y)
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

def panel_row(row: Layout.Row, colors: Theme.PanelColors) -> TUI.Node
  return rich_row(row.text, colors) if row.look == Layout.Look.Rich

  TUI.line([TUI.span(row.text, panel_style(row.look, colors))])
end

## A panel line with `**bold**` segments in the head style, the rest in the text style, through the markdown helper
## so `**` never draws itself; an unclosed `**` makes the rest bold.
def rich_row(text: String, colors: Theme.PanelColors) -> TUI.Node
  spans = Markdown.inline(text, Markdown.Look.Plain).map { |span|
    style = colors.text
    if span.look == Markdown.Look.Bold
      style = colors.head
    end

    TUI.span(span.text, style)
  }

  TUI.line(spans)
end

private

# The status row: each named span draws in its `footer-status-<name>` entry when one names it, else in
# `footer.status`; an unnamed span (a separator, the leading space or the padding) is `footer.status`.
def status_line(spans: List[Footer.Span], theme: Theme.Theme) -> TUI.Node
  TUI.line(spans.map { |span| TUI.span(span.text, Theme.footer_style(theme.footer, span.name)) })
end

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

# A banner row cut to the screen and padded to its width; the first one ends with the `x` that closes it (a click
# anywhere on the banner does).
def banner_text(text: String, width: Int, first: Bool) -> String
  cut = Width.cut(" #{text}", [width - 3, 0].max.unwrap!)[0]
  pad = [width - 3 - Width.text(cut), 0].max.unwrap!
  tail = "   "
  if first
    tail = " x "
  end

  "#{cut}#{" " * pad}#{tail}"
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

# The columns of row y that the selection covers.
def mark_of(frame: Frame, y: Int) -> List[Int]
  return [] if y >= frame.marks.size

  frame.marks[y]
end

# A row of the transcript with the part a selection covers reversed.
def chosen_row(line: Transcript.Line, colors: Theme.TranscriptColors, mark: List[Int]) -> TUI.Node
  return transcript_row(line, colors) if mark.empty?

  col = 0
  nodes: List[TUI.Span] = []
  for span in line.spans
    look = style(line.kind, span.look, colors)
    parts = Select.split_at(span.text, mark[0] - col, mark[1] - col)
    for at in 0...3
      next if parts[at] == ""

      shown = look
      if at == 1
        shown = look.with(reverse: true)
      end

      nodes = nodes.push(TUI.span(parts[at], shown))
    end

    col = col + Width.text(span.text)
  end

  TUI.line(nodes)
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
    # Rich lines never reach here: `panel_row` splits them into spans first.
    Layout.Look.Rich -> colors.text
  end
end

# Other rows show their text; the row of the cursor draws through `Components.input_row`: the character under it
# reversed (a space past the end of the text), in the last column at most.
def prompt_row(prompt: Prompt.View, y: Int, width: Int, theme: Theme.Theme) -> TUI.Node
  text = prompt.rows[y]
  return TUI.line([TUI.span(text, theme.editor.text)]) if y != prompt.cursor_y

  Components.input_row(text, prompt.cursor_x, width, theme)
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
