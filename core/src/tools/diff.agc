## What an edit changes, as numbered lines for the clients: `- 6 old` for a removed line, `+ 6 new` for an added one,
## `  5 same` for the context around them and `...` where lines are skipped. Pure.

CONTEXT = 2
MAX_LINES = 60

## The lines of `text` around the first `old` and what `new` puts in its place.
def edit(text: String, old: String, new: String) -> String
  pieces = text.split(old)
  return "" if pieces.size < 2

  before = pieces[0]
  after = before + new + text.slice(before.length + old.length, text.length - before.length - old.length)
  lines = lines_of(text)
  changed = lines_of(after)
  first = before.split("\n").size - 1
  removed = touched(before, old)
  added = touched(before, new)
  top = [first - CONTEXT, 0].max.unwrap!
  bottom = [first + added + CONTEXT, changed.size].min.unwrap!
  width = bottom.to_s.length
  rows: List[String] = []
  if top > 0
    rows = rows.push("...")
  end

  rows = rows + (top...first).to_a.map { |i| numbered(" ", i, lines[i], width) }
  rows = rows + (first...(first + removed)).to_a.map { |i| numbered("-", i, lines[i], width) }
  rows = rows + (first...(first + added)).to_a.map { |i| numbered("+", i, changed[i], width) }
  rows = rows + ((first + added)...bottom).to_a.map { |i| numbered(" ", i, changed[i], width) }
  if bottom < changed.size
    rows = rows.push("...")
  end

  capped(rows)
end

## A new file: each line of `content` added.
def written(content: String) -> String
  lines = lines_of(content)
  width = lines.size.to_s.length
  capped((0...lines.size).to_a.map { |i| numbered("+", i, lines[i], width) })
end

private

# The lines of a text; a line end at the end starts no line.
def lines_of(text: String) -> List[String]
  return text.split("\n").take(text.split("\n").size - 1) if text.end_with?("\n")

  text.split("\n")
end

# How many lines `piece` takes when it starts after `before`: a line end at its end starts no line when the piece
# starts a line.
def touched(before: String, piece: String) -> Int
  count = piece.split("\n").size
  return count - 1 if piece.end_with?("\n") and (before == "" or before.end_with?("\n"))

  count
end

def numbered(mark: String, index: Int, line: String, width: Int) -> String
  number = (index + 1).to_s
  "#{mark} #{" " * (width - number.length)}#{number} #{line}"
end

def capped(rows: List[String]) -> String
  return rows.join("\n") if rows.size <= MAX_LINES

  (rows.take(MAX_LINES) + ["... #{rows.size - MAX_LINES} more lines"]).join("\n")
end
