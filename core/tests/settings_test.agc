import Protocol from "pkg/protocol/protocol"
import H from "support/harness"

# A client changes the model and the thinking level of a session: the next calls use them, the snapshot shows them,
# and a restart keeps them. A level the server does not know is refused.
def test_a_session_changes_its_model_and_thinking_level() -> Result[Void]
  setup = H.Setup(api: "openai_responses", replies: ["text.sse", "text.sse", "text.sse"])
  H.using(setup) do |h|
    id = try H.new_session(h)
    _ = try H.send(h, id, "Hi.")
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
    _ = try H.send(h, id, "Again.")
    _ = try H.idle(h, id)
    try asked_with(try JSON.parse((try H.next_request(h)).body), "other-model", "high")
    H.restarted(h, setup, "") do |r|
      after = try H.session(r, id)
      try Test.eq([after.model, after.effort.unwrap_or("")], ["other-model", "high"])
      _ = try H.send(r, id, "Once more.")
      _ = try H.idle(r, id)
      asked_with(try JSON.parse((try H.next_request(r)).body), "other-model", "high")
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

private

def patch(h: H.Harness, id: String, body: String) -> Result[H.Answer]
  H.call(h, "PATCH", Protocol.session_path(id), body, H.auth(h))
end

def compact(h: H.Harness, id: String) -> Result[H.Answer] = H.post(h, Protocol.compact_path(id), "")

def asked_with(request: JSON.Value, model: String, effort: String) -> Result[Void]
  try Test.eq(JSON.get(request, "model"), ok(JSON.from(model)))
  Test.eq(JSON.get(try JSON.get(request, "reasoning"), "effort"), ok(JSON.from(effort)))
end
