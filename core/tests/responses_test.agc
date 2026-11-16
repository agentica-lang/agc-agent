import Protocol from "pkg/protocol/protocol"
import H from "support/harness"

# On the OpenAI Responses format a turn runs as on chat completions: the system prompt goes as `instructions`, the
# tools as functions, and the next request gives back the reasoning item (its encrypted content), the call and its
# output by `call_id`. The API keeps nothing (`store: false`) and sends the reasoning back encrypted. The usage counts
# the cached tokens, and the answer is shown.
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
    try Test.assert(types(asked, "tools").all? { |t| t == "function" }, "the tools are not functions")
    second = try JSON.parse((try H.next_request(h)).body)
    try Test.eq(types(second, "input"), ["message", "reasoning", "message", "function_call", "function_call_output"])
    items = try JSON.list(try JSON.get(second, "input"))
    try Test.eq(string(items[1], "encrypted_content"), "gAAAAABcoreOpaqueReasoning==")
    try Test.eq([string(items[3], "call_id"), string(items[4], "call_id")], ["call_core_1", "call_core_1"])
    usage = a.seen.select { |s| Protocol.event_name(s.event) == "usage" }
    try Test.eq(usage.map { |s| s.event }.first, Protocol.Event.Usage(usage_of(100, 60)))
    shown = (try H.session(h, id)).history
    Test.eq(shown.map { |m| m.text }, ["Write hello.txt.", "I will write it.\n\nHello! It's a good day!"])
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
  Protocol.Usage(input: input - cached, output: 20, cache_read: cached, cache_write: 0, context: input)
end
