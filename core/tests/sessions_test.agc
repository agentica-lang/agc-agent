import Protocol from "pkg/protocol/protocol"
import Store from "../src/store"
import H from "support/harness"

# After a restart the session is listed and drawn as before; a client that saw all but the last events gets just those,
# one that would miss text deltas (they are not saved) gets `resync`, and the next turn's ids follow the old ones. The
# model gets the old history back, tool call included. A line that a
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
      tail = a.seen.drop(a.seen.size - 2)
      try Test.eq(H.kinds(tail), ["usage", "turn_finished"])
      b = try H.until(try H.subscribe(r, id, some(before.last_event_id - 2)), Protocol.EventKind.TurnFinished)
      H.close(b)
      try Test.eq(b.seen.map { |s| s.id }, tail.map { |s| s.id })
      try Test.eq(b.seen.map { |s| s.event }, tail.map { |s| s.event })
      delta = try a.seen.find { |s| Protocol.event_name(s.event) == "text_delta" }
      old = try H.until(try H.subscribe(r, id, some(try delta.id.to_i)), Protocol.EventKind.Resync)
      H.close(old)
      try Test.eq(H.kinds(old.seen), ["resync"])
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
      try Test.eq(saved.skipped, 1)
      try Test.eq(saved.events.map { |l| l.id }.max, some((try H.session(r, id)).last_event_id))
      try Test.eq(saved.events.select { |l| Protocol.event_name(l.event).end_with?("_delta") }.size, 0)
      try Test.assert((try File.read_text(H.session_file(r, id))).include?("{\"type\":\"ids\""), "no ids reserved")
      try Test.eq(saved.shown.map { |m| m.text }.select { |t| t == "Hello." }.size, 1)
      Test.eq((try File.stat(H.sessions(r))).mode % 512, 448)
    end
  end
end

# A turn that waited for its second approval when the server stopped ends after the restart: the waiting approval is
# denied, the answer the model gave so far is shown, and the turn is cancelled, with the next ids. Late answers to
# either approval are told they came late, and the next turn and approval get the next numbers.
def test_a_turn_cut_by_a_restart_ends_cancelled() -> Result[Void]
  setup = H.Setup(replies: ["long_text_then_write.sse", "write_file.sse", "write_file.sse", "text.sse"])
  H.using(setup) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write long.txt, then hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    _ = try H.approve(h, id, "a1", Protocol.Decision.Allow)
    a = try H.until(a.with(seen: []), Protocol.EventKind.ApprovalRequested)
    try Test.eq((try H.approval(a)).approval_id, "a2")
    H.close(a)
    before = try H.session(h, id)
    try Test.eq(before.turn_id, some("turn-1"))
    H.restarted(h, setup, "") do |r|
      after = try H.session(r, id)
      try Test.eq([after.turn_id.some?, after.turn_from_event_id.some?], [false, false])
      try Test.eq([after.last_event_id, after.pending_approvals.size], [before.last_event_id + 2, 0])
      try Test.eq(after.history.map { |m| Protocol.role_name(m.role) }, ["user", "assistant"])
      try Test.assert(after.history[1].text.start_with?("word0 "), "the answer so far is not shown")
      b = try H.until(try H.subscribe(r, id, some(before.last_event_id)), Protocol.EventKind.TurnFinished)
      try Test.eq(H.kinds(b.seen), ["approval_resolved", "turn_finished"])
      try Test.eq([H.resolved_by(b), [H.stop_reason(b)]], [["deny stop"], ["cancelled"]])
      for approval_id in ["a1", "a2"]
        late = try H.approve(r, id, approval_id, Protocol.Decision.Allow)
        try Test.eq(
          [late.status.to_s, (try Protocol.decode_failure(late.text)).kind],
          ["409", Protocol.KIND_APPROVAL_RESOLVED],
        )
      end

      sent = try H.send(r, id, "Write it again.")
      try Test.eq((try Protocol.decode_message_accepted(sent.text)).turn_id, "turn-2")
      b = try H.until(b.with(seen: []), Protocol.EventKind.ApprovalRequested)
      try Test.eq((try H.approval(b)).approval_id, "a3")
      _ = try H.approve(r, id, "a3", Protocol.Decision.Deny)
      b = try H.until(b, Protocol.EventKind.TurnFinished)
      H.close(b)
      try Test.eq(H.stop_reason(b), "end_turn")
      Test.eq(File.stat("#{r.work}/hello.txt").ok?, false)
    end
  end
end

# The server stopped between the user message of a turn and its `turn_started`: that turn ends cancelled, with ids,
# and the next one gets the next number.
def test_a_turn_cut_before_it_started_ends_cancelled() -> Result[Void]
  setup = H.Setup(replies: ["text.sse", "text.sse"])
  H.using(setup) do |h|
    id = try H.new_session(h)
    _ = try H.send(h, id, "Hello.")
    before = try H.idle(h, id)
    H.restarted(h, setup, "{\"type\":\"user\",\"text\":\"two\"}\n") do |r|
      after = try H.session(r, id)
      try Test.eq(after.last_event_id, before.last_event_id + 2)
      try Test.eq(after.history.map { |m| m.text }.drop(2), ["two"])
      b = try H.until(try H.subscribe(r, id, some(before.last_event_id)), Protocol.EventKind.TurnFinished)
      try Test.eq(H.kinds(b.seen), ["turn_started", "turn_finished"])
      started = Protocol.TurnStarted(turn_id: "turn-2", history_size: some(3))
      try Test.eq(b.seen[0].event, Protocol.Event.TurnStarted(started))
      try Test.eq(H.stop_reason(b), "cancelled")
      try Test.eq(history_size(b.seen.last), some(3))
      sent = try H.send(r, id, "three")
      try Test.eq((try Protocol.decode_message_accepted(sent.text)).turn_id, "turn-3")
      b = try H.until(b.with(seen: []), Protocol.EventKind.TurnFinished)
      H.close(b)
      try Test.eq(history_size(b.seen[0]), some(4))
      try Test.eq(history_size(b.seen.last), some((try H.session(r, id)).history.size))
      Test.eq(H.stop_reason(b), "end_turn")
    end
  end
end

# The server stopped while deltas streamed after the last saved event: the file reserved their ids, so the restart
# gives no event one of them. A client that saw some deltas gets `resync`; one that saw them all gets the end of the
# cut turn.
def test_a_restart_after_unsaved_deltas_skips_their_ids() -> Result[Void]
  setup = H.Setup(replies: ["text.sse", "text.sse"])
  H.using(setup) do |h|
    id = try H.new_session(h)
    _ = try H.send(h, id, "Hello.")
    last = (try H.idle(h, id)).last_event_id
    started = "{\"type\":\"event\",\"id\":#{last + 1},\"name\":\"turn_started\",\"data\":{\"turn_id\":\"turn-2\"}}"
    cut = "{\"type\":\"user\",\"text\":\"two\"}\n#{started}\n{\"type\":\"ids\",\"until\":#{last + 1000}}\n"
    H.restarted(h, setup, cut) do |r|
      try Test.eq((try H.session(r, id)).last_event_id, last + 1001)
      some_seen = try H.until(try H.subscribe(r, id, some(last + 500)), Protocol.EventKind.Resync)
      H.close(some_seen)
      all_seen = try H.until(try H.subscribe(r, id, some(last + 1000)), Protocol.EventKind.TurnFinished)
      try Test.eq(all_seen.seen.map { |s| s.id }, [Protocol.format_event_id(last + 1001)])
      try Test.eq(H.stop_reason(all_seen), "cancelled")
      sent = try H.send(r, id, "three")
      try Test.eq((try Protocol.decode_message_accepted(sent.text)).turn_id, "turn-3")
      all_seen = try H.until(all_seen.with(seen: []), Protocol.EventKind.TurnFinished)
      H.close(all_seen)
      Test.eq(all_seen.seen.first.id, Protocol.format_event_id(last + 1002))
    end
  end
end

# After a restart the sessions are listed from the first line of their files, in the order they were made (not of
# their ids); a session is loaded when it is first used (a turn the restart cut ends only then), and one that cannot
# be loaded now answers 503 and is tried again on the next request.
def test_a_session_is_loaded_when_first_used() -> Result[Void]
  setup = H.Setup(replies: ["write_file.sse"])
  H.using(setup) do |h|
    gone_cwd = "#{h.base}/gone"
    try Dir.mkdir(gone_cwd)
    id = try H.new_session(h)
    gone = try H.new_session_in(h, gone_cwd)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    H.close(a)
    try Path.remove(gone_cwd)
    file = H.session_file(h, id)
    late = (
      "{\"type\":\"session\",\"id\":\"a-late\",\"cwd\":\"#{h.work}\",\"model\":\"m\"," +
      "\"created_ms\":#{Time.now_ms + 1_000_000}}\n"
    )

    try File.write_text(H.session_file(h, "a-late"), late)
    H.restarted(h, setup, "") do |r|
      size = (try File.stat(file)).size_bytes
      listed = try Protocol.decode_session_list((try H.get(r, Protocol.SESSIONS_PATH)).text)
      try Test.eq(listed.sessions.map { |s| s.id }, [id, gone, "a-late"])
      try Test.eq((try File.stat(file)).size_bytes, size)
      try Test.eq((try H.session(r, id)).turn_id, none)
      try Test.assert((try File.stat(file)).size_bytes > size, "the cut turn did not end when the session loaded")
      unavailable = try H.get(r, Protocol.session_path(gone))
      try Test.eq(
        [unavailable.status.to_s, (try Protocol.decode_failure(unavailable.text)).kind],
        ["503", Protocol.KIND_SESSION_UNAVAILABLE],
      )

      after = try Protocol.decode_session_list((try H.get(r, Protocol.SESSIONS_PATH)).text)
      try Test.eq(after.sessions.map { |s| s.id }, [id, gone, "a-late"])
      try Dir.mkdir(gone_cwd)
      Test.eq((try H.get(r, Protocol.session_path(gone))).status, 200)
    end
  end
end

# A session is deleted with its file, but not while a turn runs; one whose file stays loads again; one not loaded
# since a restart is deleted too.
def test_a_session_is_deleted() -> Result[Void]
  setup = H.Setup(replies: ["write_file.sse", "text.sse"])
  H.using(setup) do |h|
    id = try H.new_session(h)
    other = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    busy = try H.call(h, "DELETE", Protocol.session_path(id), "", H.auth(h))
    try Test.eq([busy.status.to_s, (try Protocol.decode_failure(busy.text)).kind], ["409", Protocol.KIND_SESSION_BUSY])
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Deny)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    try Test.eq((try H.call(h, "DELETE", Protocol.session_path(id), "", H.auth(h))).status, 200)
    try Test.eq(File.stat(H.session_file(h, id)).ok?, false)
    try Test.eq((try H.get(h, Protocol.session_path(id))).status, 404)
    try Test.eq((try H.call(h, "DELETE", Protocol.session_path(id), "", H.auth(h))).status, 404)
    try Test.eq(a.stream.body.recv(5000).ok?, false)
    H.close(a)
    kept = try H.new_session(h)
    try chmod("500", H.sessions(h))
    failed = H.call(h, "DELETE", Protocol.session_path(kept), "", H.auth(h))
    try chmod("700", H.sessions(h))
    try Test.eq((try failed).status, 500)
    try Test.eq((try H.get(h, Protocol.session_path(kept))).status, 200)
    try Test.eq((try H.call(h, "DELETE", Protocol.session_path(kept), "", H.auth(h))).status, 200)
    H.restarted(h, setup, "") do |r|
      try Test.eq((try H.call(r, "DELETE", Protocol.session_path(other), "", H.auth(r))).status, 200)
      try Test.eq(File.stat(H.session_file(r, other)).ok?, false)
      listed = try Protocol.decode_session_list((try H.get(r, Protocol.SESSIONS_PATH)).text)
      Test.eq(listed.sessions.size, 0)
    end
  end
end

# One delta between two saved events is lost in a restart: a client from before it gets `resync`, one from it gets
# the rest.
def test_one_lost_delta_is_a_resync() -> Result[Void]
  setup = H.Setup(replies: ["summary.sse"])
  H.using(setup) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Hello.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(H.kinds(a.seen), ["turn_started", "text_delta", "usage", "turn_finished"])
    H.restarted(h, setup, "") do |r|
      before = try H.until(try H.subscribe(r, id, some(1)), Protocol.EventKind.Resync)
      H.close(before)
      try Test.eq(H.kinds(before.seen), ["resync"])
      rest = try H.until(try H.subscribe(r, id, some(2)), Protocol.EventKind.TurnFinished)
      H.close(rest)
      Test.eq(H.kinds(rest.seen), ["usage", "turn_finished"])
    end
  end
end

# A write that fails gives no id: the clients get an `error` and the end of the turn without one (a client keeps the
# last id it saw), and no turn starts until the file can be written again; a client whose replay passes the failure
# gets them too. A line the failed write left cut does not take the next record with it. After a restart the ids go on
# from the last saved one.
def test_a_failed_write_stops_the_turn_and_reuses_no_id() -> Result[Void]
  setup = H.Setup(replies: ["text.sse", "write_file.sse", "text.sse", "text.sse"])
  H.using(setup) do |h|
    id = try H.new_session(h)
    file = H.session_file(h, id)
    _ = try H.send(h, id, "Hi.")
    _ = try H.idle(h, id)
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

    late = try H.until(try H.subscribe(h, id, some(saved_last)), Protocol.EventKind.TurnFinished)
    H.close(late)
    try Test.eq(H.kinds(late.seen), ["error", "turn_finished"])
    early = try H.until(try H.subscribe(h, id, some(2)), Protocol.EventKind.Error)
    if H.kinds(early.seen).last != "turn_finished"
      early = try H.until(early, Protocol.EventKind.TurnFinished)
    end

    H.close(early)
    try Test.eq(H.kinds(early.seen.drop(early.seen.size - 3)), ["approval_requested", "error", "turn_finished"])
    try chmod("600", file)
    try File.append_text(file, "{\"type\":\"event\",\"id\":999,\"name\":\"text_de")
    sent = try H.send(h, id, "Hello.")
    try Test.eq((try Protocol.decode_message_accepted(sent.text)).turn_id, "turn-3")
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

def history_size(seen: H.Seen) -> Optional[Int]
  case seen.event
    Protocol.Event.TurnStarted(started) -> started.history_size
    Protocol.Event.TurnFinished(finished) -> finished.history_size
    _ -> none
  end
end
