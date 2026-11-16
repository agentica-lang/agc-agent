import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import Approvals from "../src/approvals"
import Layout from "../src/panel"

AFTER = 1000 + Approvals.GUARD_MS

def test_only_ctrl_keys_or_a_focused_panel_answer() -> Result[Void]
  panel = asked(["a1"])
  for typed in "pay".split("")
    try Test.eq(Approvals.decision(panel, char(typed), AFTER, true), none)
    try Test.eq(Approvals.captures?(panel, char(typed)), false)
  end

  try Test.eq(Approvals.decision(panel, ctrl("a"), AFTER, true), none)
  try Test.eq(Approvals.captures?(panel, ctrl("a")), false)
  try Test.eq(Approvals.decision(panel, ctrl("y"), AFTER, false), none)
  try Test.eq(Approvals.decision(panel, ctrl("y"), AFTER, true), some(Protocol.Decision.Allow))
  try Test.eq(Approvals.decision(panel, ctrl("n"), AFTER, true), some(Protocol.Decision.Deny))
  focused = Approvals.toggled(panel, 1000)
  try Test.eq(Approvals.decision(focused, char("Y"), AFTER, true), some(Protocol.Decision.Allow))
  try Test.eq(Approvals.decision(focused, char("N"), AFTER, true), some(Protocol.Decision.Deny))
  try Test.eq(Approvals.decision(focused, char("a"), AFTER, true), some(Protocol.Decision.AllowSession))
  try Test.eq(Approvals.decision(focused, char("A"), AFTER, true), some(Protocol.Decision.AllowSession))
  try Test.eq(Approvals.decision(focused, char("p"), AFTER, true), none)
  try Test.eq(Approvals.captures?(focused, char("p")), true)
  Test.eq(Approvals.decision(Approvals.sending(focused), char("y"), AFTER, true), none)
end

# A key typed just as the asked approval changes does not answer the new one, and the focus does not carry over.
def test_no_answer_right_after_the_panel_changes() -> Result[Void]
  focused = Approvals.toggled(asked(["a1", "a2"]), 1000)
  try Test.eq(Approvals.decision(focused, ctrl("y"), 1000 + Approvals.GUARD_MS - 1, true), none)
  next_one = Approvals.resolved(focused, "a1", 5000)
  try Test.eq([next_one.pending.size.to_s, next_one.focused.to_s], ["1", "false"])
  try Test.eq(Approvals.decision(next_one, ctrl("y"), 5000 + Approvals.GUARD_MS - 1, true), none)
  Test.eq(Approvals.decision(next_one, ctrl("y"), 5000 + Approvals.GUARD_MS, true), some(Protocol.Decision.Allow))
end

def test_a_request_seen_twice_is_asked_once_and_a_resync_rebuilds_the_list() -> Result[Void]
  panel = Approvals.requested(asked(["a1"]), request("a1", ""), 2000)
  try Test.eq(panel.pending.map { |p| p.approval_id }, ["a1"])
  try Test.eq(panel.shown_at, 1000)
  rebuilt = Approvals.replaced(panel, [request("a2", ""), request("a3", "")], 3000)
  try Test.eq(rebuilt.pending.map { |p| p.approval_id }, ["a2", "a3"])
  try Test.eq(rebuilt.shown_at, 3000)
  Test.eq(Approvals.resolved(Approvals.resolved(rebuilt, "a2", 4000), "a3", 4000).pending, [])
end

# The reply to an answer: an approval another client answered first is dropped with a note; a failed send keeps it.
def test_the_reply_to_an_answer() -> Result[Void]
  panel = Approvals.sending(asked(["a1"]))
  try Test.eq(Approvals.answered(panel, "a1", ok(), AFTER).panel.pending, [])
  for kind in [Protocol.KIND_APPROVAL_RESOLVED, Protocol.KIND_APPROVAL_NOT_FOUND]
    late = Approvals.answered(panel, "a1", error("late", kind: kind), AFTER)
    try Test.eq([late.panel.pending.size.to_s, late.note.unwrap_or("")], ["0", "approval a1 was already answered"])
  end

  failed = Approvals.answered(panel, "a1", error("down", kind: "client.http"), AFTER)
  try Test.eq(failed.panel.pending.size, 1)
  try Test.eq(failed.panel.answering, none)
  Test.eq(failed.note, some("error: the answer was not sent: down"))
end

def test_the_panel_caps_its_detail_and_fits_the_room() -> Result[Void]
  long = (1..25).map { |n| "+line #{n}" }.join("\n")
  panel = Approvals.Panel(pending: [request("a1", long), request("a2", ""), request("a3", "")])
  rows = texts(Approvals.rows(panel, 200, 100))
  try Test.eq(rows.size, 1 + Approvals.MAX_DETAIL_ROWS + 1)
  try Test.eq(rows[1], "  +line 1")
  try Test.eq(rows[Approvals.MAX_DETAIL_ROWS], "  … 16 more lines")
  try Test.assert(rows[rows.size - 1].end_with?(" · 2 more waiting"), rows[rows.size - 1])
  try Test.assert(
    rows[rows.size - 1].include?("a: allow write_file on this exact target for the session"),
    rows[rows.size - 1],
  )

  small = texts(Approvals.rows(panel, 200, 4))
  try Test.eq(small.size, 4)
  try Test.eq(small[2], "  … 24 more lines")
  try Test.assert(small[3].start_with?("^Y allow · ^N deny · Tab to answer"), small[3])
  try Test.eq(texts(Approvals.rows(panel, 200, 1)).size, 1)
  try Test.eq(Approvals.rows(panel, 200, 0), [])
  narrow = Approvals.rows(panel, 12, 3)
  Test.eq(narrow.size, 3)
end

# A click on a key of the panel stands for that key, so it goes through the same rules.
# Only the keys row has buttons; text of the request that looks like a key ("a = 1", "^Y please") is none. Allowing
# for the session has no button, and the focus toggle restarts the guard time, so a double click on Tab never gives it.
def test_only_the_keys_row_has_buttons() -> Result[Void]
  panel = Approvals.Panel(pending: [request("a1", "a = 1\n^Y please")], shown_at: 1000)
  rows = Approvals.rows(panel, 200, 100)
  try Test.eq(rows.take(rows.size - 1).map { |row| row.buttons.size }.uniq, [0])
  keys = rows[rows.size - 1]
  try Test.eq(keys.text.start_with?("^Y allow · ^N deny · Tab to answer"), true)
  try Test.eq(Layout.hit(keys, 0), some(ctrl_plain("y")))
  try Test.eq(Layout.hit(keys, 11), some(ctrl_plain("n")))
  try Test.eq(Layout.hit(keys, 8), none)
  try Test.eq(Layout.hit(keys, 25), some(TUI.Event.Key(TUI.Key.Tab, TUI.Mods())))
  focused = Approvals.toggled(panel, 5000)
  try Test.eq(Approvals.decision(focused, char("y"), 5000 + Approvals.GUARD_MS - 1, true), none)
  focused_rows = Approvals.rows(focused, 200, 100)
  for row in focused_rows
    try Test.eq(row.buttons.any? { |b| b.event == char("a") }, false)
  end

  Test.eq(Layout.hit(focused_rows[focused_rows.size - 1], 25), none)
end

private

def ctrl_plain(c: String) -> TUI.Event = TUI.Event.Key(TUI.Key.Ctrl(c), TUI.Mods())

def asked(ids: List[String]) -> Approvals.Panel
  panel = Approvals.Panel()
  for id in ids
    panel = Approvals.requested(panel, request(id, ""), 1000)
  end

  panel
end

def request(id: String, detail: String) -> Protocol.ApprovalRequested
  Protocol.ApprovalRequested(
    approval_id: id,
    call_id: "c-#{id}",
    tool: "write_file",
    preview: "hello.txt",
    detail: detail,
  )
end

def char(c: String) -> TUI.Event = TUI.Event.Char(c, TUI.Mods())

def ctrl(c: String) -> TUI.Event = TUI.Event.Key(TUI.Key.Ctrl(c), TUI.Mods(ctrl: true))

def texts(rows: List[Layout.Row]) -> List[String] = rows.map { |row| row.text }
