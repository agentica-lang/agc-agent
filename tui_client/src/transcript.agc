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
end

## One drawn row of the transcript.
struct Line
  kind: Kind
  spans: List[Markdown.Span]
  ## The index of the entry it draws, -1 for the row between two entries.
  entry: Int = -1
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
    return entries.take(entries.size - 1).push(last.with(text: last.text + text))
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
  return entries.set(index, entry.with(open: some(not open?(entry, thinking)))) if entry.kind == Kind.Thinking
  return entries if not tool?(entry) or entry.call == ""

  entries.set(index, entry.with(open: some(not open?(entry, false))))
end

## The thinking blocks follow the default again (after ^T).
def unfold_thinking(entries: List[Entry]) -> List[Entry] = entries.map { |entry| unfolded(entry) }

## The entries as rows of at most `width` columns, an empty row between two entries; the answers as markdown, and the
## thinking only when `thinking`.
def lines(entries: List[Entry], width: Int, thinking: Bool) -> List[Line]
  rows: List[Line] = []
  for index in 0...entries.size
    entry = entries[index]
    if not rows.empty?
      rows = rows.push(Line(kind: entry.kind, spans: []))
    end

    rows = rows + entry_lines(entry, width, thinking).map { |line| line.with(entry: index) }
  end

  rows
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

  entry.with(open: none)
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
