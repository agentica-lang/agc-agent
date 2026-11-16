## What an edit changes, as numbered lines for the clients: `- 6 old` for a removed line, `+ 6 new` for an added one,
## `  5 same` for the context around them and `...` where lines are skipped. Pure.

CONTEXT = 2
MAX_LINES = 60

## The lines of `text` that the first `old` changes, as `new` replaces it, with the lines around them.
def edit(text: String, old: String, new: String) -> String
  found = text.index_of(old)
  return "" if old == "" or found.none?

  at = found.unwrap!
  after = text.slice(0, at) + new + text.slice(at + old.length, text.length - at - old.length)
  lines = lines_of(text)
  changed = lines_of(after)
  # The lines the same at the start and at the end of both; what is between them changed.
  head = 0
  while head < lines.size and head < changed.size and lines[head] == changed[head]
    head += 1
  end

  tail = 0
  while (
    tail < lines.size - head and
    tail < changed.size - head and
    lines[lines.size - 1 - tail] == changed[changed.size - 1 - tail]
  )
    tail += 1
  end

  removed_end = lines.size - tail
  added_end = changed.size - tail
  return "" if removed_end == head and added_end == head

  top = [head - CONTEXT, 0].max.unwrap!
  bottom = [added_end + CONTEXT, changed.size].min.unwrap!
  width = [lines.size, changed.size].max.unwrap!.to_s.length
  rows: List[String] = []
  if top > 0
    rows = rows.push("...")
  end

  rows = rows + (top...head).to_a.map { |i| numbered(" ", i, lines[i], width) }
  rows = rows + (head...removed_end).to_a.map { |i| numbered("-", i, lines[i], width) }
  rows = rows + (head...added_end).to_a.map { |i| numbered("+", i, changed[i], width) }
  rows = rows + (added_end...bottom).to_a.map { |i| numbered(" ", i, changed[i], width) }
  if bottom < changed.size
    rows = rows.push("...")
  end

  capped(rows)
end

## How many times `old` is in `text`.
def occurrences(text: String, old: String) -> Int
  return 0 if old == ""

  text.split(old).size - 1
end

## A new file: each line of `content` added.
def written(content: String) -> String
  return "" if content == ""

  lines = lines_of(content)
  width = lines.size.to_s.length
  capped((0...lines.size).to_a.map { |i| numbered("+", i, lines[i], width) })
end

private

# The lines of a text; a line end at the end starts no line.
def lines_of(text: String) -> List[String]
  return [] if text == ""
  return text.split("\n").take(text.split("\n").size - 1) if text.end_with?("\n")

  text.split("\n")
end

def numbered(mark: String, index: Int, line: String, width: Int) -> String
  number = (index + 1).to_s
  shown = line
  # A CRLF file: the line end is not drawn.
  if shown.end_with?("\r")
    shown = shown.slice(0, shown.length - 1)
  end

  "#{mark} #{" " * [width - number.length, 0].max.unwrap!}#{number} #{shown}"
end

def capped(rows: List[String]) -> String
  return rows.join("\n") if rows.size <= MAX_LINES

  (rows.take(MAX_LINES) + ["... #{rows.size - MAX_LINES} more lines"]).join("\n")
end
