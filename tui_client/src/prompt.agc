## The text the user types and its cursor, a character index. A row ends at the width, at any character, so a column
## of the screen maps to one place of the text. Pure.

import Regex from "std/regex"
import Width from "width"

MAX_ROWS = 6
NARROW = /\A[ -~]*\z/
LEAD = " "

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

# The rows drawn, and which one has the cursor.
struct Window
  rows: List[Piece]
  cursor_row: Int
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

## The text without the character after `at`.
def delete(text: String, at: Int) -> String
  cut = clamp(text, at)
  return text if cut == text.length

  last = grapheme_end(text.split(""), cut)
  text.slice(0, cut) + text.slice(last, text.length - last)
end

## The text without the characters from `from` up to `to`.
def cut(text: String, from: Int, to: Int) -> String
  first = clamp(text, from)
  last = [clamp(text, to), first].max.unwrap!
  text.slice(0, first) + text.slice(last, text.length - last)
end

## The start of the word before `at`, past the spaces before it; letters and punctuation are words of their own. A
## move never crosses a line end: at the start of a line it goes to the end of the line before.
def word_left(text: String, at: Int) -> Int
  chars = text.split("")
  i = clamp(text, at)
  return i - 1 if i > 0 and chars[i - 1] == "\n"

  while i > 0 and class_of(chars[i - 1]) == SPACE
    i = i - 1
  end

  return i if i == 0 or chars[i - 1] == "\n"

  kind = class_of(chars[i - 1])
  while i > 0 and class_of(chars[i - 1]) == kind
    i = i - 1
  end

  i
end

## The end of the word after `at`, past the spaces before it; at the end of a line, the start of the line after.
def word_right(text: String, at: Int) -> Int
  chars = text.split("")
  i = clamp(text, at)
  return i + 1 if i < chars.size and chars[i] == "\n"

  while i < chars.size and class_of(chars[i]) == SPACE
    i = i + 1
  end

  return i if i == chars.size or chars[i] == "\n"

  kind = class_of(chars[i])
  while i < chars.size and class_of(chars[i]) == kind
    i = i + 1
  end

  i
end

## The start of the line of `at`.
def line_start(text: String, at: Int) -> Int
  cut = clamp(text, at)
  cut - text.slice(0, cut).split("\n").last.length
end

## The end of the line of `at`.
def line_end(text: String, at: Int) -> Int
  cut = clamp(text, at)
  cut + text.slice(cut, text.length - cut).split("\n")[0].length
end

## The column of `at` in the row drawn for it. `width` is the screen's.
def column(text: String, at: Int, width: Int) -> Int
  cut = clamp(text, at)
  all = drawn_rows(text, width)
  piece = all[row_of(all, cut)]
  Width.text(text.slice(piece.start, cut - piece.start))
end

## The place in the row drawn `step` rows above (negative) or below `at`, at `goal` (a column) or the end of a shorter
## row; none past the first or the last row.
def vertical(text: String, at: Int, width: Int, step: Int, goal: Int) -> Optional[Int]
  all = drawn_rows(text, width)
  target = row_of(all, clamp(text, at)) + step
  return none if target < 0 or target >= all.size

  row = all[target]
  index = row.start + Width.cut(row.text, goal)[0].length
  row_end = row.start + row.text.length
  # The end of a row cut by the width is the start of the next one: the cursor stays on its row.
  wrapped = target + 1 < all.size and all[target + 1].start == row_end
  return some(index - 1) if wrapped and index == row_end and row.text.length > 0

  some(index)
end

## Pasted text without its control characters, but for line ends and tabs.
def pasted(text: String) -> String = text.split("").select { |c| kept?(c) }.join("")

def clamp(text: String, at: Int) -> Int = [[at, 0].max.unwrap!, text.length].min.unwrap!

def rows(text: String, width: Int) -> List[String] = view(text, text.length, width, MAX_ROWS + 3).rows

## `height` is the rows of the screen: the prompt leaves three to its rules and the status line.
def view(text: String, cursor: Int, width: Int, height: Int) -> View
  at = clamp(text, cursor)
  shown = window(text, at, width, height)
  piece = shown.rows[shown.cursor_row]
  x = LEAD.length + Width.text(text.slice(piece.start, at - piece.start))
  View(rows: shown.rows.map { |p| lead(p) + p.text }, cursor_x: x, cursor_y: shown.cursor_row)
end

## The index of the text at column `x` of row `y` of the view.
def index_at(text: String, cursor: Int, width: Int, height: Int, x: Int, y: Int) -> Int
  shown = window(text, clamp(text, cursor), width, height)
  piece = shown.rows[[[y, 0].max.unwrap!, shown.rows.size - 1].min.unwrap!]
  piece.start + Width.cut(piece.text, [x - LEAD.length, 0].max.unwrap!)[0].length
end

private

ZWJ = 0x200D
SPACE = 0
# Characters of their own word class: a word move stops where letters and these meet.
PUNCTUATION = Set.new("!\"#$%&'()*+,-./:;<=>?@[\\]^`{|}~".split(""))

# The last rows that fit, or from the cursor's row when it is above them. Only the lines around the cursor are cut
# into rows, so a long text costs little per key.
def window(text: String, at: Int, width: Int, height: Int) -> Window
  # The last column stays free for the cursor past the end of a row.
  columns = [width - LEAD.length - 1, 1].max.unwrap!
  fit = most(height)
  before = text.slice(0, at).split("\n")
  line = before.size - 1
  start = at - before[line].length
  lines = text.split("\n")
  rows = cut_line(lines[line], start, columns)
  row = row_of(rows, at)
  next_line = line + 1
  next_start = start + lines[line].length + 1
  while rows.size - row < fit and next_line < lines.size
    rows = rows + cut_line(lines[next_line], next_start, columns)
    next_start = next_start + lines[next_line].length + 1
    next_line = next_line + 1
  end

  return Window(rows: rows.drop(row).take(fit), cursor_row: 0) if rows.size - row >= fit

  earlier_line = line - 1
  earlier_start = start
  while rows.size < fit and earlier_line >= 0
    earlier_start = earlier_start - lines[earlier_line].length - 1
    earlier = cut_line(lines[earlier_line], earlier_start, columns)
    rows = earlier + rows
    row = row + earlier.size
    earlier_line = earlier_line - 1
  end

  first = [rows.size - fit, 0].max.unwrap!
  Window(rows: rows.drop(first), cursor_row: row - first)
end

# The rows of one line, each as wide as fits; a character wider than a row gets one of its own. A line of printable
# ASCII is cut by length; another is read once, character by character.
def cut_line(line: String, start: Int, columns: Int) -> List[Piece]
  return narrow_rows(line, start, columns) if Regex.match?(line, NARROW)

  out: List[Piece] = []
  row = ""
  from = 0
  used = 0
  at = 0
  for c in line.split("")
    wide = Width.char(c)
    if used + wide > columns and row != ""
      out = out.push(Piece(text: row, start: start + from))
      row = ""
      from = at
      used = 0
    end

    row = row + c
    used = used + wide
    at = at + 1
  end

  out.push(Piece(text: row, start: start + from))
end

def narrow_rows(line: String, start: Int, columns: Int) -> List[Piece]
  count = [(line.length + columns - 1) / columns, 1].max.unwrap!
  (0...count).to_a.map do |k|
    from = k * columns
    Piece(text: line.slice(from, [columns, line.length - from].min.unwrap!), start: start + from)
  end
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

# SPACE for a space, 1 for punctuation, 2 for a letter of a word, 3 for a line end.
def class_of(c: String) -> Int
  return SPACE if c == " " or c == "\t"
  return 1 if PUNCTUATION.include?(c)
  return 3 if c == "\n"

  2
end

# The end of the character at `at` with the zero-width code points after it and a character joined by a ZWJ.
def grapheme_end(chars: List[String], at: Int) -> Int
  last = at + 1
  while last < chars.size and (Width.char(chars[last]) == 0 or chars[last - 1].code == ZWJ)
    last = last + 1
  end

  last
end

# Every row the text draws in `width`, each line cut by the width.
def drawn_rows(text: String, width: Int) -> List[Piece]
  columns = [width - LEAD.length - 1, 1].max.unwrap!
  all: List[Piece] = []
  start = 0
  for line in text.split("\n")
    all = all + cut_line(line, start, columns)
    start = start + line.length + 1
  end

  all
end

def kept?(c: String) -> Bool
  code = c.code
  c == "\n" or c == "\t" or not (code < 0x20 or (code >= 0x7f and code < 0xa0))
end

# The rules above and under the prompt and the status line take three rows.
def most(height: Int) -> Int = [[height - 3, 1].max.unwrap!, MAX_ROWS].min.unwrap!

def lead(piece: Piece) -> String
  return LEAD if piece.start == 0

  " " * LEAD.length
end
