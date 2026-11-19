## The side panel: local output that is not part of the conversation (the server log, the help, the report of a reload)
## in a column of its own, beside the transcript on a wide screen and over it on a narrow one. It scrolls by itself and
## has its own focus. Pure.

import Client from "pkg/client/client"
import Layout from "panel"
import Transcript from "transcript"
import Width from "width"

## The screen width from which the panel sits beside the transcript; narrower, it takes the transcript's place.
WIDE = 100
MIN_COLUMNS = 40
MAX_COLUMNS = 80

struct Side
  title: String
  lines: List[String]
  ## The lines cut to the width the panel has (`wrapped_at`), so that a draw cuts nothing.
  wrapped: List[String] = []
  wrapped_at: Int = 0
  ## The first row shown while the panel does not follow the end.
  top: Int = 0
  ## The panel shows the end of its lines as they grow.
  follow: Bool = false
  ## The last lines of the server log to read again as the panel lives (the log), none for output that does not change.
  live: Optional[Int] = none
  ## The keys scroll the panel and Esc closes it, not the transcript's.
  focused: Bool = true
  ## One line after the lines, for what went wrong (the log could not be read).
  note: String = ""
end

## A panel of fixed `lines`, shown from the top.
def of(title: String, lines: List[String]) -> Side = Side(title: title, lines: lines)

## The server log: its last `count` lines, followed as they come.
def log(lines: List[String], count: Int) -> Side
  Side(title: "Server log", lines: lines, follow: true, live: some(count))
end

## Whether the keys are for the panel: it has the focus, or it covers the transcript.
def active?(side: Side, screen_width: Int) -> Bool = side.focused or not wide?(screen_width)

## Whether a screen of `width` columns has the panel beside the transcript.
def wide?(width: Int) -> Bool = width >= WIDE

## The columns of the panel on a screen of `width`: the whole width when narrow.
def columns(width: Int) -> Int
  return width if not wide?(width)

  [[(width * 2) / 5, MIN_COLUMNS].max.unwrap!, MAX_COLUMNS].min.unwrap!
end

## The columns of the app (transcript, prompt and footer) on a screen of `width` when the panel is `open`: the panel and
## the column between them are taken off on a wide screen.
def left(width: Int, open: Bool) -> Int
  return width if not open or not wide?(width)

  width - columns(width) - 1
end

## The panel with its lines cut for `width` columns, when they are not yet.
def fitted(side: Side, width: Int) -> Side
  return side if side.wrapped_at == width

  noted = side.lines
  if side.note != ""
    noted = noted.push(side.note)
  end

  side.with(wrapped: noted.flat_map { |line| Transcript.wrap(line, width) }, wrapped_at: width)
end

## The panel with `lines` in place of its own, cut for its width again.
def replaced(side: Side, lines: List[String]) -> Side
  fitted(side.with(lines: lines, note: "", wrapped_at: 0), side.wrapped_at)
end

## The panel with `note` after its lines.
def noted(side: Side, note: String) -> Side = fitted(side.with(note: note, wrapped_at: 0), side.wrapped_at)

## The first row shown in `room` rows.
def first(side: Side, room: Int) -> Int
  last = [side.wrapped.size - room, 0].max.unwrap!
  return last if side.follow

  [side.top, last].min.unwrap!
end

## The panel moved `rows` down (up when negative). A live panel follows its end again once it gets there.
def scrolled(side: Side, rows: Int, room: Int) -> Side
  last = [side.wrapped.size - room, 0].max.unwrap!
  moved = [[first(side, room) + rows, 0].max.unwrap!, last].min.unwrap!
  side.with(top: moved, follow: side.live.some? and moved == last)
end

## The rows of the panel in `width` columns and `height` rows: the title, then the lines, padded to the width.
def rows(side: Side, width: Int, height: Int, wide: Bool, keys: Client.Bindings) -> List[Layout.Row]
  return [] if height <= 0 or width <= 0

  room = height - 1
  at = first(side, room)
  look = Layout.Look.Plain
  if side.focused
    look = Layout.Look.Selected
  end

  shown = side.wrapped.drop(at).take(room)
  body = shown.map { |text| Layout.Row(text: padded(text, width)) }
  blank = (shown.size...room).to_a.map { |_| Layout.Row(text: " " * width) }
  [Layout.Row(text: padded(title(side, room, at, wide, keys), width), look: look)] + body + blank
end

private

# The title with what the panel does: its state, and the keys.
def title(side: Side, room: Int, at: Int, wide: Bool, keys: Client.Bindings) -> String
  state = ""
  if side.live.some? and side.follow
    state = " · following"
  end

  if side.live.some? and not side.follow
    state = " · paused, #{label(keys, "page_down")} to the end follows"
  end

  if not side.live.some? and side.wrapped.size > room
    state = " · #{at + 1}-#{[at + room, side.wrapped.size].min.unwrap!} of #{side.wrapped.size}"
  end

  focus = ""
  if wide
    focus = " · #{label(keys, "side_focus")} focus"
  end

  " #{side.title}#{state} · Esc closes#{focus} · #{label(keys, "page_up")}/#{label(keys, "page_down")} scroll"
end

def label(keys: Client.Bindings, action: String) -> String = Client.label(Client.key_of(keys, action))

def padded(text: String, width: Int) -> String
  cut = Width.cut(text, width)[0]
  "#{cut}#{" " * [width - Width.text(cut), 0].max.unwrap!}"
end
