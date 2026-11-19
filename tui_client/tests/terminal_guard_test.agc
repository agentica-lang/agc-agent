import TUI from "pkg/tui/tui"
import Terminal from "../src/terminal"

OUT_OF_BOUNDS = "tui: set_cell failed: Out of bounds (-9)"

# A terminal that says it is `width` by `height` and draws as termbox2 does on a screen of `real` columns by rows: a
# cell off it is an error. `drawn` gets the cells of each draw.
def terminal(width: Int, height: Int, real: List[Int], drawn: Channel[List[TUI.Cell]]) -> TUI.Backend
  base = TUI.Testing.backend(TUI.Testing.fake(width, height))
  base.with(
    draw: ->(cells: List[TUI.Cell]) {
      _ = drawn.send(cells, 0)
      off = cells.any? { |c| c.x < 0 or c.y < 0 or c.x >= real[0] or c.y >= real[1] }
      return error(OUT_OF_BOUNDS) if off

      ok()
    },
  )
end

def cell(x: Int, y: Int) -> TUI.Cell = TUI.Cell(x: x, y: y, char: "x", style: TUI.Style())

def test_a_cell_off_the_screen_is_dropped_and_the_others_are_drawn() -> Result[Void]
  drawn: Channel[List[TUI.Cell]] = Channel.new(4)
  guarded = Terminal.guarded(terminal(10, 4, [10, 4], drawn))
  try guarded.draw.call([cell(-1, 0), cell(0, -3), cell(10, 0), cell(3, 4), cell(2, 2), cell(9, 3)])
  Test.eq((try drawn.recv(0)).map { |c| [c.x, c.y] }, [[2, 2], [9, 3]])
end

# The reader takes a resize between the size read and the writes: the screen is smaller than the size read.
def test_a_resize_between_the_size_and_the_draw_is_no_failure() -> Result[Void]
  drawn: Channel[List[TUI.Cell]] = Channel.new(4)
  guarded = Terminal.guarded(terminal(20, 6, [10, 4], drawn))
  try guarded.draw.call([cell(1, 1), cell(15, 5)])
  Test.eq((try drawn.recv(0)).size, 2)
end

def test_another_drawing_error_still_ends_the_program() -> Result[Void]
  base = TUI.Testing.backend(TUI.Testing.fake(10, 4))
  guarded = Terminal.guarded(
    base.with(draw: ->(_cells: List[TUI.Cell]) { error("tui: set_cell failed: No memory (-1)") }),
  )

  Test.error?(guarded.draw.call([cell(1, 1)]))
end
