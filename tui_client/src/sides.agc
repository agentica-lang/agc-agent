## What the app does with the side panel: opens it with some output, closes it, scrolls it, gives it the focus, and reads
## the server log again while it follows it. The layout (how many columns each side has) is `Side`'s; the model keeps
## the width of the screen and `width` the columns of what is beside the panel.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import Side from "side"
import State from "state"
import Views from "views"

## How often the open server log is read again.
LOG_MS = 1000

## `side` is open with the focus: local output goes here, not to the transcript.
def shown(app: State.Model, side: Side.Side) -> State.Model
  resized(
    app.with(side: some(side), reading_side: false, side_serial: app.side_serial + 1, mcp: none),
    app.screen_width,
    app.height,
  )
end

## The panel is closed and the app has the whole width again.
def closed(app: State.Model) -> State.Model
  resized(app.with(side: none, reading_side: false, mcp: none), app.screen_width, app.height)
end

## The screen is `width` by `height`: the app takes the columns the panel leaves, and the panel is cut again for its own.
## The selection, the press and the click were about the old rows.
def resized(app: State.Model, width: Int, height: Int) -> State.Model
  columns = Side.left(width, app.side.some?)
  fit(app.with(screen_width: width, width: columns, height: height, selection: none, pressed: none, click: none))
end

## The panel cut for the columns it has now.
def fit(app: State.Model) -> State.Model
  case app.side
    some(side) -> app.with(side: some(Side.fitted(side, Side.columns(app.screen_width))))
    none -> app
  end
end

## The panel is open and the keys are for it: it has the focus, or it covers the transcript.
def active?(app: State.Model) -> Bool
  case app.side
    some(side) -> Side.active?(side, app.screen_width)
    none -> false
  end
end

## Whether column `x` is the panel's or the column before it, on a wide screen with the panel open.
def beside?(app: State.Model, x: Int) -> Bool = app.side.some? and Side.wide?(app.screen_width) and x >= app.width

## Whether a wheel at column `x` is for the panel: beside the app, or anywhere when the panel covers the transcript.
def over?(app: State.Model, x: Int) -> Bool
  return false if app.side.none?

  beside?(app, x) or not Side.wide?(app.screen_width)
end

## The panel scrolled by a page (`pages` of them, up when negative).
def paged(app: State.Model, pages: Int) -> State.Model = moved(app, pages * [room(app) - 1, 1].max.unwrap!)

## The panel scrolled by `rows`.
def moved(app: State.Model, rows: Int) -> State.Model
  case app.side
    some(side) -> app.with(side: some(Side.scrolled(side, rows, room(app))))
    none -> app
  end
end

## The panel scrolled so that its line `index` shows.
def revealed(app: State.Model, index: Int) -> State.Model
  case app.side
    some(side) -> app.with(side: some(Side.revealed(side, index, room(app))))
    none -> app
  end
end

## F6: the keys go to the other side of a wide screen; a narrow one has only the panel.
def toggled_focus(app: State.Model) -> State.Model
  case app.side
    some(side) if Side.wide?(app.screen_width) -> app.with(side: some(side.with(focused: not side.focused)))
    _ -> app
  end
end

## A press of the left button: on a wide screen the focus goes to the side it is on.
def focused_by(app: State.Model, event: TUI.Event) -> State.Model
  case event
    TUI.Event.Mouse(TUI.Mouse.Left, x, _, mods) if not mods.motion ->
      case app.side
        some(side) if Side.wide?(app.screen_width) -> app.with(side: some(side.with(focused: beside?(app, x))))
        _ -> app
      end

    _ -> app
  end
end

## Ctrl+P: the panel closes when it is open, else it opens on the server log.
def toggled(app: State.Model) -> State.Model
  return closed(app) if app.side.some?

  logs(app, Client.DEFAULT_LOG_LINES)
end

## The last `count` lines of the server log in the panel, which follows it.
def logs(app: State.Model, count: Int) -> State.Model
  case app.backend.server_log.call(count)
    ok(log) -> shown(app, Side.log(log.lines.map { |line| Client.printable(line) }, count))
    error(e) -> State.noted(app, "error: #{e.message}")
  end
end

## The panel follows a log that is open: the next read of it, when none is on its way.
def tick(app: State.Model) -> State.Model
  return app if app.reading_side

  case app.side
    some(side) if side.follow ->
      backend = app.backend
      serial = app.side_serial
      count = side.live.unwrap_or(Client.DEFAULT_LOG_LINES)
      State.effect(
        app.with(reading_side: true),
        TUI.Cmd.Run(-> { State.Msg.LogRead(serial, backend.server_log.call(count)) }),
      )
    _ -> app
  end
end

## The lines the server log has now, or a line that says why they were not read. A panel that was scrolled away from its
## end keeps what it shows, and one whose lines did not change is not cut again.
def read(app: State.Model, serial: Int, result: Result[Protocol.ServerLog]) -> State.Model
  return app if serial != app.side_serial

  idle = app.with(reading_side: false)
  for side in State.option_list(idle.side)
    return idle if not side.follow

    case result
      ok(log) ->
        lines = log.lines.map { |line| Client.printable(line) }
        return idle if lines == side.lines and side.note == ""

        return idle.with(side: some(Side.replaced(side, lines)))
      error(e) ->
        note = "log not read: #{Client.printable(e.message)}"
        return idle if side.note == note

        return idle.with(side: some(Side.noted(side, note)))
    end
  end

  idle
end

## Whether the panel reads the server log again.
def live?(app: State.Model) -> Bool
  case app.side
    some(side) -> side.live.some?
    none -> false
  end
end

private

# The rows of the panel that show lines: the title takes one.
def room(app: State.Model) -> Int = Views.side_rows(app) - 1
