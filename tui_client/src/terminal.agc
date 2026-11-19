## What the full screen writes to the terminal outside the grid it draws: the copy to the clipboard and the mouse
## reporting; and `guarded`, the terminal that a drawing error cannot end. Pure, but for `write`.

import TUI from "pkg/tui/tui"

ESC = String.from_code(27)
BEL = String.from_code(7)

## The sequence that sets the clipboard of the terminal to `text` (OSC 52), which works in local terminals, over SSH
## and in tmux with `set-clipboard on`.
def osc52(text: String) -> String = "#{ESC}]52;c;#{Base64.strict_encode64(text.bytes)}#{BEL}"

## The sequences that turn the mouse reporting of the terminal off and on, as termbox2 sets it (button events, SGR).
def mouse(on: Bool) -> String
  mode = "l"
  if on
    mode = "h"
  end

  "#{ESC}[?1000#{mode}#{ESC}[?1002#{mode}#{ESC}[?1006#{mode}"
end

## Writes to the terminal.
def write(text: String) -> Void
  print(text)
  IO.flush()
end

## `backend` whose draw never fails on a cell off the screen: the cells outside the size it has now are dropped. A
## resize can still land between the size read and the writes (the reader task takes it while the loop draws); the
## write that termbox2 then refuses is no failure either, because the `Resize` event that comes with it draws all again.
def guarded(backend: TUI.Backend) -> TUI.Backend = backend.with(draw: ->(cells) { drawn(backend, cells) })

private

OUT_OF_BOUNDS = "Out of bounds"

def drawn(backend: TUI.Backend, cells: List[TUI.Cell]) -> Result[Void]
  width = backend.width.call()
  height = backend.height.call()
  inside = cells.select { |cell| cell.x >= 0 and cell.y >= 0 and cell.x < width and cell.y < height }
  case backend.draw.call(inside)
    error(e) if not e.message.include?(OUT_OF_BOUNDS) -> error(e)
    _ -> ok()
  end
end
