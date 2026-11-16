## The picker of `/resume`, `/tree` and `/fork`: the sessions newest first, one row each with its id, folder, model,
## last change and first message; or the messages of the session's tree, a branch a step in. Up and Down (or the
## wheel) move, typing filters, Enter picks, Esc closes. Pure.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import Layout from "panel"
import Prompt from "prompt"
import Width from "width"

KEYS = ["↑↓ move", "Enter resume", "Esc close", "type to filter"]

## What the picker lists: the sessions, the messages and answers of the tree (a message picks going back before it,
## an answer going on after it), or the messages of the tree to fork from.
enum Kind
  Sessions
  Tree
  Fork
end

struct Picker
  sessions: List[Protocol.SessionSummary] = []
  tree: List[Client.TreeRow] = []
  kind: Kind = Kind.Sessions
  filter: String = ""
  ## The index in `shown`.
  selected: Int = 0
end

## A row to pick: `key` is what `Step.Pick` gives (a session id, or an entry of the tree), `search` what the filter
## looks in.
struct Choice
  key: String
  search: String
  text: String
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

## The rows the filter keeps, in any case: of a session its id, folder, model or first message; of the tree the text.
## `now_s` dates the last changes of the sessions.
def shown(picker: Picker, now_s: Int = 0) -> List[Choice]
  wanted = picker.filter.downcase
  choices(picker, now_s).select { |c| c.search.downcase.include?(wanted) }
end

## The picker in at most `room` rows; the selected row stays in sight.
def rows(picker: Picker, width: Int, room: Int, now_s: Int) -> List[Layout.Row]
  found = shown(picker, now_s)
  head = "#{title(picker.kind)} (#{found.size} of #{choices(picker, now_s).size})"
  if picker.filter != ""
    head = "#{head} · filter: #{picker.filter}"
  end

  body = ->(left: Int) { window(found, picker.selected, left).map { |i| row(found[i], i == picker.selected, width) } }

  Layout.fit(head, keys(picker.kind).map { |label| Layout.Key(label: label) }, body, width, room)
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

  Step.Pick(found[picker.selected].key)
end

def title(kind: Kind) -> String
  case kind
    Kind.Sessions -> "resume a session"
    Kind.Tree -> "go back to a message, or on after an answer"
    Kind.Fork -> "fork a new session from a message"
  end
end

def keys(kind: Kind) -> List[String]
  case kind
    Kind.Sessions -> KEYS
    Kind.Tree -> ["↑↓ move", "Enter go there", "Esc close", "type to filter"]
    Kind.Fork -> ["↑↓ move", "Enter fork", "Esc close", "type to filter"]
  end
end

def choices(picker: Picker, now_s: Int) -> List[Choice]
  case picker.kind
    Kind.Sessions -> picker.sessions.map { |s| session_choice(s, now_s) }
    Kind.Tree -> (0...picker.tree.size).to_a.flat_map { |i| tree_choices(picker.tree[i], i + 1, true) }
    Kind.Fork -> (0...picker.tree.size).to_a.flat_map { |i| tree_choices(picker.tree[i], i + 1, false) }
  end
end

def session_choice(session: Protocol.SessionSummary, now_s: Int) -> Choice
  title = session.title.split("\n")[0]
  Choice(
    key: session.id,
    search: [session.id, session.cwd, session.model, session.title].join(" "),
    text: "#{session.id}  #{session.cwd}  #{session.model}  #{ago(now_s, session.updated_s)}  #{title}",
  )
end

# A message with its number (as `/tree N` takes it), `*` on the branch the session is on; with `answers`, its answer
# under it.
def tree_choices(row: Client.TreeRow, number: Int, answers: Bool) -> List[Choice]
  node = row.node
  indent = Client.tree_indent(row)
  mark = "  "
  if node.active
    mark = "* "
  end

  message = Client.printable(node.text.split("\n")[0])
  label = "#{number}. "
  said = Choice(key: node.id.to_s, search: node.text, text: "#{label}#{indent}#{mark}#{message}")
  return [said] if not answers or node.answer.empty?

  answer = Client.printable(node.answer.split("\n")[0])
  pad = " " * label.length
  [said, Choice(key: node.last.to_s, search: node.answer, text: "#{pad}#{"  " * row.depth}    → #{answer}")]
end

# The indexes of the rows in sight: from the top, or ending at the selected one.
def window(found: List[Choice], selected: Int, left: Int) -> List[Int]
  return [] if left <= 0

  first = [selected - left + 1, 0].max.unwrap!
  (first...[first + left, found.size].min.unwrap!).to_a
end

def row(choice: Choice, selected: Bool, width: Int) -> Layout.Row
  mark = "  "
  look = Layout.Look.Plain
  if selected
    mark = "› "
    look = Layout.Look.Selected
  end

  Layout.Row(text: Width.cut("#{mark}#{choice.text}", width)[0], look: look)
end
