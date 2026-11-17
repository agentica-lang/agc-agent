import Protocol from "pkg/protocol/protocol"
import H from "support/harness"

# On the OpenAI Responses format a turn runs as on chat completions: the system prompt goes as `instructions`, the
# tools as functions (`apply_patch` as a custom tool), and the next request gives back the reasoning item (its
# encrypted content), the call and its output by `call_id`. The API keeps nothing (`store: false`) and sends the
# reasoning back encrypted, so no item goes
# back with its id. The usage counts the cached tokens, and the answer is shown.
def test_a_turn_runs_on_the_responses_format() -> Result[Void]
  setup = H.Setup(api: "openai_responses", replies: ["write_file.sse", "text.sse"])
  H.using(setup) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(H.stop_reason(a), "end_turn")
    try Test.eq(File.read_text("#{h.work}/hello.txt"), ok("hi\n"))
    first = try H.next_request(h)
    try Test.eq([first.method, first.path], ["POST", "/v1/responses"])
    asked = try JSON.parse(first.body)
    try Test.assert(string(asked, "instructions").start_with?("You are a coding agent."), "no instructions")
    try Test.eq(types(asked, "input"), ["message"])
    try Test.eq(JSON.get(asked, "store"), ok(JSON.from(false)))
    try Test.eq(JSON.get(asked, "include"), ok(JSON.from(["reasoning.encrypted_content"])))
    try Test.eq(types(asked, "tools").select { |t| t != "function" }, ["custom"])
    second = try JSON.parse((try H.next_request(h)).body)
    try Test.eq(types(second, "input"), ["message", "reasoning", "message", "function_call", "function_call_output"])
    items = try JSON.list(try JSON.get(second, "input"))
    try Test.eq(string(items[1], "encrypted_content"), "gAAAAABcoreOpaqueReasoning==")
    try Test.eq([string(items[3], "call_id"), string(items[4], "call_id")], ["call_core_1", "call_core_1"])
    try Test.eq(items.select { |item| JSON.get(item, "id").ok? }.size, 0)
    usage = a.seen.select { |s| Protocol.event_name(s.event) == "usage" }
    try Test.eq(usage.map { |s| s.event }.first, Protocol.Event.Usage(usage_of(100, 60)))
    shown = (try H.session(h, id)).history
    Test.eq(shown.map { |m| m.text }, ["Write hello.txt.", "I will write it.\n\nHello! It's a good day!"])
  end
end

# The reasoning of one provider does not go to another: after a move (and a restart), the next request has none.
def test_a_move_to_another_provider_leaves_the_reasoning_behind() -> Result[Void]
  replies = ["write_file.sse", "text.sse", "text.sse"]
  setup = H.Setup(api: "openai_responses", replies: replies, providers: ["other:openai_responses"])
  H.using(setup) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    change = Protocol.encode_update_session(Protocol.UpdateSession(provider: some("other"), model: some("m1")))
    try Test.eq((try H.call(h, "PATCH", Protocol.session_path(id), change, H.auth(h))).status, 200)
    H.restarted(h, setup, "") do |r|
      _ = try H.send(r, id, "Thanks.")
      _ = try H.idle(r, id)
      _ = try H.next_request(r)
      _ = try H.next_request(r)
      third = try H.next_request(r)
      try Test.eq(third.path, "/other/responses")
      Test.eq(
        types(try JSON.parse(third.body), "input").uniq.sort,
        ["function_call", "function_call_output", "message"],
      )
    end
  end
end

# Reasoning saved before providers names none: it is of the session's first provider, so it goes back to that one and
# not to another after a move.
def test_old_reasoning_stays_with_the_first_provider() -> Result[Void]
  setup = H.Setup(api: "openai_responses", replies: ["text.sse", "text.sse"], providers: ["other:openai_responses"])
  H.using(setup) do |h|
    head = (
      "{\"type\":\"session\",\"id\":\"old\",\"cwd\":\"#{h.work}\",\"model\":\"m\",\"created_ms\":1,\"api\":\"openai_responses\"}"
    )

    reasoning = "{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[],\"encrypted_content\":\"gAAAold==\"}"
    blocks = "[{\"type\":\"thinking\",\"text\":\"t\",\"replay\":#{reasoning}},{\"type\":\"text\",\"text\":\"Hello.\"}]"
    answer = "{\"type\":\"messages\",\"messages\":[{\"role\":\"assistant\",\"content\":#{blocks}}]}"
    try File.write_text(
      H.session_file(h, "old"),
      [head, "{\"type\":\"user\",\"text\":\"Hi.\"}", answer, ""].join("\n"),
    )

    H.restarted(h, setup, "") do |r|
      _ = try H.send(r, "old", "Again.")
      _ = try H.idle(r, "old")
      change = Protocol.encode_update_session(Protocol.UpdateSession(provider: some("other"), model: some("m1")))
      try Test.eq((try H.call(r, "PATCH", Protocol.session_path("old"), change, H.auth(r))).status, 200)
      _ = try H.send(r, "old", "Thanks.")
      _ = try H.idle(r, "old")
      first = try H.next_request(r)
      second = try H.next_request(r)
      try Test.eq([first.path, second.path], ["/v1/responses", "/other/responses"])
      try Test.eq(types(try JSON.parse(first.body), "input").include?("reasoning"), true)
      Test.eq(types(try JSON.parse(second.body), "input").include?("reasoning"), false)
    end
  end
end

private

def string(json: JSON.Value, key: String) -> String
  JSON.string(JSON.get(json, key).unwrap_or(JSON.null())).unwrap_or("")
end

def types(request: JSON.Value, key: String) -> List[String]
  none_yet: List[JSON.Value] = []
  JSON.list(JSON.get(request, key).unwrap_or(JSON.null())).unwrap_or(none_yet).map { |item| string(item, "type") }
end

def usage_of(input: Int, cached: Int) -> Protocol.Usage
  Protocol.Usage(
    input: input - cached,
    output: 20,
    cache_read: cached,
    cache_write: 0,
    context: input,
    window: some(1_000_000),
  )
end
