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
  lines = text.split("\n")
  changed = after.split("\n")
  first = before.split("\n").size - 1
  removed = old.split("\n").size
  added = new.split("\n").size
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
  lines = content.split("\n")
  width = lines.size.to_s.length
  capped((0...lines.size).to_a.map { |i| numbered("+", i, lines[i], width) })
end

private

def numbered(mark: String, index: Int, line: String, width: Int) -> String
  number = (index + 1).to_s
  "#{mark} #{" " * (width - number.length)}#{number} #{line}"
end

def capped(rows: List[String]) -> String
  return rows.join("\n") if rows.size <= MAX_LINES

  (rows.take(MAX_LINES) + ["... #{rows.size - MAX_LINES} more lines"]).join("\n")
end
