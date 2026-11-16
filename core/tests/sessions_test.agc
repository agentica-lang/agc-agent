import Protocol from "pkg/protocol/protocol"
import Store from "../src/session/store"
import H from "support/harness"

ROLES = "\"user\" \"assistant\" \"tool\" \"assistant\" \"user\""

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
      try Test.eq(number((try Protocol.decode_message_accepted(sent.text)).turn_id), "turn-2")
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

# A message sent while a turn runs is queued and read before the next model call, after the answer so far; it stays in
# the history after a restart. One queued when the turn is stopped is dropped with an error event.
def test_a_message_sent_during_a_turn_is_read_before_the_next_model_call() -> Result[Void]
  setup = H.Setup(replies: ["write_file.sse", "text.sse", "write_file.sse", "text.sse"])
  H.using(setup) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    queued = try H.send(h, id, "Also say hi.")
    accepted = try Protocol.decode_message_accepted(queued.text)
    try Test.eq([queued.status.to_s, number(accepted.turn_id)], ["202", "turn-1"])
    message_id = "#{accepted.turn_id}.1"
    try Test.eq(accepted.message_id, some(message_id))
    a = try H.until(a, Protocol.EventKind.MessageQueued)
    event = Protocol.MessageQueued(turn_id: accepted.turn_id, text: "Also say hi.", message_id: message_id)
    try Test.eq(a.seen.last.event, Protocol.Event.MessageQueued(event))
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    second = try H.request_messages(h, 2)
    try Test.eq(JSON.get(second.last, "role"), ok(JSON.from("user")))
    try Test.eq(JSON.get(second.last, "content"), ok(JSON.from("Also say hi.")))
    before = try H.session(h, id)
    texts = before.history.map { |m| "#{Protocol.role_name(m.role)}: #{m.text}" }
    try Test.eq(texts.take(3), ["user: Write hello.txt.", "assistant: I will write it.", "user: Also say hi."])
    try Test.eq(before.history.size, 4)
    _ = try H.send(h, id, "Write it again.")
    a = try H.until(a.with(seen: []), Protocol.EventKind.ApprovalRequested)
    _ = try H.send(h, id, "Never read.")
    try Test.eq((try H.post(h, Protocol.stop_path(id), "")).status, 200)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    dropped = a.seen.select do |s|
      case s.event
        Protocol.Event.Error(failure) -> failure.kind == Protocol.KIND_QUEUE_DROPPED
        _ -> false
      end
    end

    try Test.eq(dropped.size, 1)
    after_stop = try H.session(h, id)
    try Test.eq(after_stop.history.map { |m| m.text }.include?("Never read."), false)
    H.restarted(h, setup, "") do |r| Test.eq((try H.session(r, id)).history, after_stop.history) end
  end
end

# A message that comes while the final answer streams is read after it: the same turn calls the model again. Past 20
# messages, or past the size of one message together, the queue refuses with 409.
def test_the_queue_is_read_after_a_final_answer_and_has_a_limit() -> Result[Void]
  replies = ["text.sse@hold", "text.sse", "write_file.sse", "text.sse@hold", "text.sse"]
  H.using(H.Setup(replies: replies)) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Hi.")
    a = try H.until(a, Protocol.EventKind.TurnStarted)
    _ = try H.send(h, id, "More.")
    H.release(h)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    try Test.eq(H.kinds(a.seen).select { |k| k == "turn_started" }.size, 1)
    after = try H.session(h, id)
    try Test.eq([after.turn_id.some?.to_s, after.history.size.to_s], ["false", "4"])
    _ = try H.next_request(h)
    second = try H.request_messages(h, 1)
    try Test.eq(JSON.get(second.last, "content"), ok(JSON.from("More.")))
    try Test.eq(JSON.get(second[second.size - 2], "role"), ok(JSON.from("assistant")))
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a.with(seen: []), Protocol.EventKind.ApprovalRequested)
    H.close(a)
    statuses: List[String] = []
    for i in 1..21
      statuses = statuses.push((try H.send(h, id, "m#{i}")).status.to_s)
    end

    try Test.eq([statuses.take(20).uniq, statuses.drop(20)], [["202"], ["409"]])
    _ = try H.post(h, Protocol.stop_path(id), "")
    _ = try H.idle(h, id)
    a = try H.subscribe(h, id, some((try H.session(h, id)).last_event_id))
    _ = try H.send(h, id, "Long.")
    a = try H.until(a, Protocol.EventKind.TurnStarted)
    big = try H.send(h, id, "x" * 600_000)
    bigger = try H.send(h, id, "y" * 500_000)
    H.close(a)
    H.release(h)
    try Test.eq([big.status, bigger.status], [202, 409])
    shown = (try H.idle(h, id)).history.map { |m| m.text.size }
    Test.eq(shown.include?(600_000), true)
  end
end

# A turn that does not get its queue in time goes on without it: the messages stay queued and start the next turn,
# and the file agrees with the history, so a restart gives every tool call its result.
def test_a_late_read_leaves_the_queue_whole() -> Result[Void]
  setup = H.Setup(replies: ["write_file.sse", "text.sse", "text.sse", "text.sse"], take_ms: 0)
  H.using(setup) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    _ = try H.send(h, id, "Also say hi.")
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    a = try H.until(a.with(seen: []), Protocol.EventKind.TurnFinished)
    H.close(a)
    turns = a.seen.map { |s| s.event }.flat_map do |event|
      case event
        Protocol.Event.TurnStarted(started) -> [started.turn_id]
        _ -> []
      end
    end

    try Test.eq(turns.map { |t| number(t) }, ["turn-2"])
    _ = try H.next_request(h)
    _ = try H.next_request(h)
    third = try H.request_messages(h, 1)
    try Test.eq(third.map { |m| JSON.encode(JSON.get(m, "role").unwrap_or(JSON.null())) }.drop(1).join(" "), ROLES)
    before = try H.session(h, id)
    H.restarted(h, setup, "") do |r|
      _ = try H.send(r, id, "Again.")
      _ = try H.idle(r, id)
      again = try H.request_messages(r, 1)
      try Test.eq(again.take(third.size), third)
      Test.eq((try H.session(r, id)).history.take(before.history.size), before.history)
    end
  end
end

# A final answer cut by the token limit or refused ends the turn: the message sent meanwhile starts the next one.
def test_a_cut_or_refused_answer_ends_the_turn() -> Result[Void]
  replies = ["text_length.sse@hold", "text_refused.sse@hold", "text.sse"]
  H.using(H.Setup(replies: replies)) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Hi.")
    a = try H.until(a, Protocol.EventKind.TurnStarted)
    _ = try H.send(h, id, "More.")
    H.release(h)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    a = try H.until(a, Protocol.EventKind.TurnStarted)
    _ = try H.send(h, id, "Again.")
    H.release(h)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    ends = a.seen.map { |s| s.event }.flat_map do |event|
      case event
        Protocol.Event.TurnStarted(started) -> [number(started.turn_id)]
        Protocol.Event.TurnFinished(finished) -> [Protocol.stop_reason_name(finished.stop_reason)]
        _ -> []
      end
    end

    Test.eq(ends, ["turn-1", "max_tokens", "turn-2", "refusal", "turn-3", "end_turn"])
  end
end

# A queue whose session file cannot be written is dropped with an `error` event.
def test_a_broken_file_drops_the_queue() -> Result[Void]
  H.using(H.Setup(replies: ["write_file.sse", "text.sse"])) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    _ = try H.send(h, id, "Also say hi.")
    try chmod("400", H.session_file(h, id))
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try chmod("600", H.session_file(h, id))
    Test.eq(errors(a), [Protocol.KIND_SESSION_STORAGE, Protocol.KIND_QUEUE_DROPPED])
  end
end

# A queue that cannot start the next turn (its user record, with the content of the skills it names, is over the size
# of a record) is dropped with an `error` event, and the session goes on.
def test_a_queue_whose_turn_cannot_be_saved_is_dropped() -> Result[Void]
  setup = H.Setup(replies: ["write_file.sse", "text.sse", "text.sse"], take_ms: 0, skills: true)
  H.using(setup) do |h|
    names = (1..18).map { |i| "s#{i}" }
    body = "x" * 1_000_000
    for name in names
      try write(
        "#{h.base}/home/.agents/skills/#{name}/SKILL.md",
        "---\nname: #{name}\ndescription: Big.\n---\n#{body}",
      )
    end

    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    _ = try H.send(h, id, names.map { |n| "/#{n}" }.join(" "))
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    a = try H.until(a.with(seen: []), Protocol.EventKind.Error)
    try Test.eq(H.kinds(a.seen), ["error"])
    try Test.eq(errors(a), [Protocol.KIND_QUEUE_DROPPED])
    sent = try H.send(h, id, "Hi.")
    try Test.eq(number((try Protocol.decode_message_accepted(sent.text)).turn_id), "turn-2")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    Test.eq(H.stop_reason(a), "end_turn")
  end
end

# A turn that waited for its second approval ends after the restart: the waiting approval is
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
    try Test.eq(before.turn_id.map { |t| number(t) }, some("turn-1"))
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
      try Test.eq(number((try Protocol.decode_message_accepted(sent.text)).turn_id), "turn-2")
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
      try Test.eq(started_turn(b.seen[0]), some("turn-2"))
      try Test.eq(history_size(b.seen[0]), some(3))
      try Test.eq(H.stop_reason(b), "cancelled")
      try Test.eq(history_size(b.seen.last), some(3))
      sent = try H.send(r, id, "three")
      try Test.eq(number((try Protocol.decode_message_accepted(sent.text)).turn_id), "turn-3")
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
      try Test.eq(number((try Protocol.decode_message_accepted(sent.text)).turn_id), "turn-3")
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
      try Test.eq(listed.sessions.map { |s| s.id }.sort, [id, gone, "a-late"].sort)
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

# A load that crashes answers 503, without the detail, to the requests that wait for it; the next request loads again.
def test_a_load_that_crashes_is_tried_again() -> Result[Void]
  crash: Channel[Bool] = Channel.new(1)
  setup = H.Setup(replies: [], before_load: some(->(_id) { crash_once(crash) }))
  H.using(setup) do |h|
    id = try H.new_session(h)
    _ = crash.send(true, 0)
    H.restarted(h, setup, "") do |r|
      failed = try H.get(r, Protocol.session_path(id))
      failure = try Protocol.decode_failure(failed.text)
      try Test.eq([failed.status.to_s, failure.kind], ["503", Protocol.KIND_SESSION_UNAVAILABLE])
      try Test.assert(not failure.message.include?("crash"), "the detail is logged, not sent: #{failure.message}")
      Test.eq((try H.get(r, Protocol.session_path(id))).status, 200)
    end
  end
end

# At most 64 requests wait for one load; one more answers 503 at once, and the 64 get the session.
def test_a_load_takes_at_most_64_waiting_requests() -> Result[Void]
  gate: Channel[Bool] = Channel.new(1)
  setup = H.Setup(replies: [], before_load: some(->(_id) { _ = gate.recv(WAIT_MS) }))
  H.using(setup) do |h|
    id = try H.new_session(h)
    H.restarted(h, setup, "") do |r|
      path = Protocol.session_path(id)
      requests: List[Task[Int]] = []
      for _ in 1..64
        requests = requests.push(Task.spawn do status(H.get(r, path)) end)
      end

      refused = false
      for _ in 1..20
        probe = Task.spawn do status(H.get(r, path)) end
        requests = requests.push(probe)
        case Task.await(probe, PROBE_MS)
          Await.Done(code) if code == 503 ->
            refused = true
            break
          _ -> nil
        end
      end

      try Test.assert(refused, "no request was refused while 64 waited")
      _ = gate.send(true, 0)
      codes = requests.map { |request| Task.await(request) }
      try Test.eq(codes.select { |code| code == 200 }.size, 64)
      Test.eq(codes.select { |code| code != 200 and code != 503 }, [])
    end
  end
end

# A session keeps the model API it was made with, in its file, across a restart: the one it named, or the server's
# when it named none, even after the server's changes. A session whose file names none (made before the choice) uses
# the server's of now, and one that names an API the server does not know answers 503. An unknown API is refused, and
# the list shows the API of each session.
def test_a_session_keeps_its_model_api() -> Result[Void]
  replies = [
    "openai_responses/text.sse",
    "openai_chat/text.sse",
    "openai_chat/text.sse",
    "openai_responses/text.sse",
    "openai_responses/text.sse",
  ]

  setup = H.Setup(replies: replies)
  H.using(setup) do |h|
    responses = try H.new_session_in(h, h.work, some("openai_responses"))
    chat = try H.new_session(h)
    _ = try H.send(h, responses, "Hi.")
    _ = try H.idle(h, responses)
    _ = try H.send(h, chat, "Hi.")
    _ = try H.idle(h, chat)
    first = try H.next_request(h)
    try Test.eq([first.path, (try H.next_request(h)).path], ["/v1/responses", "/v1/chat/completions"])
    asked = try JSON.parse(first.body)
    try Test.eq(JSON.get(asked, "store"), ok(JSON.from(false)))
    try Test.eq(JSON.get(asked, "include"), ok(JSON.from(["reasoning.encrypted_content"])))
    unknown = Protocol.NewSession(cwd: h.work, model: none, api: some("nope"))
    refused = try H.post(h, Protocol.SESSIONS_PATH, Protocol.encode_new_session(unknown))
    try Test.eq(
      [refused.status.to_s, (try Protocol.decode_failure(refused.text)).kind],
      ["400", Protocol.KIND_INVALID],
    )

    try File.write_text(H.session_file(h, "old"), header(h.work, "old", ""))
    try File.write_text(H.session_file(h, "odd"), header(h.work, "odd", ",\"api\":\"nope\""))
    H.restarted(h, setup.with(api: "openai_responses"), "") do |r|
      listed = try Protocol.decode_session_list((try H.get(r, Protocol.SESSIONS_PATH)).text)
      apis = listed.sessions.map { |s| "#{s.id} #{s.api}" }.sort
      try Test.eq(apis, ["#{chat} openai", "#{responses} openai_responses", "odd nope", "old openai_responses"].sort)
      for id in [chat, "old", responses]
        _ = try H.send(r, id, "Again.")
        _ = try H.idle(r, id)
      end

      paths = [try H.next_request(r), try H.next_request(r), try H.next_request(r)].map { |seen| seen.path }
      try Test.eq(paths, ["/v1/chat/completions", "/v1/responses", "/v1/responses"])
      odd = try H.get(r, Protocol.session_path("odd"))
      failure = try Protocol.decode_failure(odd.text)
      try Test.eq([odd.status.to_s, failure.kind], ["503", Protocol.KIND_SESSION_UNAVAILABLE])
      Test.assert(failure.message.include?("unknown API nope"), "the reason is not said: #{failure.message}")
    end
  end
end

# A session picks a provider of the config, and a PATCH moves it to another with a model; both survive a restart, and
# an unknown provider is refused.
def test_a_session_keeps_its_provider_and_model() -> Result[Void]
  setup = H.Setup(replies: ["text.sse", "text.sse", "text.sse"], providers: ["other"])
  H.using(setup) do |h|
    id = try H.new_session_in(h, h.work, none, some("other"))
    _ = try H.send(h, id, "Hi.")
    _ = try H.idle(h, id)
    try Test.eq((try H.next_request(h)).path, "/other/chat/completions")
    offered = try Protocol.decode_provider_list((try H.get(h, Protocol.PROVIDERS_PATH)).text)
    try Test.eq(
      offered.providers.map { |p| [p.name, p.models.join(" ")] },
      [["anthropic", ""], ["local", "qwen2.5-0.5b-instruct"], ["other", "m1"]],
    )

    shown = try H.session(h, id)
    try Test.eq([shown.provider, shown.api, shown.model], ["other", "openai", "default"])
    change = Protocol.UpdateSession(provider: some("local"), model: some("m2"))
    patched = try H.call(h, "PATCH", Protocol.session_path(id), Protocol.encode_update_session(change), H.auth(h))
    try Test.eq(patched.status, 200)
    nope = Protocol.encode_update_session(Protocol.UpdateSession(provider: some("nope")))
    try Test.eq((try H.call(h, "PATCH", Protocol.session_path(id), nope, H.auth(h))).status, 400)
    unknown = Protocol.NewSession(cwd: h.work, model: none, provider: some("nope"))
    try Test.eq((try H.post(h, Protocol.SESSIONS_PATH, Protocol.encode_new_session(unknown))).status, 400)
    H.restarted(h, setup, "") do |r|
      listed = try Protocol.decode_session_list((try H.get(r, Protocol.SESSIONS_PATH)).text)
      try Test.eq(listed.sessions.map { |s| [s.provider.unwrap_or(""), s.model] }, [["local", "m2"]])
      _ = try H.send(r, id, "Again.")
      _ = try H.idle(r, id)
      seen = try H.next_request(r)
      try Test.eq(seen.path, "/v1/chat/completions")
      try Test.eq(JSON.get(try JSON.parse(seen.body), "model"), ok(JSON.from("m2")))
      again = try H.session(r, id)
      Test.eq([again.provider, again.api, again.model], ["local", "openai", "m2"])
    end
  end
end

# A file made before providers runs on the built-in provider of its API, never on the server's (`other` here). A
# session whose provider is not offered now (its key is unset) loads, refuses a turn with the key to set, and moves
# to another provider by a PATCH.
def test_old_and_orphan_sessions_load() -> Result[Void]
  setup = H.Setup(
    replies: ["text.sse", "text.sse"],
    providers: ["other"],
    provider: "other",
    key_envs: {"gone": "GONE_KEY"},
  )

  H.using(setup) do |h|
    try File.write_text(H.session_file(h, "old"), header(h.work, "old", ",\"api\":\"openai\""))
    try File.write_text(
      H.session_file(h, "orphan"),
      header(h.work, "orphan", ",\"api\":\"openai\",\"provider\":\"gone\""),
    )

    H.restarted(h, setup, "") do |r|
      listed = try Protocol.decode_session_list((try H.get(r, Protocol.SESSIONS_PATH)).text)
      providers = listed.sessions.map { |s| "#{s.id} #{s.provider.unwrap_or("")}" }.sort
      try Test.eq(providers, ["old local", "orphan gone"])
      try Test.eq((try H.session(r, "orphan")).provider, "gone")
      refused = try H.send(r, "orphan", "Hi.")
      failure = try Protocol.decode_failure(refused.text)
      try Test.eq([refused.status.to_s, failure.kind], ["503", Protocol.KIND_SESSION_UNAVAILABLE])
      try Test.assert(failure.message.include?("GONE_KEY"), "the key is not named: #{failure.message}")
      change = Protocol.encode_update_session(Protocol.UpdateSession(provider: some("local")))
      try Test.eq((try H.call(r, "PATCH", Protocol.session_path("orphan"), change, H.auth(r))).status, 200)
      for id in ["old", "orphan"]
        _ = try H.send(r, id, "Hi.")
        _ = try H.idle(r, id)
      end

      Test.eq(
        [(try H.next_request(r)).path, (try H.next_request(r)).path],
        ["/v1/chat/completions", "/v1/chat/completions"],
      )
    end
  end
end

# A PATCH while a turn runs applies from the next turn: the rest of the running one stays on its provider and model.
def test_a_change_during_a_turn_applies_from_the_next_turn() -> Result[Void]
  setup = H.Setup(replies: ["write_file.sse", "text.sse", "text.sse"], providers: ["other"])
  H.using(setup) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    change = Protocol.encode_update_session(Protocol.UpdateSession(provider: some("other"), model: some("m1")))
    try Test.eq((try H.call(h, "PATCH", Protocol.session_path(id), change, H.auth(h))).status, 200)
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Deny)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    _ = try H.send(h, id, "Again.")
    _ = try H.idle(h, id)
    seen = [try H.next_request(h), try H.next_request(h), try H.next_request(h)]
    try Test.eq(seen.map { |s| s.path }, ["/v1/chat/completions", "/v1/chat/completions", "/other/chat/completions"])
    try Test.eq(JSON.get(try JSON.parse(seen[1].body), "model"), ok(JSON.from(setup.model)))
    Test.eq(JSON.get(try JSON.parse(seen[2].body), "model"), ok(JSON.from("m1")))
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
    try Test.eq(history_size(unsaved[1]), some(snapshot.history.size))
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
    try Test.eq(number((try Protocol.decode_message_accepted(sent.text)).turn_id), "turn-3")
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

# A branch goes back before a message: the clients read the session again, the next turn follows the branch and its
# ids follow the old ones (a client from an older one gets `resync`), and the tree keeps both branches across a
# restart. A fork and a copy are new sessions.
def test_a_session_branches_forks_and_copies() -> Result[Void]
  setup = H.Setup(replies: ["text.sse", "text.sse", "text.sse"])
  H.using(setup) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "One.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    _ = try H.send(h, id, "Two.")
    a = try H.until(a.with(seen: []), Protocol.EventKind.TurnFinished)
    first = try tree(h, id)
    try Test.eq(first.map { |n| n.text }, ["One.", "Two."])
    before = try H.session(h, id)
    refused = try H.post(h, Protocol.branch_path(id), Protocol.encode_branch(Protocol.Branch(entry: first[1].id + 1)))
    try Test.eq(refused.status, 400)
    moved = try H.post(h, Protocol.branch_path(id), Protocol.encode_branch(Protocol.Branch(entry: first[1].id)))
    try Test.eq(Protocol.decode_branched(moved.text), ok(Protocol.Branched(id: id, text: "Two.")))
    a = try H.until(a.with(seen: []), Protocol.EventKind.Resync)
    H.close(a)
    after = try H.session(h, id)
    try Test.eq(after.history, before.history.take(2))
    try Test.eq(after.last_event_id, before.last_event_id + 1)
    old = try H.until(try H.subscribe(h, id, some(before.last_event_id)), Protocol.EventKind.Resync)
    H.close(old)
    try Test.eq(H.kinds(old.seen), ["resync"])
    b = try H.subscribe(h, id, some(after.last_event_id))
    _ = try H.send(h, id, "Three.")
    b = try H.until(b, Protocol.EventKind.TurnFinished)
    H.close(b)
    try Test.eq(b.seen[0].id, Protocol.format_event_id(before.last_event_id + 2))
    second = try tree(h, id)
    try Test.eq(second.map { |n| "#{n.text} #{n.active}" }, ["One. true", "Two. false", "Three. true"])
    try Test.eq(second.map { |n| n.parent }, [none, some(first[0].id), some(first[0].id)])
    fork = try H.post(h, Protocol.fork_path(id), Protocol.encode_fork(Protocol.Fork(entry: some(first[1].id))))
    forked = try Protocol.decode_branched(fork.text)
    try Test.eq([fork.status.to_s, forked.text], ["201", "Two."])
    try Test.eq((try H.session(h, forked.id)).history, before.history.take(2))
    copy = try Protocol.decode_branched((try H.post(h, Protocol.fork_path(id), "{}")).text)
    now = try H.session(h, id)
    try Test.eq((try H.session(h, copy.id)).history, now.history)
    try Test.eq((try tree(h, copy.id)).map { |n| n.text }, ["One.", "Three."])
    H.restarted(h, setup, "") do |r|
      listed = try Protocol.decode_session_list((try H.get(r, Protocol.SESSIONS_PATH)).text)
      try Test.eq(listed.sessions.size, 3)
      try Test.eq((try H.session(r, id)).history, now.history)
      try Test.eq((try H.session(r, id)).last_event_id, now.last_event_id)
      Test.eq(try tree(r, id), second)
    end
  end
end

# After a restart, a client from the branch left gets `resync`, and the next turn takes a number no turn had.
def test_a_restart_after_a_branch_resyncs_the_branch_left() -> Result[Void]
  setup = H.Setup(replies: ["text.sse", "text.sse", "text.sse"])
  H.using(setup) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "One.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    _ = try H.send(h, id, "Two.")
    a = try H.until(a.with(seen: []), Protocol.EventKind.TurnFinished)
    H.close(a)
    before = try H.session(h, id)
    nodes = try tree(h, id)
    _ = try H.post(h, Protocol.branch_path(id), Protocol.encode_branch(Protocol.Branch(entry: nodes[1].id)))
    H.restarted(h, setup, "") do |r|
      old = try H.until(try H.subscribe(r, id, some(before.last_event_id)), Protocol.EventKind.Resync)
      H.close(old)
      try Test.eq(H.kinds(old.seen), ["resync"])
      after = try H.session(r, id)
      try Test.eq(after.history, before.history.take(2))
      try Test.eq(after.last_event_id, before.last_event_id + 1)
      sent = try H.send(r, id, "Three.")
      try Test.eq(number((try Protocol.decode_message_accepted(sent.text)).turn_id), "turn-3")
      _ = try H.idle(r, id)
      ok()
    end
  end
end

private

WAIT_MS = 20_000
PROBE_MS = 300

# A turn id without its random part.
def number(turn_id: String) -> String = turn_id.split("-").take(2).join("-")

def header(cwd: String, id: String, more: String) -> String
  "{\"type\":\"session\",\"id\":\"#{id}\",\"cwd\":\"#{cwd}\",\"model\":\"m\",\"created_ms\":1#{more}}\n"
end

def crash_once(crash: Channel[Bool]) -> Void
  if crash.recv(0).ok?
    missing: Optional[Int] = none
    _ = missing.unwrap!
  end
end

def status(answer: Result[H.Answer]) -> Int
  case answer
    ok(got) -> got.status
    error(_) -> 0
  end
end

def errors(sub: H.Sub) -> List[String]
  sub.seen.map { |s| s.event }.flat_map do |event|
    case event
      Protocol.Event.Error(failure) -> [failure.kind]
      _ -> []
    end
  end
end

def write(path: String, text: String) -> Result[Void]
  code = try H.run("mkdir", ["-p", path.slice(0, path.length - path.split("/").last.length - 1)])
  return error("mkdir failed") if code != 0

  File.write_text(path, text)
end

def chmod(mode: String, path: String) -> Result[Void]
  code = try H.run("chmod", [mode, path])
  return error("chmod failed") if code != 0

  ok()
end

def roles() -> String
  ["system", "user", "assistant", "tool", "assistant", "user"].map { |r| JSON.encode(r) }.join(" ")
end

def started_turn(seen: H.Seen) -> Optional[String]
  case seen.event
    Protocol.Event.TurnStarted(started) -> some(number(started.turn_id))
    _ -> none
  end
end

def history_size(seen: H.Seen) -> Optional[Int]
  case seen.event
    Protocol.Event.TurnStarted(started) -> started.history_size
    Protocol.Event.TurnFinished(finished) -> finished.history_size
    _ -> none
  end
end

def tree(h: H.Harness, id: String) -> Result[List[Protocol.TreeNode]]
  ok((try Protocol.decode_session_tree((try H.get(h, Protocol.tree_path(id))).text)).nodes)
end
