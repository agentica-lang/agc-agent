## A tool call as the transcript draws it, like a shell line: `$ make test`, `read src/app.agc`, `edit README.md`,
## then its diff and output, muted, and how long it took. Folded, the body shows its first FOLDED_ROWS rows. Pure.

import Markdown from "markdown"

FOLDED_ROWS = 4
## The tool a `!` command runs as, drawn `$ command`.
BASH = "bash"
LEAD = " "
BODY = "   "

enum State
  Running
  Done
  Failed
end

struct Call
  name: String
  target: String
  state: State = State.Running
  summary: String = ""
  output: String = ""
  diff: String = ""
  duration_ms: Int = 0
  ## A muted line after the output, shown folded too.
  aside: String = ""
  ## "Took" shows the duration.
  timed: Bool = true
end

## The rows of `call` in `width` columns; `open` shows the whole body.
def rows(call: Call, width: Int, open: Bool) -> List[List[Markdown.Span]]
  head = [[span(LEAD, Markdown.Look.Plain)] + title(call, [width - LEAD.length, 1].max.unwrap!)]
  return head if call.state == State.Running

  columns = [width - BODY.length, 1].max.unwrap!
  body = body_lines(call).flat_map do |line|
    Markdown.chunks(line.text, columns).map { |piece| [span(BODY + piece, line.look)] }
  end

  shown = body
  if not open and body.size > FOLDED_ROWS
    more = "#{BODY}… #{body.size - FOLDED_ROWS} more lines (click or ^O shows them)"
    shown = body.take(FOLDED_ROWS).push([span(more, Markdown.Look.Muted)])
  end

  if call.aside != ""
    shown = shown.push([span(BODY + call.aside, Markdown.Look.Muted)])
  end

  return head + shown if not call.timed

  head + shown + [[span("#{BODY}Took #{seconds(call.duration_ms)}", Markdown.Look.Muted)]]
end

## `ms` as seconds with one decimal: "0.2s".
def seconds(ms: Int) -> String = "#{ms / 1000}.#{ms % 1000 / 100}s"

private

struct Shown
  text: String
  look: Markdown.Look
end

def span(text: String, look: Markdown.Look) -> Markdown.Span = Markdown.Span(text: text, look: look)

# The title of the call (`$` for a command) and its argument, cut to `columns`.
def title(call: Call, columns: Int) -> List[Markdown.Span]
  word = case call.name
    _ if call.name == BASH -> "$"
    "read_file" -> "read"
    "write_file" -> "write"
    "edit_file" -> "edit"
    "apply_patch" -> "patch"
    _ -> call.name
  end

  return [span(Markdown.chunks(call.target, columns)[0], Markdown.Look.Arg)] if word == ""

  head = Markdown.chunks(word, columns)[0]
  target = call.target.split("\n")[0]
  return [span(head, Markdown.Look.Title)] if target == "" or target == call.name or head.length + 1 >= columns

  [
    span(head, Markdown.Look.Title),
    span(" ", Markdown.Look.Plain),
    span(Markdown.chunks(target, columns - head.length - 1)[0], Markdown.Look.Arg),
  ]
end

# The diff, then the output (the summary when there is none); a failed call shows its error as removed.
def body_lines(call: Call) -> List[Shown]
  diff: List[Shown] = []
  if call.diff != ""
    diff = call.diff.split("\n").map { |line| Shown(text: line, look: diff_look(line)) }
  end

  text = call.output
  if text == ""
    text = call.summary
  end

  look = Markdown.Look.Muted
  if call.state == State.Failed
    look = Markdown.Look.Removed
  end

  output = text.split("\n").select { |line| line != "" }.map { |line| Shown(text: line, look: look) }
  diff + output
end

def diff_look(line: String) -> Markdown.Look
  return Markdown.Look.Removed if line.start_with?("-")
  return Markdown.Look.Added if line.start_with?("+")

  Markdown.Look.Muted
end
