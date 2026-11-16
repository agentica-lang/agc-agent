## What the transcript holds and the lines it draws in a given width. Pure.

import Protocol from "pkg/protocol/protocol"
import Markdown from "markdown"
import Width from "width"

FOLDED_THINKING = "▸ thinking (click or ^T shows it)"

enum Kind
  User
  Assistant
  Thinking
  Notice
  ## A tool call that runs or ran well.
  Tool
  ToolFailed
end

struct Entry
  kind: Kind
  text: String
  ## The call of a tool entry, which its end replaces.
  call_id: String = ""
  ## The line of a tool call when it started, which an open entry shows above its end.
  call: String = ""
  ## A click opened or closed the entry (a thinking block, a tool call); none follows the default.
  open: Optional[Bool] = none
  ## The rows of the entry for the width and thinking they were cut for; a change of the entry drops them.
  wrapped: Optional[Wrapped] = none
end

## One drawn row of the transcript.
struct Line
  kind: Kind
  spans: List[Markdown.Span]
  ## The index of the entry it draws, -1 for the row between two entries.
  entry: Int = -1
end

struct Wrapped
  width: Int
  thinking: Bool
  lines: List[Line]
end

def from_history(messages: List[Protocol.Message]) -> List[Entry]
  messages.map do |message|
    case message.role
      Protocol.Role.User -> Entry(kind: Kind.User, text: message.text)
      Protocol.Role.Assistant -> Entry(kind: Kind.Assistant, text: message.text)
    end
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

## Puts the entry of a tool call in place of the one of the same call, or at the end.
def tool(entries: List[Entry], call_id: String, kind: Kind, text: String) -> List[Entry]
  entry = Entry(kind: kind, text: text, call_id: call_id)
  case (entries.find_index { |e| e.call_id == call_id and call_id != "" })
    some(at) ->
      old = entries[at]
      call = old.call
      if call == ""
        call = old.text
      end

      entries.set(at, entry.with(call: call, open: old.open))
    none -> entries.push(entry)
  end
end

## Opens or closes the entry at `index` when it is a thinking block or a tool call; `thinking` is the default of the
## thinking blocks.
def toggle(entries: List[Entry], index: Int, thinking: Bool) -> List[Entry]
  return entries if index < 0 or index >= entries.size

  entry = entries[index]
  default = entry.kind == Kind.Thinking and thinking
  return entries if entry.kind != Kind.Thinking and (not tool?(entry) or entry.call == "")

  entries.set(index, entry.with(open: some(not open?(entry, default)), wrapped: none))
end

## The thinking blocks follow the default again (after ^T).
def unfold_thinking(entries: List[Entry]) -> List[Entry] = entries.map { |entry| unfolded(entry) }

## The entries as rows of at most `width` columns, an empty row between two entries that have rows; the answers as
## markdown, and the thinking only when `thinking`.
def lines(entries: List[Entry], width: Int, thinking: Bool) -> List[Line]
  rows: List[Line] = []
  for index in 0...entries.size
    drawn = entry_rows(entries[index], index, width, thinking)
    next if drawn.empty?

    if not rows.empty?
      rows = rows.push(Line(kind: entries[index].kind, spans: []))
    end

    rows = rows + drawn
  end

  rows
end

## The last `count` rows of `lines` (all of them when there are fewer), cutting only the entries they reach.
def tail(entries: List[Entry], width: Int, thinking: Bool, count: Int) -> List[Line]
  parts: List[List[Line]] = []
  size = 0
  # The kind of the entry after, which the empty row between takes.
  after: Optional[Kind] = none
  index = entries.size - 1
  while index >= 0 and size < count
    drawn = entry_rows(entries[index], index, width, thinking)
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

## The entries with their rows cut for `width` and `thinking`, so that `lines` and `tail` cut only what changed.
def wrapped(entries: List[Entry], width: Int, thinking: Bool) -> List[Entry]
  return entries if (entries.all? { |entry| fresh?(entry, width, thinking) })

  (0...entries.size).to_a.map do |index|
    entry = entries[index]
    cut = Wrapped(width: width, thinking: thinking, lines: entry_rows(entry, index, width, thinking))
    entry.with(wrapped: some(cut))
  end
end

## `text` cut into rows of at most `width` columns, at spaces when it can.
def wrap(text: String, width: Int) -> List[String]
  rows: List[String] = []
  for paragraph in text.split("\n")
    rows = rows + wrap_paragraph(paragraph, [width, 1].max.unwrap!)
  end

  rows
end

private

def unfolded(entry: Entry) -> Entry
  return entry if entry.kind != Kind.Thinking

  entry.with(open: none, wrapped: none)
end

# Only a thinking block draws differently with `thinking`.
def fresh?(entry: Entry, width: Int, thinking: Bool) -> Bool
  case entry.wrapped
    some(cut) -> cut.width == width and (entry.kind != Kind.Thinking or cut.thinking == thinking)
    none -> false
  end
end

def entry_rows(entry: Entry, index: Int, width: Int, thinking: Bool) -> List[Line]
  return entry.wrapped.unwrap!.lines if fresh?(entry, width, thinking)

  entry_lines(entry, width, thinking).map { |line| line.with(entry: index) }
end

def open?(entry: Entry, default: Bool) -> Bool = entry.open.unwrap_or(default)

def tool?(entry: Entry) -> Bool = entry.kind == Kind.Tool or entry.kind == Kind.ToolFailed

def entry_lines(entry: Entry, width: Int, thinking: Bool) -> List[Line]
  if entry.kind == Kind.Thinking and not open?(entry, thinking)
    return [Line(kind: entry.kind, spans: [Markdown.Span(text: FOLDED_THINKING, look: Markdown.Look.Plain)])]
  end

  if tool?(entry) and entry.call != "" and open?(entry, false)
    call = entry_lines(Entry(kind: Kind.Tool, text: entry.call), width, thinking)
    return call + entry_lines(entry.with(call: ""), width, thinking)
  end

  if entry.kind == Kind.Assistant
    # An answer that only called tools has no text and no row.
    return [] if entry.text.strip == ""

    return Markdown.rows(entry.text, width).map { |spans| Line(kind: entry.kind, spans: spans) }
  end

  prefix = case entry.kind
    Kind.User -> "> "
    Kind.Notice -> "· "
    _ -> ""
  end

  rows = wrap(entry.text, width - prefix.length)
  led = [prefix + rows[0]] + rows.drop(1).map { |row| " " * prefix.length + row }
  led.map { |row| Line(kind: entry.kind, spans: [Markdown.Span(text: row, look: Markdown.Look.Plain)]) }
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
