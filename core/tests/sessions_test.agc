import Protocol from "pkg/protocol/protocol"
import H from "support/harness"

# After a restart the session is listed and drawn as before; a client that saw all but the last events gets just those,
# and the next turn's ids follow the old ones. The model gets the old history back, tool call included.
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
    H.restarted(h, setup) do |r|
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
      Test.eq(third.take(4).map { |m| JSON.encode(m) }, second.map { |m| JSON.encode(m) })
    end
  end
end

# A turn that waited for an approval when the server stopped ends after the restart: the approval is denied and the
# turn is cancelled, with the next ids. A new turn runs after it.
def test_a_turn_cut_by_a_restart_ends_cancelled() -> Result[Void]
  setup = H.Setup(replies: ["write_file.sse", "text.sse"])
  H.using(setup) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    H.close(a)
    before = try H.session(h, id)
    try Test.eq(before.turn_id, some("turn-1"))
    H.restarted(h, setup) do |r|
      after = try H.session(r, id)
      try Test.eq([after.turn_id.some?, after.turn_from_event_id.some?], [false, false])
      try Test.eq([after.last_event_id, after.pending_approvals.size], [before.last_event_id + 2, 0])
      b = try H.until(try H.subscribe(r, id, some(before.last_event_id)), Protocol.EventKind.TurnFinished)
      try Test.eq(H.kinds(b.seen), ["approval_resolved", "turn_finished"])
      try Test.eq([H.resolved_by(b), [H.stop_reason(b)]], [["deny stop"], ["cancelled"]])
      sent = try H.send(r, id, "Hello.")
      try Test.eq((try Protocol.decode_message_accepted(sent.text)).turn_id, "turn-2")
      b = try H.until(b.with(seen: []), Protocol.EventKind.TurnFinished)
      H.close(b)
      try Test.eq(H.stop_reason(b), "end_turn")
      Test.eq(File.stat("#{r.work}/hello.txt").ok?, false)
    end
  end
end

private

def roles() -> String
  ["system", "user", "assistant", "tool", "assistant", "user"].map { |r| JSON.encode(r) }.join(" ")
end
