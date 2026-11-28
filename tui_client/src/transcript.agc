## What the transcript holds and the lines it draws in a given width. Pure.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import Calls from "calls"
import Markdown from "markdown"
import Width from "width"

## Every row starts one column in.
INDENT = " "
## The gutter of a user message: one more column than other rows, so the tinted block reads indented like a bubble.
USER_INDENT = "  "

enum Kind
  User
  Assistant
  Thinking
  Notice
  ## A tool call that runs, ran well or failed.
  ToolRunning
  Tool
  ToolFailed
end

## What the entries show unless a click opened or closed one: the thinking blocks, the bodies of the tool calls.
struct Folds
  thinking: Bool = false
  tools: Bool = false
  ## The names of the keys that show them, for the hints of the folded rows.
  thinking_key: String = "^T"
  tools_key: String = "^O"
end

struct Entry
  kind: Kind
  text: String
  ## The id of a tool call and the call.
  call_id: String = ""
  call: Optional[Calls.Call] = none
  ## The child session whose call it is; none for a call of the session itself. Two children may use the same call
  ## id, so a call is keyed by both.
  session: Optional[String] = none
  ## A click opened or closed the entry (a thinking block, a tool call); none follows the default.
  open: Optional[Bool] = none
  ## The rows of the entry for the width and folds they were cut for; a change of the entry drops them.
  wrapped: Optional[Wrapped] = none
end

## One drawn row of the transcript.
struct Line
  kind: Kind
  spans: List[Markdown.Span]
  ## The index of the entry it draws, -1 for the row between two entries.
  entry: Int = -1
  ## How the row goes on from the one before (`Markdown.JOIN_NEW`, `JOIN_SPACE` or `JOIN_DIRECT`).
  join: Int = 0
  ## The columns of indent after the gutter that are not part of the text (a continued list item).
  indent: Int = 0
end

## A row of a wrapped text, and how it goes on from the one before.
struct Cut
  text: String
  join: Int
end

struct Wrapped
  width: Int
  folds: Folds
  lines: List[Line]
end

def from_history(messages: List[Protocol.Message]) -> List[Entry]
  entries: List[Entry] = []
  for message in messages
    entries = from_message(entries, message)
  end

  entries
end

## How a turn that did not end as asked is noted, live or in the history; none for one that did.
def stop_note(done: Protocol.TurnFinished) -> Optional[String]
  note = Client.stop_note(done)
  case done.stop_reason
    Protocol.StopReason.EndTurn -> none
    Protocol.StopReason.Cancelled -> some("stopped")
    _ if not note.empty? -> some(note)
    _ -> some("the turn ended: #{Protocol.stop_reason_name(done.stop_reason)}")
  end
end

## Adds `text`: a streamed kind (the answer, the thinking) goes on the end of the last entry when it is of that kind.
def add(entries: List[Entry], kind: Kind, text: String) -> List[Entry]
  streamed = kind == Kind.Assistant or kind == Kind.Thinking
  if streamed and not entries.empty? and entries.last.kind == kind
    last = entries.last
    return entries.take(entries.size - 1).push(last.with(text: last.text + text, wrapped: none))
  end

  entries.push(Entry(kind: kind, text: text))
end

def note(entries: List[Entry], text: String) -> List[Entry] = entries.push(Entry(kind: Kind.Notice, text: text))

## A tool call starts: its entry at the end, or in place of the one of the same call of the same session (a replay).
## A child's call goes under the open `agent` call that started it, when exactly one runs; with none or several
## running it goes at the end, still named by its child. Concurrent or async children can never be tied to a call
## reliably, so they keep their own labelled group instead of joining a call that may not be theirs.
def tool_started(entries: List[Entry], started: Protocol.ToolStarted) -> List[Entry]
  call = Calls.Call(name: started.name, target: started.summary)
  entry = Entry(kind: Kind.ToolRunning, text: "", call_id: started.call_id, call: some(call), session: started.session)

  case found(entries, started.call_id, started.session)
    some(at) -> entries.set(at, entry.with(open: entries[at].open))
    none -> nested(entries, entry)
  end
end

## A tool call ends: its entry shows how, with its output and diff, `aside` after them, and its duration when `timed`.
def tool_finished(
  entries: List[Entry],
  done: Protocol.ToolFinished,
  aside: String = "",
  timed: Bool = true,
) -> List[Entry]
  state = Calls.State.Failed
  kind = Kind.ToolFailed
  if done.ok
    state = Calls.State.Done
    kind = Kind.Tool
  end

  base = Entry(
    kind: kind,
    text: "",
    call_id: done.call_id,
    call: some(Calls.Call(name: "", target: done.summary)),
    session: done.session,
  )

  at = found(entries, done.call_id, done.session)
  if at.some?
    base = entries[at.unwrap!].with(kind: kind, wrapped: none)
  end

  call = (
    base.call
      .unwrap_or(Calls.Call(name: "", target: done.summary))
      .with(
        state: state,
        summary: done.summary,
        output: done.output.unwrap_or(""),
        diff: done.diff.unwrap_or(""),
        duration_ms: done.duration_ms,
        aside: aside,
        timed: timed,
      )
  )

  entry = base.with(call: some(call))
  case at
    some(index) -> entries.set(index, entry)
    none -> entries.push(entry)
  end
end

## Opens or closes the entry at `index` when it is a thinking block or a finished tool call.
def toggle(entries: List[Entry], index: Int, folds: Folds) -> List[Entry]
  return entries if index < 0 or index >= entries.size

  entry = entries[index]
  if entry.kind == Kind.Thinking
    return entries.set(index, entry.with(open: some(not open?(entry, folds.thinking)), wrapped: none))
  end

  return entries if entry.kind != Kind.Tool and entry.kind != Kind.ToolFailed

  entries.set(index, entry.with(open: some(not open?(entry, folds.tools)), wrapped: none))
end

## The thinking blocks follow the folds again (after ^T).
def unfold_thinking(entries: List[Entry]) -> List[Entry] = entries.map { |entry| unfolded(entry, Kind.Thinking) }

## The tool calls follow the folds again (after ^O).
def unfold_tools(entries: List[Entry]) -> List[Entry]
  entries.map { |entry| unfolded(unfolded(entry, Kind.Tool), Kind.ToolFailed) }
end

## The entries as rows of at most `width` columns, an empty row between two entries that have rows; the answers as
## markdown, and the thinking only when `thinking`.
def lines(entries: List[Entry], width: Int, folds: Folds) -> List[Line]
  rows: List[Line] = []
  for index in 0...entries.size
    drawn = entry_rows(entries[index], index, width, folds)
    next if drawn.empty?

    if not rows.empty?
      rows = rows.push(Line(kind: entries[index].kind, spans: []))
    end

    rows = rows + drawn
  end

  rows
end

## How many rows `lines` has, without making them again when they are kept.
def size(entries: List[Entry], width: Int, folds: Folds) -> Int
  total = 0
  for index in 0...entries.size
    rows = entry_rows(entries[index], index, width, folds).size
    next if rows == 0

    if total > 0
      total = total + 1
    end

    total = total + rows
  end

  total
end

## The last `count` rows of `lines` (all of them when there are fewer), cutting only the entries they reach.
def tail(entries: List[Entry], width: Int, folds: Folds, count: Int) -> List[Line]
  parts: List[List[Line]] = []
  size = 0
  # The kind of the entry after, which the empty row between takes.
  after: Optional[Kind] = none
  index = entries.size - 1
  while index >= 0 and size < count
    drawn = entry_rows(entries[index], index, width, folds)
    if not drawn.empty?
      case after
        some(kind) ->
          parts = parts.push([Line(kind: kind, spans: [])])
          size = size + 1
        none -> nil
      end

      drawn = drawn.drop([drawn.size - (count - size), 0].max.unwrap!)
      parts = parts.push(drawn)
      size = size + drawn.size
      after = some(entries[index].kind)
    end

    index = index - 1
  end

  parts.reverse.flat_map { |rows| rows }
end

## The entries with their rows cut for `width` and `folds`, so that `lines` and `tail` cut only what changed.
def wrapped(entries: List[Entry], width: Int, folds: Folds) -> List[Entry]
  return entries if entries.all? { |entry| fresh?(entry, width, folds) }

  (0...entries.size).to_a.map do |index|
    entry = entries[index]
    cut = Wrapped(width: width, folds: folds, lines: entry_rows(entry, index, width, folds))
    entry.with(wrapped: some(cut))
  end
end

## `text` cut into rows of at most `width` columns, at spaces when it can.
def wrap(text: String, width: Int) -> List[String] = wrap_marked(text, width).map { |row| row.text }

def wrap_marked(text: String, width: Int) -> List[Cut]
  rows: List[Cut] = []
  for paragraph in text.split("\n")
    rows = rows + wrap_paragraph(paragraph, [width, 1].max.unwrap!)
  end

  rows
end

private

# A message of the history drawn as it was live: a thinking block, a tool call with its end, or how the turn ended.
def from_message(entries: List[Entry], message: Protocol.Message) -> List[Entry]
  return entries.push(Entry(kind: Kind.Thinking, text: message.text)) if message.thinking

  case message.tool
    some(started) ->
      running = tool_started(entries, started)
      return message.done.map { |done| tool_finished(running, done) }.unwrap_or(running)
    none -> nil
  end

  case message.stop
    some(done) -> return stop_note(done).map { |text| note(entries, text) }.unwrap_or(entries)
    none -> nil
  end

  case message.role
    Protocol.Role.User -> entries.push(Entry(kind: Kind.User, text: message.text))
    Protocol.Role.Assistant -> entries.push(Entry(kind: Kind.Assistant, text: message.text))
  end
end

def found(entries: List[Entry], call_id: String, session: Optional[String]) -> Optional[Int]
  return none if call_id == ""

  entries.find_index { |e| e.call_id == call_id and e.session == session }
end

## Where a new call entry goes: under the open `agent` call that started it when exactly one runs, else at the end.
def nested(entries: List[Entry], entry: Entry) -> List[Entry]
  return entries.push(entry) if entry.session.none?

  open: List[Int] = []
  for index in 0...entries.size
    current = entries[index]
    if current.kind == Kind.ToolRunning and current.session.none? and parent_call?(current.call)
      open = open.push(index)
    end
  end

  return entries.push(entry) if open.size != 1

  at = open[0]
  entries.take(at + 1) + [entry] + entries.drop(at + 1)
end

## Whether `call` is an open `agent` call of the session itself, which a child's call nests under.
def parent_call?(call: Optional[Calls.Call]) -> Bool
  for started in option_list(call)
    return ["agent", "agent_send", "agent_stop"].include?(started.name)
  end

  false
end

def unfolded(entry: Entry, kind: Kind) -> Entry
  return entry if entry.kind != kind

  entry.with(open: none, wrapped: none)
end

# Only a thinking block draws differently with `folds.thinking`, and only a tool call with `folds.tools`.
def fresh?(entry: Entry, width: Int, folds: Folds) -> Bool
  case entry.wrapped
    some(cut) ->
      cut.width == width and folded(entry, cut.folds) == folded(entry, folds) and same_keys?(cut.folds, folds)
    none -> false
  end
end

def same_keys?(a: Folds, b: Folds) -> Bool = a.thinking_key == b.thinking_key and a.tools_key == b.tools_key

def folded(entry: Entry, folds: Folds) -> Bool
  case entry.kind
    Kind.Thinking -> folds.thinking
    Kind.Tool -> folds.tools
    Kind.ToolFailed -> folds.tools
    _ -> false
  end
end

def entry_rows(entry: Entry, index: Int, width: Int, folds: Folds) -> List[Line]
  return entry.wrapped.unwrap!.lines if fresh?(entry, width, folds)

  entry_lines(entry, width, folds).map { |line| line.with(entry: index) }
end

def open?(entry: Entry, default: Bool) -> Bool = entry.open.unwrap_or(default)

def entry_lines(entry: Entry, width: Int, folds: Folds) -> List[Line]
  if entry.kind == Kind.Thinking and not open?(entry, folds.thinking)
    return [
      Line(
        kind: entry.kind,
        spans: [
          Markdown.Span(
            text: "#{INDENT}▸ thinking (click or #{folds.thinking_key} shows it)",
            look: Markdown.Look.Plain,
          ),
        ],
      ),
    ]
  end

  for call in option_list(entry.call)
    return Calls.rows(call, width, open?(entry, folds.tools), folds.tools_key, entry.session).map { |spans|
      Line(kind: entry.kind, spans: spans)
    }
  end

  if entry.kind == Kind.Assistant
    # An answer that only called tools has no text and no row.
    return [] if entry.text.strip == ""

    lead = Markdown.Span(text: INDENT, look: Markdown.Look.Plain)
    rows = Markdown.marked(entry.text, width - INDENT.length)
    return rows.map { |row| Line(kind: entry.kind, spans: [lead] + row.spans, join: row.join, indent: row.indent) }
  end

  gutter = INDENT
  extra = 0
  if entry.kind == Kind.User
    gutter = USER_INDENT
    # The columns past `Select.GUTTER` that a copy leaves out with the gutter.
    extra = 1
  end

  wrap_marked(entry.text, width - gutter.length).map do |row|
    Line(
      kind: entry.kind,
      spans: [Markdown.Span(text: gutter + row.text, look: Markdown.Look.Plain)],
      join: row.join,
      indent: extra,
    )
  end
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end

def wrap_paragraph(paragraph: String, width: Int) -> List[Cut]
  rows: List[Cut] = []
  row = ""
  join = Markdown.JOIN_NEW
  for word in paragraph.split(" ")
    candidate = word
    if row != ""
      candidate = "#{row} #{word}"
    end

    if Width.text(candidate) <= width
      row = candidate
    else
      if row != ""
        rows = rows.push(Cut(text: row, join: join))
        join = Markdown.JOIN_SPACE
      end

      row = word
      while Width.text(row) > width
        parts = Width.cut(row, width)
        if parts[0] == ""
          parts = [row.slice(0, 1), row.slice(1, row.length - 1)]
        end

        rows = rows.push(Cut(text: parts[0], join: join))
        join = Markdown.JOIN_DIRECT
        row = parts[1]
      end
    end
  end

  rows.push(Cut(text: row, join: join))
end
