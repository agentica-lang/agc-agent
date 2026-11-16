import Protocol from "pkg/protocol/protocol"
import Store from "../src/store"
import H from "support/harness"

# After a restart the session is listed and drawn as before; a client that saw all but the last events gets just those,
# and the next turn's ids follow the old ones. The model gets the old history back, tool call included. A line that a
# crash cut is skipped, and the next record starts on a line of its own.
def test_a_restarted_server_resumes_a_session_with_its_event_ids() -> Result[Void]
  setup = H.Setup(replies: ["write_file.sse", "text.sse", "text.sse"])
  H.using(setup) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    before = try H.session(h, id)
    try Test.eq(a.seen.size, before.last_event_id)
    try Test.eq((try File.stat(H.sessions(h))).mode % 512, 448)
    try Test.eq((try File.stat(H.session_file(h, id))).mode % 512, 384)
    H.restarted(h, setup, "{\"type\":\"event\",\"id\":99,\"na") do |r|
      listed = try Protocol.decode_session_list((try H.get(r, Protocol.SESSIONS_PATH)).text)
      try Test.eq(listed.sessions.map { |s| s.id }, [id])
      after = try H.session(r, id)
      try Test.eq([after.last_event_id, after.history.size], [before.last_event_id, 2])
      try Test.eq(after.history, before.history)
      tail = a.seen.drop(a.seen.size - 3)
      b = try H.until(try H.subscribe(r, id, some(before.last_event_id - 3)), Protocol.EventKind.TurnFinished)
      H.close(b)
      try Test.eq(b.seen.map { |s| s.id }, tail.map { |s| s.id })
      try Test.eq(b.seen.map { |s| s.event }, tail.map { |s| s.event })
      c = try H.subscribe(r, id, some(before.last_event_id))
      sent = try H.send(r, id, "Hello.")
      try Test.eq((try Protocol.decode_message_accepted(sent.text)).turn_id, "turn-2")
      c = try H.until(c, Protocol.EventKind.TurnFinished)
      H.close(c)
      first = before.last_event_id + 1
      try Test.eq(c.seen.map { |s| s.id }, (first...(first + c.seen.size)).map { |n| Protocol.format_event_id(n) })
      second = try H.request_messages(r, 2)
      third = try H.request_messages(r, 1)
      try Test.eq(third.map { |m| JSON.encode(JSON.get(m, "role").unwrap_or(JSON.null())) }.join(" "), roles())
      try Test.eq(third.take(4).map { |m| JSON.encode(m) }, second.map { |m| JSON.encode(m) })
      saved = try Store.load(H.session_file(r, id))
      try Test.eq([saved.skipped, saved.events.size], [1, (try H.session(r, id)).last_event_id])
      Test.eq((try File.stat(H.sessions(r))).mode % 512, 448)
    end
  end
end

# A turn that waited for an approval when the server stopped ends after the restart: the approval is denied and the
# turn is cancelled, with the next ids; a late answer to it is told it came late. A new turn runs after it, and its
# approval is the next one.
def test_a_turn_cut_by_a_restart_ends_cancelled() -> Result[Void]
  setup = H.Setup(replies: ["write_file.sse", "write_file.sse", "text.sse"])
  H.using(setup) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    H.close(a)
    before = try H.session(h, id)
    try Test.eq(before.turn_id, some("turn-1"))
    H.restarted(h, setup, "") do |r|
      after = try H.session(r, id)
      try Test.eq([after.turn_id.some?, after.turn_from_event_id.some?], [false, false])
      try Test.eq([after.last_event_id, after.pending_approvals.size], [before.last_event_id + 2, 0])
      b = try H.until(try H.subscribe(r, id, some(before.last_event_id)), Protocol.EventKind.TurnFinished)
      try Test.eq(H.kinds(b.seen), ["approval_resolved", "turn_finished"])
      try Test.eq([H.resolved_by(b), [H.stop_reason(b)]], [["deny stop"], ["cancelled"]])
      late = try H.approve(r, id, "a1", Protocol.Decision.Allow)
      try Test.eq(
        [late.status.to_s, (try Protocol.decode_failure(late.text)).kind],
        ["409", Protocol.KIND_APPROVAL_RESOLVED],
      )

      sent = try H.send(r, id, "Write it again.")
      try Test.eq((try Protocol.decode_message_accepted(sent.text)).turn_id, "turn-2")
      b = try H.until(b.with(seen: []), Protocol.EventKind.ApprovalRequested)
      try Test.eq((try H.approval(b)).approval_id, "a2")
      _ = try H.approve(r, id, "a2", Protocol.Decision.Deny)
      b = try H.until(b, Protocol.EventKind.TurnFinished)
      H.close(b)
      try Test.eq(H.stop_reason(b), "end_turn")
      Test.eq(File.stat("#{r.work}/hello.txt").ok?, false)
    end
  end
end

# A write that fails gives no id: the clients get an `error` and the end of the turn without one (a client keeps the
# last id it saw), and no turn starts
# until the file can be written again. After a restart the ids go on from the last saved one, never twice.
def test_a_failed_write_stops_the_turn_and_reuses_no_id() -> Result[Void]
  setup = H.Setup(replies: ["write_file.sse", "text.sse", "text.sse"])
  H.using(setup) do |h|
    id = try H.new_session(h)
    file = H.session_file(h, id)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    saved_last = (try H.session(h, id)).last_event_id
    try chmod("400", file)
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    unsaved = a.seen.drop(a.seen.size - 2)
    no_id = Protocol.format_event_id(saved_last)
    try Test.eq([H.kinds(unsaved), unsaved.map { |s| s.id }], [["error", "turn_finished"], [no_id, no_id]])
    try Test.eq(H.stop_reason(a), "cancelled")
    snapshot = try H.session(h, id)
    try Test.eq([snapshot.turn_id.some?, snapshot.last_event_id == saved_last], [false, true])
    refused = try H.send(h, id, "Hello.")
    try Test.eq(
      [refused.status.to_s, (try Protocol.decode_failure(refused.text)).kind],
      ["500", Protocol.KIND_SESSION_STORAGE],
    )

    try chmod("600", file)
    sent = try H.send(h, id, "Hello.")
    try Test.eq((try Protocol.decode_message_accepted(sent.text)).turn_id, "turn-2")
    a = try H.until(a.with(seen: []), Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(a.seen.first.id, Protocol.format_event_id(saved_last + 1))
    last = (try H.session(h, id)).last_event_id
    H.restarted(h, setup, "") do |r|
      after = try H.session(r, id)
      try Test.eq(after.last_event_id, last)
      Test.eq(after.history.map { |m| m.text }.select { |t| t == "Hello." }.size, 1)
    end
  end
end

private

def chmod(mode: String, path: String) -> Result[Void]
  code = try H.run("chmod", [mode, path])
  return error("chmod failed") if code != 0

  ok()
end

def roles() -> String
  ["system", "user", "assistant", "tool", "assistant", "user"].map { |r| JSON.encode(r) }.join(" ")
end
