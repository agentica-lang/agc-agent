## What the transcript holds and the lines it draws in a given width. Pure.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import Calls from "calls"
import Markdown from "markdown"
import Width from "width"

FOLDED_THINKING = "▸ thinking (click or ^T shows it)"
## Every row starts one column in.
INDENT = " "

enum Kind
  User
  Assistant
  Thinking
  Notice
  ## A tool call that runs, ran well or failed.
  ToolRunning
  Tool
  ToolFailed
end

## What the entries show unless a click opened or closed one: the thinking blocks, the bodies of the tool calls.
struct Folds
  thinking: Bool = false
  tools: Bool = false
end

struct Entry
  kind: Kind
  text: String
  ## The id of a tool call and the call.
  call_id: String = ""
  call: Optional[Calls.Call] = none
  ## A click opened or closed the entry (a thinking block, a tool call); none follows the default.
  open: Optional[Bool] = none
  ## The rows of the entry for the width and folds they were cut for; a change of the entry drops them.
  wrapped: Optional[Wrapped] = none
end

## One drawn row of the transcript.
struct Line
  kind: Kind
  spans: List[Markdown.Span]
  ## The index of the entry it draws, -1 for the row between two entries.
  entry: Int = -1
  ## The row goes on the one before it: the text was cut there to fit the width.
  soft: Bool = false
end

struct Wrapped
  width: Int
  folds: Folds
  lines: List[Line]
end

def from_history(messages: List[Protocol.Message]) -> List[Entry]
  entries: List[Entry] = []
  for message in messages
    entries = from_message(entries, message)
  end

  entries
end

## How a turn that did not end as asked is noted, live or in the history; none for one that did.
def stop_note(done: Protocol.TurnFinished) -> Optional[String]
  note = Client.stop_note(done)
  case done.stop_reason
    Protocol.StopReason.EndTurn -> none
    Protocol.StopReason.Cancelled -> some("stopped")
    _ if not note.empty? -> some(note)
    _ -> some("the turn ended: #{Protocol.stop_reason_name(done.stop_reason)}")
  end
end

## Adds `text`: a streamed kind (the answer, the thinking) goes on the end of the last entry when it is of that kind.
def add(entries: List[Entry], kind: Kind, text: String) -> List[Entry]
  streamed = kind == Kind.Assistant or kind == Kind.Thinking
  if streamed and not entries.empty? and entries.last.kind == kind
    last = entries.last
    return entries.take(entries.size - 1).push(last.with(text: last.text + text, wrapped: none))
  end

  entries.push(Entry(kind: kind, text: text))
end

def note(entries: List[Entry], text: String) -> List[Entry] = entries.push(Entry(kind: Kind.Notice, text: text))

## A tool call starts: its entry at the end, or in place of the one of the same call (a replay).
def tool_started(entries: List[Entry], started: Protocol.ToolStarted) -> List[Entry]
  call = Calls.Call(name: started.name, target: started.summary)
  entry = Entry(kind: Kind.ToolRunning, text: "", call_id: started.call_id, call: some(call))
  case found(entries, started.call_id)
    some(at) -> entries.set(at, entry.with(open: entries[at].open))
    none -> entries.push(entry)
  end
end

## A tool call ends: its entry shows how, with its output and diff, `aside` after them, and its duration when `timed`.
def tool_finished(
  entries: List[Entry],
  done: Protocol.ToolFinished,
  aside: String = "",
  timed: Bool = true,
) -> List[Entry]
  state = Calls.State.Failed
  kind = Kind.ToolFailed
  if done.ok
    state = Calls.State.Done
    kind = Kind.Tool
  end

  base = Entry(kind: kind, text: "", call_id: done.call_id, call: some(Calls.Call(name: "", target: done.summary)))
  at = found(entries, done.call_id)
  if at.some?
    base = entries[at.unwrap!].with(kind: kind, wrapped: none)
  end

  call = (
    base.call
      .unwrap_or(Calls.Call(name: "", target: done.summary))
      .with(
        state: state,
        summary: done.summary,
        output: done.output.unwrap_or(""),
        diff: done.diff.unwrap_or(""),
        duration_ms: done.duration_ms,
        aside: aside,
        timed: timed,
      )
  )

  entry = base.with(call: some(call))
  case at
    some(index) -> entries.set(index, entry)
    none -> entries.push(entry)
  end
end

## Opens or closes the entry at `index` when it is a thinking block or a finished tool call.
def toggle(entries: List[Entry], index: Int, folds: Folds) -> List[Entry]
  return entries if index < 0 or index >= entries.size

  entry = entries[index]
  if entry.kind == Kind.Thinking
    return entries.set(index, entry.with(open: some(not open?(entry, folds.thinking)), wrapped: none))
  end

  return entries if entry.kind != Kind.Tool and entry.kind != Kind.ToolFailed

  entries.set(index, entry.with(open: some(not open?(entry, folds.tools)), wrapped: none))
end

## The thinking blocks follow the folds again (after ^T).
def unfold_thinking(entries: List[Entry]) -> List[Entry] = entries.map { |entry| unfolded(entry, Kind.Thinking) }

## The tool calls follow the folds again (after ^O).
def unfold_tools(entries: List[Entry]) -> List[Entry]
  entries.map { |entry| unfolded(unfolded(entry, Kind.Tool), Kind.ToolFailed) }
end

## The entries as rows of at most `width` columns, an empty row between two entries that have rows; the answers as
## markdown, and the thinking only when `thinking`.
def lines(entries: List[Entry], width: Int, folds: Folds) -> List[Line]
  rows: List[Line] = []
  for index in 0...entries.size
    drawn = entry_rows(entries[index], index, width, folds)
    next if drawn.empty?

    if not rows.empty?
      rows = rows.push(Line(kind: entries[index].kind, spans: []))
    end

    rows = rows + drawn
  end

  rows
end

## The last `count` rows of `lines` (all of them when there are fewer), cutting only the entries they reach.
def tail(entries: List[Entry], width: Int, folds: Folds, count: Int) -> List[Line]
  parts: List[List[Line]] = []
  size = 0
  # The kind of the entry after, which the empty row between takes.
  after: Optional[Kind] = none
  index = entries.size - 1
  while index >= 0 and size < count
    drawn = entry_rows(entries[index], index, width, folds)
    if not drawn.empty?
      case after
        some(kind) ->
          parts = parts.push([Line(kind: kind, spans: [])])
          size = size + 1
        none -> nil
      end

      drawn = drawn.drop([drawn.size - (count - size), 0].max.unwrap!)
      parts = parts.push(drawn)
      size = size + drawn.size
      after = some(entries[index].kind)
    end

    index = index - 1
  end

  parts.reverse.flat_map { |rows| rows }
end

## The entries with their rows cut for `width` and `folds`, so that `lines` and `tail` cut only what changed.
def wrapped(entries: List[Entry], width: Int, folds: Folds) -> List[Entry]
  return entries if (entries.all? { |entry| fresh?(entry, width, folds) })

  (0...entries.size).to_a.map do |index|
    entry = entries[index]
    cut = Wrapped(width: width, folds: folds, lines: entry_rows(entry, index, width, folds))
    entry.with(wrapped: some(cut))
  end
end

## `text` cut into rows of at most `width` columns, at spaces when it can.
def wrap(text: String, width: Int) -> List[String] = wrap_marked(text, width).map { |row| row.text }

## A row of a wrapped text, and whether it goes on the one before.
struct Cut
  text: String
  soft: Bool
end

def wrap_marked(text: String, width: Int) -> List[Cut]
  rows: List[Cut] = []
  for paragraph in text.split("\n")
    pieces = wrap_paragraph(paragraph, [width, 1].max.unwrap!)
    rows = rows + (0...pieces.size).to_a.map { |at| Cut(text: pieces[at], soft: at > 0) }
  end

  rows
end

private

# A message of the history drawn as it was live: a thinking block, a tool call with its end, or how the turn ended.
def from_message(entries: List[Entry], message: Protocol.Message) -> List[Entry]
  return entries.push(Entry(kind: Kind.Thinking, text: message.text)) if message.thinking

  case message.tool
    some(started) ->
      running = tool_started(entries, started)
      return message.done.map { |done| tool_finished(running, done) }.unwrap_or(running)
    none -> nil
  end

  case message.stop
    some(done) -> return stop_note(done).map { |text| note(entries, text) }.unwrap_or(entries)
    none -> nil
  end

  case message.role
    Protocol.Role.User -> entries.push(Entry(kind: Kind.User, text: message.text))
    Protocol.Role.Assistant -> entries.push(Entry(kind: Kind.Assistant, text: message.text))
  end
end

def found(entries: List[Entry], call_id: String) -> Optional[Int]
  return none if call_id == ""

  entries.find_index { |e| e.call_id == call_id }
end

def unfolded(entry: Entry, kind: Kind) -> Entry
  return entry if entry.kind != kind

  entry.with(open: none, wrapped: none)
end

# Only a thinking block draws differently with `folds.thinking`, and only a tool call with `folds.tools`.
def fresh?(entry: Entry, width: Int, folds: Folds) -> Bool
  case entry.wrapped
    some(cut) -> cut.width == width and folded(entry, cut.folds) == folded(entry, folds)
    none -> false
  end
end

def folded(entry: Entry, folds: Folds) -> Bool
  case entry.kind
    Kind.Thinking -> folds.thinking
    Kind.Tool -> folds.tools
    Kind.ToolFailed -> folds.tools
    _ -> false
  end
end

def entry_rows(entry: Entry, index: Int, width: Int, folds: Folds) -> List[Line]
  return entry.wrapped.unwrap!.lines if fresh?(entry, width, folds)

  entry_lines(entry, width, folds).map { |line| line.with(entry: index) }
end

def open?(entry: Entry, default: Bool) -> Bool = entry.open.unwrap_or(default)

def entry_lines(entry: Entry, width: Int, folds: Folds) -> List[Line]
  if entry.kind == Kind.Thinking and not open?(entry, folds.thinking)
    return [Line(kind: entry.kind, spans: [Markdown.Span(text: INDENT + FOLDED_THINKING, look: Markdown.Look.Plain)])]
  end

  for call in option_list(entry.call)
    return Calls.rows(call, width, open?(entry, folds.tools)).map { |spans| Line(kind: entry.kind, spans: spans) }
  end

  if entry.kind == Kind.Assistant
    # An answer that only called tools has no text and no row.
    return [] if entry.text.strip == ""

    lead = Markdown.Span(text: INDENT, look: Markdown.Look.Plain)
    rows = Markdown.marked(entry.text, width - INDENT.length)
    return rows.map { |row| Line(kind: entry.kind, spans: [lead] + row.spans, soft: row.soft) }
  end

  wrap_marked(entry.text, width - INDENT.length).map do |row|
    Line(kind: entry.kind, spans: [Markdown.Span(text: INDENT + row.text, look: Markdown.Look.Plain)], soft: row.soft)
  end
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end

def wrap_paragraph(paragraph: String, width: Int) -> List[String]
  rows: List[String] = []
  row = ""
  for word in paragraph.split(" ")
    candidate = word
    if row != ""
      candidate = "#{row} #{word}"
    end

    if Width.text(candidate) <= width
      row = candidate
    else
      if row != ""
        rows = rows.push(row)
      end

      row = word
      while Width.text(row) > width
        parts = Width.cut(row, width)
        if parts[0] == ""
          parts = [row.slice(0, 1), row.slice(1, row.length - 1)]
        end

        rows = rows.push(parts[0])
        row = parts[1]
      end
    end
  end

  rows.push(row)
end
