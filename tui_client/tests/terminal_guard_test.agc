import TUI from "pkg/tui/tui"
import Client from "pkg/client/client"
import App from "../src/app"
import Args from "../src/args"
import Tty from "../src/terminal"

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
  guarded = Tty.guarded(terminal(10, 4, [10, 4], drawn))
  try guarded.draw.call([cell(-1, 0), cell(0, -3), cell(10, 0), cell(3, 4), cell(2, 2), cell(9, 3)])
  Test.eq((try drawn.recv(0)).map { |c| [c.x, c.y] }, [[2, 2], [9, 3]])
end

# The reader takes a resize between the size read and the writes: the screen is smaller than the size read.
def test_a_resize_between_the_size_and_the_draw_is_no_failure() -> Result[Void]
  drawn: Channel[List[TUI.Cell]] = Channel.new(4)
  guarded = Tty.guarded(terminal(20, 6, [10, 4], drawn))
  try guarded.draw.call([cell(1, 1), cell(15, 5)])
  Test.eq((try drawn.recv(0)).size, 2)
end

def test_another_drawing_error_still_ends_the_program() -> Result[Void]
  base = TUI.Testing.backend(TUI.Testing.fake(10, 4))
  guarded = Tty.guarded(base.with(draw: ->(_cells: List[TUI.Cell]) { error("tui: set_cell failed: No memory (-1)") }))

  Test.error?(guarded.draw.call([cell(1, 1)]))
end

# A terminal that is closed or suspended gives a negative size: the draw is not filtered, so its own error shows.
def test_a_negative_size_passes_the_cells_and_the_error_through() -> Result[Void]
  drawn: Channel[List[TUI.Cell]] = Channel.new(4)
  closed = terminal(10, 4, [10, 4], drawn).with(width: -> { -8 }, height: -> { -8 })
  guarded = Tty.guarded(
    closed.with(
      draw: ->(cells: List[TUI.Cell]) {
        _ = drawn.send(cells, 0)
        error("tui: set_cell failed: Not init (-8)")
      },
    ),
  )

  try Test.error?(guarded.draw.call([cell(-1, 0), cell(2, 2)]))
  Test.eq((try drawn.recv(0)).size, 2)
end

# Under the program: a resize lands in the middle of the first draw and the termbox2 write fails. The app keeps
# running, and the `Resize` that came with it draws the screen again at the new size.
def test_a_resize_that_cuts_a_draw_short_is_drawn_again_and_the_app_goes_on() -> Result[Void]
  fake = TUI.Testing.fake(20, 5)
  real = TUI.Testing.backend(fake)
  cut: Channel[Bool] = Channel.new(1)
  _ = cut.send(true, 0)
  cutting = real.with(
    draw: ->(cells: List[TUI.Cell]) {
      if cut.recv(0).ok?
        _ = TUI.Testing.resize(fake, 6, 3)
        return error(OUT_OF_BOUNDS)
      end

      real.draw.call(cells)
    },
  )

  options = Args.Options(
    state_dir: none,
    server_command: none,
    session: none,
    cwd: none,
    model: none,
    api: none,
    thinking: false,
  )

  # Nothing listens on the server: the app makes no call while it only draws.
  server = Client.Server(url: "http://127.0.0.1:1", token: "t")
  start = App.seed(Client.http_backend(server), options, Channel.new(1), 20, 5)
  runner = Task.spawn(-> { App.drive(cutting, start) })
  rows = TUI.Testing.wait_for(fake, ->(shown: List[String]) { shown.size == 3 and shown.any? { |r| r == "─" * 6 } })

  _ = fake.events.send(TUI.Event.Key(TUI.Key.Ctrl("c"), TUI.Mods()), 1000)
  outcome = Task.await(runner)
  try rows
  Test.eq(try outcome, 0)
end
