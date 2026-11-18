## What the model does with a selection: the copy when the button goes up, and the word of a double click.

import Select from "select"
import State from "state"
import Terminal from "terminal"
import Transcript from "transcript"

## Copies the selected text to the clipboard of the terminal and says how much. The note adds rows at the end of the
## transcript, so the selection moves up by them and stays on the same text.
def copied(app: State.Model) -> State.Model
  chosen = app.selection.unwrap!
  first = Select.ends(chosen)[0]
  lines = Transcript.tail(app.entries, app.width, State.folds(app), first.row + 1)
  text = Select.text(chosen, lines)
  return app if text == ""

  app.write.call(Terminal.osc52(text))
  before = Transcript.lines(app.entries, app.width, State.folds(app)).size
  noted = State.noted(app, "copied #{text.length} characters")
  shift = Transcript.lines(noted.entries, app.width, State.folds(app)).size - before
  noted.with(
    selection: some(Select.Selection(anchor: lowered(chosen.anchor, shift), head: lowered(chosen.head, shift))),
  )
end

## Whether a click at `cell` is the second of a double click.
def double?(app: State.Model, cell: Select.Cell) -> Bool
  case app.click
    some(before) -> before.cell == cell and app.now - before.at_ms <= Select.DOUBLE_MS
    none -> false
  end
end

## The word at `cell` is selected and copied.
def double(app: State.Model, cell: Select.Cell) -> State.Model
  lines = Transcript.tail(app.entries, app.width, State.folds(app), cell.row + 1)
  case Select.word_at(lines, cell)
    some(word) -> copied(app.with(selection: some(word), click: none))
    none -> app.with(click: none)
  end
end

private

def lowered(cell: Select.Cell, rows: Int) -> Select.Cell = Select.Cell(row: cell.row + rows, col: cell.col)
