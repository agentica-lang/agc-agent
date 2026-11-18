import Protocol from "pkg/protocol/protocol"
import H from "support/harness"

# A client changes the model and the thinking level of a session: the next calls use them, the snapshot shows them,
# and a restart keeps them. A level the server does not know is refused.
def test_a_session_changes_its_model_and_thinking_level() -> Result[Void]
  setup = H.Setup(api: "openai_responses", replies: ["text.sse", "text.sse", "text.sse", "text.sse"])
  H.using(setup) do |h|
    id = try H.new_session(h)
    _ = try H.send(h, id, "Hi.\tThere")
    _ = try H.idle(h, id)
    first = try JSON.parse((try H.next_request(h)).body)
    try Test.eq(JSON.get(first, "reasoning").ok?, false)
    change = Protocol.UpdateSession(model: some("other-model"), effort: some("high"))
    changed = try patch(h, id, Protocol.encode_update_session(change))
    try Test.eq(changed.status, 200)
    refused = try patch(h, id, "{\"effort\": \"max\"}")
    try Test.eq(
      [refused.status.to_s, (try Protocol.decode_failure(refused.text)).kind],
      ["400", Protocol.KIND_UNKNOWN],
    )

    snapshot = try H.session(h, id)
    try Test.eq([snapshot.model, snapshot.effort.unwrap_or("")], ["other-model", "high"])
    other = try H.new_session(h)
    listed = try Protocol.decode_session_list((try H.get(h, Protocol.SESSIONS_PATH)).text)
    shown = listed.sessions.map { |l| "#{l.id} #{l.model} #{l.title}" }
    try Test.eq(shown.sort, ["#{id} other-model Hi. There", "#{other} other-model "].sort)
    try Test.assert(listed.sessions.all? { |l| l.updated_s > 0 }, "no time of change: #{listed}")
    _ = try H.send(h, id, "Again.")
    _ = try H.idle(h, id)
    try asked_with(try JSON.parse((try H.next_request(h)).body), "other-model", "high")
    # A settings record with a level the server does not know is skipped.
    bad = "{\"type\":\"settings\",\"model\":\"m\",\"effort\":\"max\"}\n"
    H.restarted(h, setup, bad) do |r|
      after = try H.session(r, id)
      try Test.eq([after.model, after.effort.unwrap_or("")], ["other-model", "high"])
      _ = try H.send(r, id, "Once more.")
      _ = try H.idle(r, id)
      try asked_with(try JSON.parse((try H.next_request(r)).body), "other-model", "high")
      reset = try patch(r, id, Protocol.encode_update_session(Protocol.UpdateSession(effort: some("default"))))
      try Test.eq([reset.status.to_s, reset.text], ["200", "{}"])
      try Test.eq((try H.session(r, id)).effort, none)
      _ = try H.send(r, id, "Plain.")
      _ = try H.idle(r, id)
      try Test.eq(JSON.get(try JSON.parse((try H.next_request(r)).body), "reasoning").ok?, false)
      restarted = try Protocol.decode_session_list((try H.get(r, Protocol.SESSIONS_PATH)).text)
      try Test.eq(restarted.sessions.select { |l| l.id == id }.map { |l| l.model }, ["other-model"])
      side = "#{H.sessions(r)}/#{id}.settings.json"
      try Test.eq((try File.stat(side)).mode % 512, 384)
      deleted = try H.call(r, "DELETE", Protocol.session_path(id), "", H.auth(r))
      try Test.eq(deleted.status, 200)
      Test.eq(File.stat(side).ok?, false)
    end
  end
end

# A client asks for a compaction: the history up to the last task becomes a summary that the next call starts from.
# With nothing to fold the answer says so and the model is not asked; while a turn runs it is `session.busy`.
def test_a_client_compacts_the_history() -> Result[Void]
  replies = ["text.sse", "text.sse", "summary.sse", "text.sse", "write_file.sse"]
  H.using(H.Setup(replies: replies)) do |h|
    id = try H.new_session(h)
    nothing = try compact(h, id)
    try Test.eq(
      [nothing.status.to_s, nothing.text],
      ["200", Protocol.encode_compacted(Protocol.Compacted(compacted: false))],
    )

    for text in ["Say hello.", "Say it again."]
      _ = try H.send(h, id, text)
      _ = try H.idle(h, id)
    end

    folded = try compact(h, id)
    try Test.eq(Protocol.decode_compacted(folded.text), ok(Protocol.Compacted(compacted: true)))
    _ = try H.send(h, id, "And now?")
    _ = try H.idle(h, id)
    messages = try H.request_messages(h, 4)
    texts = messages.map { |m| JSON.encode(m) }
    try Test.assert(texts.any? { |t| t.include?("Summary of the session so far") }, "no summary in #{texts}")
    try Test.eq(texts.any? { |t| t.include?("Say it again.") }, true)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    busy = try compact(h, id)
    try Test.eq([busy.status.to_s, (try Protocol.decode_failure(busy.text)).kind], ["409", Protocol.KIND_SESSION_BUSY])
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Deny)
    H.close(a)
    ok()
  end
end

# While a compaction a client asked for runs, a turn and a second compaction are `session.busy`; then both work.
def test_a_compaction_refuses_turns_and_another_compaction() -> Result[Void]
  replies = ["text.sse", "text.sse", "summary.sse@hold", "text.sse"]
  H.using(H.Setup(replies: replies)) do |h|
    id = try H.new_session(h)
    for text in ["Say hello.", "Say it again."]
      _ = try H.send(h, id, text)
      _ = try H.idle(h, id)
    end

    first = Task.spawn(-> { compact(h, id) })
    for _ in 1..3
      _ = try H.next_request(h)
    end

    turn = try H.send(h, id, "Now?")
    again = try compact(h, id)
    for refused in [turn, again]
      try Test.eq(
        [refused.status.to_s, (try Protocol.decode_failure(refused.text)).kind],
        ["409", Protocol.KIND_SESSION_BUSY],
      )
    end

    H.release(h)
    done = try Task.await(first)
    try Test.eq(Protocol.decode_compacted(done.text), ok(Protocol.Compacted(compacted: true)))
    sent = try H.send(h, id, "Now?")
    try Test.eq(sent.status, 202)
    _ = try H.idle(h, id)
    ok()
  end
end

# A bidi control in the first message becomes a space in the list, so it cannot reorder a client's row.
def test_a_bidi_control_in_the_title_becomes_a_space() -> Result[Void]
  setup = H.Setup(replies: [])
  H.using(setup) do |h|
    head = "{\"type\":\"session\",\"id\":\"rlo\",\"cwd\":\"#{h.work}\",\"model\":\"m\",\"created_ms\":1}\n"
    try File.write_text(H.session_file(h, "rlo"), "#{head}{\"type\":\"user\",\"text\":\"fix \\u202eit\\u2067\"}\n")
    H.restarted(h, setup, "") do |r|
      listed = try Protocol.decode_session_list((try H.get(r, Protocol.SESSIONS_PATH)).text)
      Test.eq(listed.sessions.map { |l| l.title }, ["fix  it "])
    end
  end
end

# A byte that is not UTF-8 in the first message spoils only its character in the list.
def test_a_bad_byte_in_the_title_becomes_a_replacement_character() -> Result[Void]
  setup = H.Setup(replies: [])
  H.using(setup) do |h|
    head = "{\"type\":\"session\",\"id\":\"odd\",\"cwd\":\"#{h.work}\",\"model\":\"m\",\"created_ms\":1}\n"
    bad = try Bytes.from_list([0xff])
    record = "{\"type\":\"user\",\"text\":\"fix ".bytes + bad + "it\"}\n".bytes
    try File.write_text(H.session_file(h, "odd"), head)
    handle = try File.open(H.session_file(h, "odd"), "append")
    written = File.write_bytes(handle, record)
    try File.close(handle)
    try written
    H.restarted(h, setup, "") do |r|
      listed = try Protocol.decode_session_list((try H.get(r, Protocol.SESSIONS_PATH)).text)
      Test.eq(listed.sessions.map { |l| l.title }, ["fix #{String.from_code(0xfffd)}it"])
    end
  end
end

private

def patch(h: H.Harness, id: String, body: String) -> Result[H.Answer]
  H.call(h, "PATCH", Protocol.session_path(id), body, H.auth(h))
end

def compact(h: H.Harness, id: String) -> Result[H.Answer] = H.post(h, Protocol.compact_path(id), "")

def asked_with(request: JSON.Value, model: String, effort: String) -> Result[Void]
  try Test.eq(JSON.get(request, "model"), ok(JSON.from(model)))
  Test.eq(JSON.get(try JSON.get(request, "reasoning"), "effort"), ok(JSON.from(effort)))
end

# `PATCH` with `confine` switches the file tools of one session between its folder and any path: the snapshot shows it,
# and the server's default (off) applies to the next session.
def test_a_session_switches_the_confinement_of_its_file_tools() -> Result[Void]
  H.using(H.Setup(replies: [])) do |h|
    id = try H.new_session(h)
    try Test.eq((try H.session(h, id)).confine, false)
    try Test.eq((try patch(h, id, "{\"confine\": true}")).status, 200)
    try Test.eq((try H.session(h, id)).confine, true)
    try Test.eq((try H.session(h, try H.new_session(h))).confine, false)
    forked = try H.post(h, Protocol.fork_path(id), Protocol.encode_fork(Protocol.Fork(entry: none)))
    try Test.eq((try H.session(h, (try Protocol.decode_branched(forked.text)).id)).confine, true)
    try Test.eq((try patch(h, id, "{\"confine\": false}")).status, 200)
    Test.eq((try H.session(h, id)).confine, false)
  end
end

# A read outside the session folder runs by default and is refused after `PATCH` with `confine`, in the same session.
def test_a_read_outside_the_folder_is_refused_once_the_session_confines_its_file_tools() -> Result[Void]
  replies = ["read_outside.sse", "text.sse", "read_outside.sse", "text.sse"]
  H.using(H.Setup(replies: replies, approvals: false)) do |h|
    try File.write_text("#{h.base}/outside.txt", "text of outside")
    id = try H.new_session(h)
    _ = try H.send(h, id, "Read it.")
    _ = try H.idle(h, id)
    _ = try H.next_request(h)
    open = (try H.next_request(h)).body
    try Test.assert(open.include?("text of outside"), "the read did not run: #{open}")
    try Test.eq((try patch(h, id, "{\"confine\": true}")).status, 200)
    _ = try H.send(h, id, "Read it again.")
    _ = try H.idle(h, id)
    _ = try H.next_request(h)
    shut = (try H.next_request(h)).body
    Test.assert(shut.include?("outside the session folder"), "the read was not refused: #{shut}")
  end
end
