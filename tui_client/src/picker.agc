## The session picker of `/resume`: the sessions newest first, one row each with its id, folder, model, last change
## and first message. Up and Down (or the wheel) move, typing filters, Enter picks, Esc closes. Pure.

import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import Layout from "panel"
import Width from "width"

KEYS = ["↑↓ move", "Enter resume", "Esc close", "type to filter"]

struct Picker
  sessions: List[Protocol.SessionSummary]
  filter: String = ""
  ## The index in `shown`.
  selected: Int = 0
end

## What a key did to the picker.
enum Step
  Stay(Picker)
  Pick(String)
  Close
end

def key(picker: Picker, event: TUI.Event) -> Step
  case event
    TUI.Event.Key(TUI.Key.Up, _) -> Step.Stay(moved(picker, -1))
    TUI.Event.Key(TUI.Key.Down, _) -> Step.Stay(moved(picker, 1))
    TUI.Event.Mouse(TUI.Mouse.WheelUp, _, _, _) -> Step.Stay(moved(picker, -1))
    TUI.Event.Mouse(TUI.Mouse.WheelDown, _, _, _) -> Step.Stay(moved(picker, 1))
    TUI.Event.Key(TUI.Key.Escape, _) -> Step.Close
    TUI.Event.Key(TUI.Key.Enter, _) -> picked(picker)
    TUI.Event.Key(TUI.Key.Backspace, _) ->
      Step.Stay(picker.with(filter: picker.filter.slice(0, [picker.filter.length - 1, 0].max.unwrap!), selected: 0))
    TUI.Event.Char(c, _) -> Step.Stay(picker.with(filter: picker.filter + c, selected: 0))
    _ -> Step.Stay(picker)
  end
end

## The sessions the filter keeps: it is found in the id, folder, model or first message, in any case.
def shown(picker: Picker) -> List[Protocol.SessionSummary]
  wanted = picker.filter.downcase
  picker.sessions.select { |s| [s.id, s.cwd, s.model, s.title].join(" ").downcase.include?(wanted) }
end

## The picker in at most `room` rows; the selected session stays in sight. `now_s` dates the last changes.
def rows(picker: Picker, width: Int, room: Int, now_s: Int) -> List[Layout.Row]
  found = shown(picker)
  head = "resume a session (#{found.size} of #{picker.sessions.size})"
  if picker.filter != ""
    head = "#{head} · filter: #{picker.filter}"
  end

  body = ->(left: Int) {
    window(found, picker.selected, left).map { |i| row(found[i], i == picker.selected, width, now_s) }
  }

  Layout.fit(head, KEYS.map { |label| Layout.Key(label: label) }, body, width, room)
end

## How long ago `then_s` was, in the largest unit: "now", "5m", "3h", "2d".
def ago(now_s: Int, then_s: Int) -> String
  seconds = [now_s - then_s, 0].max.unwrap!
  return "now" if seconds < 60
  return "#{seconds / 60}m" if seconds < 3600
  return "#{seconds / 3600}h" if seconds < 86400

  "#{seconds / 86400}d"
end

private

def moved(picker: Picker, by: Int) -> Picker
  last = [shown(picker).size - 1, 0].max.unwrap!
  picker.with(selected: [[picker.selected + by, 0].max.unwrap!, last].min.unwrap!)
end

def picked(picker: Picker) -> Step
  found = shown(picker)
  return Step.Stay(picker) if found.empty?

  Step.Pick(found[picker.selected].id)
end

# The indexes of the rows in sight: from the top, or ending at the selected one.
def window(found: List[Protocol.SessionSummary], selected: Int, left: Int) -> List[Int]
  return [] if left <= 0

  first = [selected - left + 1, 0].max.unwrap!
  (first...[first + left, found.size].min.unwrap!).to_a
end

def row(session: Protocol.SessionSummary, selected: Bool, width: Int, now_s: Int) -> Layout.Row
  mark = "  "
  style = TUI.Style()
  if selected
    mark = "› "
    style = TUI.Style(attrs: [TUI.Attr.Reverse])
  end

  title = session.title.split("\n")[0]
  text = "#{mark}#{session.id}  #{session.cwd}  #{session.model}  #{ago(now_s, session.updated_s)}  #{title}"
  Layout.Row(text: Width.cut(text, width)[0], style: style)
end
