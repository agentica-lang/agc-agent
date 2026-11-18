## The markdown the transcript draws: headings, list items, fenced code blocks and `**bold**`, wrapped to a width.
## Everything else is plain text. Pure.

import Width from "width"

FENCE = "```"
BULLET = "• "

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

## A row of the text, and whether it goes on the row before: the text was cut there to fit the width.
struct Marked
  spans: List[Span]
  soft: Bool
end

## The rows of `text` in `width` columns, each a list of spans.
def rows(text: String, width: Int) -> List[List[Span]] = marked(text, width).map { |row| row.spans }

## The same rows, each with whether it goes on the one before.
def marked(text: String, width: Int) -> List[Marked]
  columns = [width, 1].max.unwrap!
  out: List[Marked] = []
  code = false
  for line in text.split("\n")
    if line.strip.start_with?(FENCE)
      code = not code
    elsif code
      out = out + continued(chunks(line, columns).map { |piece| [Span(text: piece, look: Look.Code)] })
    else
      out = out + continued(block(line, columns))
    end
  end

  out
end

# The rows of one line of the text: each but the first goes on the one before.
def continued(rows: List[List[Span]]) -> List[Marked]
  (0...rows.size).to_a.map { |at| Marked(spans: rows[at], soft: at > 0) }
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

def bold_if(bold: Bool, look: Look) -> Look
  return Look.Bold if bold and look == Look.Plain

  look
end

def block(line: String, width: Int) -> List[List[Span]]
  heading = heading_text(line)
  return wrapped(inline(heading.unwrap!, Look.Heading), width) if heading.some?

  item = list_item(line)
  return wrapped(inline(line, Look.Plain), width) if item.none?

  lead = item.unwrap![0]
  rest = item.unwrap![1]
  body = wrapped(inline(rest, Look.Plain), width - Width.text(lead))
  indent = " " * Width.text(lead)
  first = merged([Span(text: lead, look: Look.Plain)] + body[0])
  [first] + body.drop(1).map { |row| merged([Span(text: indent, look: Look.Plain)] + row) }
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
def wrapped(spans: List[Span], width: Int) -> List[List[Span]]
  columns = [width, 1].max.unwrap!
  rows: List[List[Span]] = []
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
        rows = rows.push(merged(row))
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

          rows = rows.push([Span(text: cut[0], look: look)])
          text = cut[1]
        end

        row = [Span(text: text, look: look)]
        used = Width.text(text)
      end
    end
  end

  rows.push(merged(row))
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
