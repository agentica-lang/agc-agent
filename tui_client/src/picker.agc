## The pickers over the prompt: the sessions of `/resume` (newest first, one row each with its id, folder, model, last
## change and first message) and the `provider/model` pairs of `/model`. Up and Down (or the wheel) move, typing
## filters, Enter picks, Esc closes. Pure.

import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import Layout from "panel"
import Prompt from "prompt"
import Width from "width"

## What a pick does.
enum Purpose
  Resume
  Model
end

## A row to pick: `id` is what a pick gives, `text` what the row shows and the filter searches.
struct Item
  id: String
  text: String
end

struct Picker
  purpose: Purpose
  items: List[Item]
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
    TUI.Event.Char(c, _) -> Step.Stay(filtered(picker, c))
    TUI.Event.Paste(text) -> Step.Stay(filtered(picker, Prompt.pasted(text).replace("\n", " ").replace("\t", " ")))
    _ -> Step.Stay(picker)
  end
end

## The picker of `/resume`; `now_s` dates the last changes.
def sessions(list: List[Protocol.SessionSummary], now_s: Int) -> Picker
  Picker(purpose: Purpose.Resume, items: list.map { |s| Item(id: s.id, text: session_text(s, now_s)) })
end

## The picker of `/model`: every model of every provider, as `provider/model`, on the one in use.
def models(list: Protocol.ProviderList, current: String) -> Picker
  ids = list.providers.flat_map { |p| p.models.map { |m| "#{p.name}/#{m}" } }
  selected = ids.index(current).unwrap_or(0)
  Picker(purpose: Purpose.Model, items: ids.map { |id| Item(id: id, text: id) }, selected: selected)
end

## The items the filter keeps: it is found in their text, in any case.
def shown(picker: Picker) -> List[Item]
  wanted = picker.filter.downcase
  picker.items.select { |item| item.text.downcase.include?(wanted) }
end

## The keys the panel shows.
def keys(purpose: Purpose) -> List[String]
  verb = case purpose
    Purpose.Resume -> "resume"
    Purpose.Model -> "use"
  end

  ["↑↓ move", "Enter #{verb}", "Esc close", "type to filter"]
end

## The picker in at most `room` rows; the selected item stays in sight.
def rows(picker: Picker, width: Int, room: Int) -> List[Layout.Row]
  found = shown(picker)
  title = case picker.purpose
    Purpose.Resume -> "resume a session"
    Purpose.Model -> "pick a model"
  end

  head = "#{title} (#{found.size} of #{picker.items.size})"
  if picker.filter != ""
    head = "#{head} · filter: #{picker.filter}"
  end

  body = ->(left: Int) { window(found, picker.selected, left).map { |i| row(found[i], i == picker.selected, width) } }

  Layout.fit(head, keys(picker.purpose).map { |label| Layout.Key(label: label) }, body, width, room)
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

def filtered(picker: Picker, more: String) -> Picker = picker.with(filter: picker.filter + more, selected: 0)

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
def window(found: List[Item], selected: Int, left: Int) -> List[Int]
  return [] if left <= 0

  first = [selected - left + 1, 0].max.unwrap!
  (first...[first + left, found.size].min.unwrap!).to_a
end

def row(item: Item, selected: Bool, width: Int) -> Layout.Row
  mark = "  "
  look = Layout.Look.Plain
  if selected
    mark = "› "
    look = Layout.Look.Selected
  end

  Layout.Row(text: Width.cut("#{mark}#{item.text}", width)[0], look: look)
end

def session_text(session: Protocol.SessionSummary, now_s: Int) -> String
  title = session.title.split("\n")[0]
  "#{session.id}  #{session.cwd}  #{session.model}  #{ago(now_s, session.updated_s)}  #{title}"
end
