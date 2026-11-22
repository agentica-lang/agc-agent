## The markdown the transcript draws: headings, lists, fenced code, pipe tables and `**bold**`.
## Everything else is plain text. Pure.

import Width from "width"

FENCE = "```"
BULLET = "• "
## How a row goes on from the one before: it starts a line of the text, or the text was cut there to fit the width, at
## a space that is not drawn (`JOIN_SPACE`), or inside a word or a code line (`JOIN_DIRECT`).
JOIN_NEW = 0
JOIN_SPACE = 1
JOIN_DIRECT = 2

## How a span looks: the markdown of an answer, and the parts of a tool call (its title, its argument, its output and
## the removed and added lines of its diff).
enum Look
  Plain
  Bold
  Heading
  Code
  Title
  Arg
  Muted
  Removed
  Added
end

struct Span
  text: String
  look: Look
end

## A row of the text, and how it goes on from the row before.
struct Marked
  spans: List[Span]
  join: Int = 0
  ## The columns of indent a row of a list item starts with after the first: drawn, but not part of the text.
  indent: Int = 0
end

## The rows of `text` in `width` columns, each a list of spans.
def rows(text: String, width: Int) -> List[List[Span]] = marked(text, width).map { |row| row.spans }

## The same rows, each with whether it goes on the one before.
def marked(text: String, width: Int) -> List[Marked]
  columns = [width, 1].max.unwrap!
  out: List[Marked] = []
  code = false
  lines = text.split("\n")
  at = 0
  while at < lines.size
    line = lines[at]
    at = at + 1
    if line.strip.start_with?(FENCE)
      code = not code
    elsif code
      pieces = chunks(line, columns)
      out = (
        out +
        (0...pieces.size).to_a.map { |i| Marked(spans: [Span(text: pieces[i], look: Look.Code)], join: if_cut(i)) }
      )
    else
      table = table_at(line, lines, at, columns)
      if table.rows.empty?
        out = out + block(line, columns)
      else
        out = out + table.rows
        at = table.after
      end
    end
  end

  out
end

# A row of a code line, which is cut at any character: each but the first goes on directly.
def if_cut(at: Int) -> Int
  return JOIN_NEW if at == 0

  JOIN_DIRECT
end

## A code line in rows of `columns`, cut at any character so its spaces stay.
def chunks(line: String, columns: Int) -> List[String]
  out: List[String] = []
  rest = line
  while true
    parts = Width.cut(rest, columns)
    if parts[0] == "" and rest != ""
      parts = [rest.slice(0, 1), rest.slice(1, rest.length - 1)]
    end

    out = out.push(parts[0])
    break if parts[1] == ""

    rest = parts[1]
  end

  out
end

## The text of a row.
def plain(spans: List[Span]) -> String = spans.map { |span| span.text }.join("")

## `text` split at `**` into plain and bold spans; an unclosed `**` makes the rest bold.
def inline(text: String, look: Look) -> List[Span]
  parts = text.split("**")
  spans: List[Span] = []
  for i in 0...parts.size
    if parts[i] != ""
      spans = spans.push(Span(text: parts[i], look: bold_if(i % 2 == 1, look)))
    end
  end

  spans
end

private

struct Table
  rows: List[Marked] = []
  after: Int = 0
end

# A header and a delimiter row distinguish a table from prose containing pipes.
def table_at(header: String, lines: List[String], at: Int, width: Int) -> Table
  return Table() if at >= lines.size or not header.include?("|") or not lines[at].include?("|")

  labels = cells(header)
  rules = cells(lines[at])
  return Table() if (labels.empty? or labels.size != rules.size or not rules.all? { |rule| table_rule?(rule) })

  body = [labels]
  after = at + 1
  while after < lines.size and lines[after].include?("|") and not lines[after].strip.start_with?(FENCE)
    row = cells(lines[after])
    break if row.size != labels.size

    body = body.push(row)
    after = after + 1
  end

  widths = (0...labels.size).to_a.map { |i|
    body.map { |row| Width.text(plain(inline(row[i], Look.Plain))) }.max.unwrap!
  }

  budget = width - 3 * labels.size + 1
  if widths.sum > budget
    cap = budget / labels.size
    return Table() if cap < 2

    widths = widths.map { |size| [size, cap].min.unwrap! }
  end

  rule = widths.map { |size| "─" * (size + 2) }.join("┼")
  heading = table_row(labels, widths, Look.Heading)
  divider = Marked(spans: [Span(text: rule, look: Look.Plain)])
  rows = heading.push(divider)
  for row in body.drop(1)
    rows = rows + table_row(row, widths, Look.Plain)
  end

  Table(rows: rows, after: after)
end

def cells(line: String) -> List[String]
  text = line.strip
  parts = text.split("|")
  start = 0
  if text.start_with?("|")
    start = 1
  end

  stop = parts.size
  if text.end_with?("|")
    stop = stop - 1
  end

  parts.take(stop).drop(start).map { |cell| cell.strip }
end

def table_rule?(rule: String) -> Bool
  marks = rule.split("")
  if rule.start_with?(":")
    marks = marks.drop(1)
  end

  if not marks.empty? and rule.end_with?(":")
    marks = marks.take(marks.size - 1)
  end

  not marks.empty? and marks.all? { |mark| mark == "-" }
end

def table_row(row: List[String], widths: List[Int], look: Look) -> List[Marked]
  columns = (0...row.size).to_a.map { |i| wrapped(inline(row[i], look), widths[i]) }
  height = columns.map { |column| column.size }.max.unwrap!
  (0...height).to_a.map { |y| table_line(columns, widths, y) }
end

def table_line(columns: List[List[Marked]], widths: List[Int], y: Int) -> Marked
  spans: List[Span] = []
  for i in 0...columns.size
    if i > 0
      spans = spans.push(Span(text: "│", look: Look.Plain))
    end

    content: List[Span] = []
    if y < columns[i].size
      content = columns[i][y].spans
    end

    pad = widths[i] - Width.text(plain(content))
    spans = spans.push(Span(text: " ", look: Look.Plain)) + content
    spans = spans.push(Span(text: " " * (pad + 1), look: Look.Plain))
  end

  Marked(spans: spans)
end

def bold_if(bold: Bool, look: Look) -> Look
  return Look.Bold if bold and look == Look.Plain

  look
end

def block(line: String, width: Int) -> List[Marked]
  heading = heading_text(line)
  return wrapped(inline(heading.unwrap!, Look.Heading), width) if heading.some?

  item = list_item(line)
  return wrapped(inline(line, Look.Plain), width) if item.none?

  lead = item.unwrap![0]
  rest = item.unwrap![1]
  body = wrapped(inline(rest, Look.Plain), width - Width.text(lead))
  indent = " " * Width.text(lead)
  first = Marked(spans: merged([Span(text: lead, look: Look.Plain)] + body[0].spans), join: body[0].join)
  width_of_lead = Width.text(lead)
  later = body.drop(1)
    .map do |row|
      Marked(spans: merged([Span(text: indent, look: Look.Plain)] + row.spans), join: row.join, indent: width_of_lead)
    end

  [first] + later
end

# `# Title` to `###### Title`: the title.
def heading_text(line: String) -> Optional[String]
  marks = line.split("").take_while { |c| c == "#" }.size
  return none if marks == 0 or marks > 6 or line.length <= marks or line.at(marks) != " "

  some(line.slice(marks + 1, line.length - marks - 1).strip)
end

# `- item`, `* item`, `+ item` or `12. item`, maybe indented: the lead to draw (indent and marker) and the text.
def list_item(line: String) -> Optional[List[String]]
  spaces = line.split("").take_while { |c| c == " " }.size
  rest = line.slice(spaces, line.length - spaces)
  indent = " " * spaces
  for marker in ["- ", "* ", "+ "]
    return some([indent + BULLET, rest.slice(2, rest.length - 2)]) if rest.start_with?(marker)
  end

  digits = rest.split("").take_while { |c| c.code >= 48 and c.code <= 57 }.size
  if digits > 0 and rest.slice(digits, rest.length - digits).start_with?(". ")
    marker = rest.slice(0, digits + 2)
    return some([indent + marker, rest.slice(digits + 2, rest.length - digits - 2)])
  end

  none
end

# The spans cut into rows at spaces, a word longer than a row cut where it must.
def wrapped(spans: List[Span], width: Int) -> List[Marked]
  columns = [width, 1].max.unwrap!
  rows: List[Marked] = []
  join = JOIN_NEW
  row: List[Span] = []
  used = 0
  for word in words(spans)
    size = Width.text(plain(word))
    gap = 0
    if used > 0
      gap = 1
    end

    if used + gap + size <= columns
      if gap == 1
        row = row.push(Span(text: " ", look: Look.Plain))
      end

      row = row + word
      used = used + gap + size
    else
      if used > 0
        rows = rows.push(Marked(spans: merged(row), join: join))
        join = JOIN_SPACE
      end

      row = word
      used = size
      if size > columns
        look = word[0].look
        text = plain(word)
        while Width.text(text) > columns
          cut = Width.cut(text, columns)
          if cut[0] == ""
            cut = [text.slice(0, 1), text.slice(1, text.length - 1)]
          end

          rows = rows.push(Marked(spans: [Span(text: cut[0], look: look)], join: join))
          join = JOIN_DIRECT
          text = cut[1]
        end

        row = [Span(text: text, look: look)]
        used = Width.text(text)
      end
    end
  end

  rows.push(Marked(spans: merged(row), join: join))
end

# The words of the spans, each a list of spans: `**bold**,` is one word of two looks.
def words(spans: List[Span]) -> List[List[Span]]
  out: List[List[Span]] = []
  joined = false
  for span in spans
    pieces = span.text.split(" ")
    for i in 0...pieces.size
      if i > 0
        joined = false
      end

      if pieces[i] != ""
        piece = Span(text: pieces[i], look: span.look)
        if joined and not out.empty?
          out = out.take(out.size - 1).push(out.last.push(piece))
        else
          out = out.push([piece])
        end

        joined = true
      end
    end
  end

  out
end

def merged(row: List[Span]) -> List[Span]
  out: List[Span] = []
  for span in row
    if not out.empty? and out.last.look == span.look
      out = out.take(out.size - 1).push(out.last.with(text: out.last.text + span.text))
    else
      out = out.push(span)
    end
  end

  out
end
