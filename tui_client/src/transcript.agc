## What the transcript holds and the lines it draws in a given width. Pure.

import Protocol from "pkg/protocol/protocol"

enum Kind
  User
  Assistant
  Thinking
  Notice
end

struct Entry
  kind: Kind
  text: String
end

## One drawn row of the transcript.
struct Line
  kind: Kind
  text: String
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

## The entries as rows of at most `width` characters, an empty row between two entries.
def lines(entries: List[Entry], width: Int) -> List[Line]
  rows: List[Line] = []
  for entry in entries
    if not rows.empty?
      rows = rows.push(Line(kind: entry.kind, text: ""))
    end

    rows = rows + entry_lines(entry, width)
  end

  rows
end

## `text` cut into rows of at most `width` characters, at spaces when it can.
def wrap(text: String, width: Int) -> List[String]
  rows: List[String] = []
  for paragraph in text.split("\n")
    rows = rows + wrap_paragraph(paragraph, [width, 1].max.unwrap!)
  end

  rows
end

private

def entry_lines(entry: Entry, width: Int) -> List[Line]
  prefix = case entry.kind
    Kind.User -> "> "
    Kind.Notice -> "· "
    _ -> ""
  end

  rows = wrap(entry.text, width - prefix.length)
  rest = rows.drop(1).map { |row| Line(kind: entry.kind, text: " " * prefix.length + row) }
  [Line(kind: entry.kind, text: prefix + rows[0])] + rest
end

def wrap_paragraph(paragraph: String, width: Int) -> List[String]
  rows: List[String] = []
  row = ""
  for word in paragraph.split(" ")
    candidate = word
    if row != ""
      candidate = "#{row} #{word}"
    end

    if candidate.length <= width
      row = candidate
    else
      if row != ""
        rows = rows.push(row)
      end

      row = word
      while row.length > width
        rows = rows.push(row.slice(0, width))
        row = row.slice(width, row.length - width)
      end
    end
  end

  rows.push(row)
end
