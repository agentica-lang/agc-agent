## The layout of a panel over the prompt (an approval, the session picker): a head, a body and the key rows, fitted
## in the rows left on the screen. When rows are cut, the first row of the head stays, then the first key rows, then
## the rest of the head; the body gets what is left. Only a key row has buttons, at the spans of its labels; the head
## and the body never do. Pure.

import TUI from "pkg/tui/tui"
import Transcript from "transcript"
import Width from "width"

SEPARATOR = " · "

## A label of the key row; a click on it is `event` when there is one.
struct Key
  label: String
  event: Optional[TUI.Event] = none
end

## The columns `from` up to (not with) `to` of a row are a button.
struct Button
  from: Int
  to: Int
  event: TUI.Event
end

## How a row looks; the theme gives each its style.
enum Look
  ## The head and the key rows.
  Head
  Plain
  Selected
  Removed
  Added
end

struct Row
  text: String
  look: Look = Look.Plain
  buttons: List[Button] = []
end

## `head` is wrapped to `width` and `keys` packed into rows of it; `body` gets the number of rows left for it.
def fit(head: String, keys: List[Key], body: Fn[Int, List[Row]], width: Int, room: Int) -> List[Row]
  return [] if room <= 0

  # The first row of the head stays, so the panel always says what it asks; the last key rows go first.
  packed = key_rows(keys, width).take(room - 1)
  left = room - packed.size
  head_rows = Transcript.wrap(head, width).take(left).map { |line| Row(text: line, look: Look.Head) }
  body_rows = body.call(left - head_rows.size)
  head_rows + body_rows + packed
end

## The event of the button at column `x` of a row.
def hit(row: Row, x: Int) -> Optional[TUI.Event]
  found = row.buttons.select { |b| x >= b.from and x < b.to }
  return none if found.empty?

  some(found[0].event)
end

private

# The labels in rows of `width`, separated by SEPARATOR; a label wider than a row is cut.
def key_rows(keys: List[Key], width: Int) -> List[Row]
  columns = [width, 1].max.unwrap!
  rows: List[Row] = []
  row = Row(text: "", look: Look.Head)
  used = 0
  for key in keys
    label = Width.cut(key.label, columns)[0]
    size = Width.text(label)
    gap = 0
    if row.text != ""
      gap = Width.text(SEPARATOR)
    end

    if row.text != "" and used + gap + size > columns
      rows = rows.push(row)
      row = Row(text: "", look: Look.Head)
      used = 0
      gap = 0
    end

    from = used + gap
    if gap > 0
      row = row.with(text: row.text + SEPARATOR)
    end

    row = row.with(text: row.text + label)
    for event in option_list(key.event)
      row = row.with(buttons: row.buttons.push(Button(from: from, to: from + size, event: event)))
    end

    used = from + size
  end

  rows.push(row)
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
