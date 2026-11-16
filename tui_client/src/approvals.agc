## The approvals that wait and the panel that asks the first one. Its keys are modal, so typing never answers by
## accident: Ctrl+Y and Ctrl+N answer at once; y, n and a (allow for the session) only after Tab focuses the panel. No
## key answers in the first GUARD_MS after the asked approval changes, nor while the panel has no row on the screen.
## Pure.

import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import Transcript from "transcript"
import Width from "width"

GUARD_MS = 300
MAX_DETAIL_ROWS = 10

struct Panel
  ## The first one is asked.
  pending: List[Protocol.ApprovalRequested] = []
  ## Tab focused the panel: y, n and a answer.
  focused: Bool = false
  ## When the asked approval last changed, in monotonic ms.
  shown_at: Int = 0
  ## The approval whose answer is being sent.
  answering: Optional[String] = none
end

struct Row
  text: String
  style: TUI.Style
end

## A panel after an answer was sent, and the note to show.
struct Outcome
  panel: Panel
  note: Optional[String] = none
end

def requested(panel: Panel, request: Protocol.ApprovalRequested, now: Int) -> Panel
  return panel if (panel.pending.any? { |p| p.approval_id == request.approval_id })

  changed(panel, panel.pending.push(request), now)
end

def resolved(panel: Panel, approval_id: String, now: Int) -> Panel
  changed(panel, panel.pending.select { |p| p.approval_id != approval_id }, now)
end

## The pending approvals as a snapshot of the session gives them.
def replaced(panel: Panel, pending: List[Protocol.ApprovalRequested], now: Int) -> Panel = changed(panel, pending, now)

## Tab focuses the panel or gives the keys back to the prompt.
def toggled(panel: Panel) -> Panel
  return panel if panel.pending.empty?

  panel.with(focused: not panel.focused)
end

## The answer a key gives, none when the key does not answer now. `shown` says whether the panel has rows on the
## screen.
def decision(panel: Panel, event: TUI.Event, now: Int, shown: Bool) -> Optional[Protocol.Decision]
  return none if not shown or panel.pending.empty? or panel.answering.some? or now - panel.shown_at < GUARD_MS

  case event
    TUI.Event.Key(TUI.Key.Ctrl(c), _) -> shortcut(c)
    TUI.Event.Char(c, _) if panel.focused -> letter(c)
    _ -> none
  end
end

## Whether a key belongs to the panel, so it does not reach the prompt.
def captures?(panel: Panel, event: TUI.Event) -> Bool
  return false if panel.pending.empty?

  case event
    TUI.Event.Char(_, _) -> panel.focused
    TUI.Event.Key(TUI.Key.Ctrl(c), _) -> shortcut(c).some?
    _ -> false
  end
end

## The answer of the first approval is being sent.
def sending(panel: Panel) -> Panel = panel.with(answering: some(panel.pending[0].approval_id))

## The reply to an answer. Another client may have answered first: that is not a failure. An answer that was not sent
## leaves the approval pending.
def answered(panel: Panel, approval_id: String, result: Result[Void], now: Int) -> Outcome
  done = panel.with(answering: none)
  case result
    ok(_) -> Outcome(panel: resolved(done, approval_id, now))
    error(e) if e.kind == Protocol.KIND_APPROVAL_RESOLVED or e.kind == Protocol.KIND_APPROVAL_NOT_FOUND ->
      Outcome(panel: resolved(done, approval_id, now), note: some("approval #{approval_id} was already answered"))
    error(e) -> Outcome(panel: done, note: some("error: the answer was not sent: #{e.message}"))
  end
end

## The panel in at most `room` rows: what the call is, what it would write (MAX_DETAIL_ROWS at most), and the keys.
## The keys stay when rows are cut; the detail goes first, then the head.
def rows(panel: Panel, width: Int, room: Int) -> List[Row]
  return [] if panel.pending.empty? or room <= 0

  request = panel.pending[0]
  strong = TUI.Style(fg: TUI.Color.Yellow, attrs: [TUI.Attr.Bold])
  keys = Transcript.wrap(keys_text(panel), width).map { |text| Row(text: text, style: strong) }
  keys = keys.drop([keys.size - room, 0].max.unwrap!)
  left = room - keys.size
  head = Transcript.wrap("approval #{request.approval_id} · #{request.tool}: #{request.preview}", width)
  head_rows = head.take(left).map { |text| Row(text: text, style: strong) }
  left = left - head_rows.size
  detail_rows = detail(request.detail, width, [left, MAX_DETAIL_ROWS].min.unwrap!)
  head_rows + detail_rows + keys
end

private

def changed(panel: Panel, pending: List[Protocol.ApprovalRequested], now: Int) -> Panel
  before = panel.pending.take(1).map { |p| p.approval_id }
  after = pending.take(1).map { |p| p.approval_id }
  return panel.with(pending: pending) if after == before

  panel.with(pending: pending, focused: false, shown_at: now, answering: none)
end

# No Ctrl+A: a pasted 0x01 byte must not allow a tool for the session.
def shortcut(c: String) -> Optional[Protocol.Decision]
  case c
    "y" -> some(Protocol.Decision.Allow)
    "n" -> some(Protocol.Decision.Deny)
    _ -> none
  end
end

def letter(c: String) -> Optional[Protocol.Decision]
  case c.downcase
    "y" -> some(Protocol.Decision.Allow)
    "n" -> some(Protocol.Decision.Deny)
    "a" -> some(Protocol.Decision.AllowSession)
    _ -> none
  end
end

def keys_text(panel: Panel) -> String
  request = panel.pending[0]
  session = "allow #{request.tool} on this exact target for the session"
  more = ""
  if panel.pending.size > 1
    more = " · #{panel.pending.size - 1} more waiting"
  end

  return "sending the answer…#{more}" if panel.answering.some?
  return "y allow · n deny · a #{session} · Tab back to the prompt#{more}" if panel.focused

  "Tab to answer (a: #{session}) · ^Y allow · ^N deny#{more}"
end

def detail(text: String, width: Int, room: Int) -> List[Row]
  lines = text.split("\n").select { |line| line != "" }
  return [] if room <= 0

  shown = lines
  if lines.size > room
    shown = lines.take(room - 1)
  end

  rows = shown.map { |line| Row(text: Width.cut("  #{line}", width)[0], style: detail_style(line)) }
  return rows if shown.size == lines.size

  rows.push(Row(text: Width.cut("  … #{lines.size - shown.size} more lines", width)[0], style: TUI.Style()))
end

def detail_style(line: String) -> TUI.Style
  return TUI.Style(fg: TUI.Color.Red) if line.start_with?("-")
  return TUI.Style(fg: TUI.Color.Green) if line.start_with?("+")

  TUI.Style()
end
