## The text the user types and its cursor, a character index. A row ends at the width, at any character, so a column
## of the screen maps to one place of the text. Pure.

import Width from "width"

MAX_ROWS = 6
LEAD = "> "

## The rows the prompt draws (at most MAX_ROWS, the cursor's among them), and where the cursor is in them.
struct View
  rows: List[String]
  cursor_x: Int
  cursor_y: Int
end

# One drawn row: its text and the index of its first character.
struct Piece
  text: String
  start: Int
end

def insert(text: String, at: Int, piece: String) -> String
  cut = clamp(text, at)
  text.slice(0, cut) + piece + text.slice(cut, text.length - cut)
end

## The text without the character before `at`.
def backspace(text: String, at: Int) -> String
  cut = clamp(text, at)
  return text if cut == 0

  text.slice(0, cut - 1) + text.slice(cut, text.length - cut)
end

## Pasted text without its control characters, but for line ends and tabs.
def pasted(text: String) -> String = text.split("").select { |c| kept?(c) }.join("")

def clamp(text: String, at: Int) -> Int = [[at, 0].max.unwrap!, text.length].min.unwrap!

def rows(text: String, width: Int) -> List[String] = view(text, text.length, width, MAX_ROWS + 1).rows

## `height` is the rows of the screen: the prompt leaves one to the status line.
def view(text: String, cursor: Int, width: Int, height: Int) -> View
  all = pieces(text, width)
  at = clamp(text, cursor)
  row = row_of(all, at)
  first = first_row(all, row, height)
  led = all.drop(first).take(most(height)).map { |piece| lead(piece) + piece.text }
  x = LEAD.length + Width.text(text.slice(all[row].start, at - all[row].start))
  View(rows: led, cursor_x: x, cursor_y: row - first)
end

## The index of the text at column `x` of row `y` of the view.
def index_at(text: String, cursor: Int, width: Int, height: Int, x: Int, y: Int) -> Int
  all = pieces(text, width)
  first = first_row(all, row_of(all, clamp(text, cursor)), height)
  piece = all[[[first + y, 0].max.unwrap!, all.size - 1].min.unwrap!]
  piece.start + Width.cut(piece.text, [x - LEAD.length, 0].max.unwrap!)[0].length
end

private

def pieces(text: String, width: Int) -> List[Piece]
  columns = [width - LEAD.length, 1].max.unwrap!
  out: List[Piece] = []
  start = 0
  for line in text.split("\n")
    out = out + cut_line(line, start, columns)
    start = start + line.length + 1
  end

  out
end

def cut_line(line: String, start: Int, columns: Int) -> List[Piece]
  out: List[Piece] = []
  rest = line
  at = start
  while true
    parts = Width.cut(rest, columns)
    if parts[0] == "" and rest != ""
      parts = [rest.slice(0, 1), rest.slice(1, rest.length - 1)]
    end

    out = out.push(Piece(text: parts[0], start: at))
    break if parts[1] == ""

    at = at + parts[0].length
    rest = parts[1]
  end

  out
end

# The last row that starts at or before `cursor`.
def row_of(all: List[Piece], cursor: Int) -> Int
  found = 0
  for i in 0...all.size
    if all[i].start <= cursor
      found = i
    end
  end

  found
end

def kept?(c: String) -> Bool
  code = c.code
  c == "\n" or c == "\t" or not (code < 0x20 or (code >= 0x7f and code < 0xa0))
end

def most(height: Int) -> Int = [[height - 1, 1].max.unwrap!, MAX_ROWS].min.unwrap!

# The last rows that fit, or from the cursor's row when it is above them.
def first_row(all: List[Piece], row: Int, height: Int) -> Int
  [[all.size - most(height), 0].max.unwrap!, row].min.unwrap!
end

def lead(piece: Piece) -> String
  return LEAD if piece.start == 0

  " " * LEAD.length
end
