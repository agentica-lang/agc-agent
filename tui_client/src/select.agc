## Selecting the text of the transcript with the mouse. A cell is a row counted from the first row of the transcript (0),
## so a scroll, or rows added at its end, leave the cells where they are, and a column. Pure.

import Markdown from "markdown"
import Transcript from "transcript"
import Width from "width"

## The columns past the end of a row.
FAR = 100_000
## Two clicks on one cell within this many ms are a double click.
DOUBLE_MS = 400
## The columns of the gutter before the text of a row, which a copy leaves out.
GUTTER = 1

struct Cell
  row: Int
  col: Int
end

## The cell the button went down on, and the entry its row draws (-1 for the row between two entries).
struct Press
  cell: Cell
  entry: Int
end

## A click that ended where it started: where, when, and the entry it folded or unfolded (-1 for none).
struct Click
  cell: Cell
  at_ms: Int
  toggled: Int = -1
end

struct Selection
  anchor: Cell
  head: Cell
end

## The cell at column `x` of the row `y` of the screen, when `top` is the number of the row at its top.
def cell_at(top: Int, x: Int, y: Int) -> Cell = Cell(row: top + y, col: x)

## The two ends in reading order: the earlier one first.
def ends(selection: Selection) -> List[Cell]
  a = selection.anchor
  b = selection.head
  return [a, b] if a.row < b.row or (a.row == b.row and a.col <= b.col)

  [b, a]
end

## The columns from and to (past the last) that the selection covers in each of the `rows` rows of the screen, `top`
## being the number of the first; an empty list for a row it does not touch.
def marks(selection: Optional[Selection], top: Int, rows: Int) -> List[List[Int]]
  case selection
    some(chosen) ->
      pair = ends(chosen)
      (0...rows).to_a.map { |y| marked(pair[0], pair[1], top + y) }
    none -> []
  end
end

## The text a selection copies from `lines`, the rows of the transcript: the text of the rows without their gutter, with
## a row that was cut to fit the width joined to the one before.
def text(selection: Selection, lines: List[Transcript.Line]) -> String
  pair = ends(selection)
  out: List[String] = []
  row = [pair[0].row, 0].max.unwrap!
  last = [pair[1].row, lines.size - 1].min.unwrap!
  while row <= last
    if row >= 0 and row < lines.size
      line = lines[row]
      from = 0
      to = FAR
      if row == pair[0].row
        from = pair[0].col
      end

      if row == pair[1].row
        to = pair[1].col + 1
      end

      piece = columns(Markdown.plain(line.spans), from, to, code?(line), line.indent)
      if row == pair[0].row
        out = [piece]
      elsif line.join == Markdown.JOIN_DIRECT
        out = out.push(piece)
      elsif line.join == Markdown.JOIN_SPACE
        out = out.push(" #{trimmed_start(piece)}")
      else
        out = out.push("\n#{piece}")
      end
    end

    row = row + 1
  end

  out.join("")
end

## The word at `cell` in `lines` (the rows of the transcript), as a selection; none on a space or past the row.
def word_at(lines: List[Transcript.Line], cell: Cell) -> Optional[Selection]
  at = cell.row
  return none if at < 0 or at >= lines.size

  chars = Markdown.plain(lines[at].spans).split("")
  index = char_at(chars, cell.col)
  return none if index < 0 or chars[index].strip == ""

  first = index
  while first > 0 and chars[first - 1].strip != ""
    first = first - 1
  end

  last = index
  while last + 1 < chars.size and chars[last + 1].strip != ""
    last = last + 1
  end

  left = Width.text(chars.take(first).join(""))
  right = Width.text(chars.take(last + 1).join("")) - 1
  some(Selection(anchor: Cell(row: cell.row, col: left), head: Cell(row: cell.row, col: right)))
end

## The spans of a row cut at the columns from and to, so that the part inside can be drawn apart: before, inside, after.
def split_at(text: String, from: Int, to: Int) -> List[String]
  start = [from, 0].max.unwrap!
  head = Width.cut(text, start)
  rest = Width.cut(head[1], [to - start, 0].max.unwrap!)
  [head[0], rest[0], rest[1]]
end

private

def marked(first: Cell, last: Cell, row: Int) -> List[Int]
  return [] if row < first.row or row > last.row

  from = 0
  to = FAR
  if row == first.row
    from = first.col
  end

  if row == last.row
    to = last.col + 1
  end

  [from, to]
end

# The part of a row between the columns `from` and `to` (past the last), without the gutter: each character that has a
# cell in them, a wide one also when only its other cell is. The end of a row that is taken to its end loses
# its spaces,
# but a line of code keeps them.
def columns(text: String, from: Int, to: Int, code: Bool, indent: Int) -> String
  start = [from, GUTTER + indent].max.unwrap!
  return "" if to <= start

  # A row taken whole, as the rows between the ends of a long selection are: no walk over its characters.
  if from <= GUTTER + indent and to >= FAR
    return "" if text.length <= GUTTER + indent

    whole = text.slice(GUTTER + indent, text.length - GUTTER - indent)
    return whole if code

    return trimmed_end(whole)
  end

  out = ""
  used = 0
  for char in text.split("")
    size = Width.char(char)
    if used + size > start and used < to
      out = "#{out}#{char}"
    end

    used = used + size
  end

  return trimmed_end(out) if to == FAR and not code

  out
end

# Whether the row is a line of code.
def code?(line: Transcript.Line) -> Bool = line.spans.any? { |span| span.look == Markdown.Look.Code }

# The index of the character that covers the column, -1 past the end.
def char_at(chars: List[String], col: Int) -> Int
  used = 0
  for index in 0...chars.size
    used = used + Width.char(chars[index])
    return index if col < used
  end

  -1
end

def trimmed_end(text: String) -> String
  size = text.length
  while size > 0 and text.at(size - 1) == " "
    size = size - 1
  end

  text.slice(0, size)
end

def trimmed_start(text: String) -> String
  skipped = text.split("").take_while { |c| c == " " }.size
  text.slice(skipped, text.length - skipped)
end
