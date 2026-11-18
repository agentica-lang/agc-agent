## Selecting the text of the transcript with the mouse. A cell is a row counted from the last row of the transcript (0),
## so a scroll, or a longer transcript, leaves the cells where they are, and a column. Pure.

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

## A click that ended where it started: where, and when.
struct Click
  cell: Cell
  at_ms: Int
end

struct Selection
  anchor: Cell
  head: Cell
end

## The cell at column `x` of the row `y` of the screen, when `base` is the number of the row at its top.
def cell_at(base: Int, x: Int, y: Int) -> Cell = Cell(row: base - y, col: x)

## The two ends in reading order: the earlier one first.
def ends(selection: Selection) -> List[Cell]
  a = selection.anchor
  b = selection.head
  return [a, b] if a.row > b.row or (a.row == b.row and a.col <= b.col)

  [b, a]
end

## The columns from and to (past the last) that the selection covers in each of the `rows` rows of the screen, `base`
## being the number of the first; an empty list for a row it does not touch.
def marks(selection: Optional[Selection], base: Int, rows: Int) -> List[List[Int]]
  case selection
    some(chosen) ->
      pair = ends(chosen)
      (0...rows).to_a.map { |y| marked(pair[0], pair[1], base - y) }
    none -> []
  end
end

## The text a selection copies from `lines`, the last rows of the transcript (at least up to its first row): the text
## of the rows without their gutter, with a row that was cut to fit the width joined to the one before.
def text(selection: Selection, lines: List[Transcript.Line]) -> String
  pair = ends(selection)
  out = ""
  row = pair[0].row
  while row >= pair[1].row
    at = lines.size - 1 - row
    if at >= 0 and at < lines.size
      line = lines[at]
      from = 0
      to = FAR
      if row == pair[0].row
        from = pair[0].col
      end

      if row == pair[1].row
        to = pair[1].col + 1
      end

      piece = columns(Markdown.plain(line.spans), from, to)
      if row == pair[0].row
        out = piece
      elsif line.soft
        out = joined(out, piece, line)
      else
        out = "#{out}\n#{piece}"
      end
    end

    row = row - 1
  end

  out
end

## The word at `cell` in `lines` (the last rows of the transcript), as a selection; none on a space or past the row.
def word_at(lines: List[Transcript.Line], cell: Cell) -> Optional[Selection]
  at = lines.size - 1 - cell.row
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
  return [] if row > first.row or row < last.row

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

# The part of a row between the columns `from` and `to` (past the last), without the gutter; the end of a row that is
# taken to its end loses its spaces.
def columns(text: String, from: Int, to: Int) -> String
  start = [from, GUTTER].max.unwrap!
  return "" if to <= start

  parts = split_at(text, start, to)
  return trimmed_end(parts[1]) if to == FAR

  parts[1]
end

# A row cut to fit the width goes on the one before it: after a space, except a line of code, which keeps its spaces.
def joined(before: String, piece: String, line: Transcript.Line) -> String
  code = line.spans.any? { |span| span.look == Markdown.Look.Code }
  return "#{before}#{piece}" if code

  "#{before} #{trimmed_start(piece)}"
end

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
