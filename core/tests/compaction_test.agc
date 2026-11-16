import Protocol from "pkg/protocol/protocol"
import H from "support/harness"

# The window comes from `GET /models` (120 tokens). The tool round of the second turn reaches 100 tokens, past 80 per
# cent: the compaction model summarizes what lies between the first task and the running turn, and the next call
# carries the first task, the summary and the running turn after the same system prompt and tools. The event ids go
# on, and a restart keeps the compacted history.
def test_past_the_window_the_history_is_compacted_and_keeps_the_first_task() -> Result[Void]
  replies = [
    "models_small.json", "text.sse", "write_file.sse", "summary.sse", "text.sse", "models_small.json", "text.sse",
  ]

  setup = H.Setup(replies: replies, context_window: 0, compact_model: "cheap")
  H.using(setup) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Say hello.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(a.seen.map { |s| s.id }, (1..a.seen.size).map { |n| Protocol.format_event_id(n) })
    try Test.eq(H.stop_reason(a), "end_turn")
    models = try H.next_request(h)
    try Test.eq([models.method, models.path], ["GET", "/v1/models"])
    first = try body(h)
    _ = try body(h)
    summary_request = try body(h)
    after = try body(h)
    try Test.eq(string(summary_request, "model"), "cheap")
    asked = try JSON.list(try JSON.get(summary_request, "messages"))
    try Test.eq(asked.map { |m| string(m, "role") }, ["system", "user"])
    try Test.assert(string(asked[1], "content").include?("Assistant: Hello!"), "the summary does not see the answer")
    try Test.eq(JSON.get(summary_request, "tools").ok?, false)
    try Test.eq(roles(after), ["system", "user", "assistant", "user", "assistant", "tool"])
    try Test.eq(prefix(after), prefix(first))
    try Test.eq(contents(after).take(4).drop(1), ["Say hello.", summary(), "Write hello.txt."])
    shown = (try H.session(h, id)).history
    try Test.eq(shown.map { |m| Protocol.role_name(m.role) }, ["user", "assistant", "user", "assistant"])
    try Test.assert(not shown[3].text.include?("Summary"), "the summary is shown as an answer")
    last = (try H.session(h, id)).last_event_id
    H.restarted(h, setup, "") do |r|
      b = try H.subscribe(r, id, some(last))
      _ = try H.send(r, id, "Again.")
      b = try H.until(b, Protocol.EventKind.TurnFinished)
      H.close(b)
      try Test.eq(b.seen.first.id, Protocol.format_event_id(last + 1))
      _ = try H.next_request(r)
      again = try body(r)
      try Test.eq(roles(again), ["system", "user", "assistant", "user", "assistant", "tool", "assistant", "user"])
      try Test.eq(prefix(again), prefix(first))
      Test.eq(contents(again).take(3).drop(1), ["Say hello.", summary()])
    end
  end
end

private

def body(h: H.Harness) -> Result[JSON.Value] = JSON.parse((try H.next_request(h)).body)

def string(json: JSON.Value, key: String) -> String
  JSON.string(JSON.get(json, key).unwrap_or(JSON.null())).unwrap_or("")
end

def messages(request: JSON.Value) -> List[JSON.Value]
  none_yet: List[JSON.Value] = []
  JSON.list(JSON.get(request, "messages").unwrap_or(JSON.null())).unwrap_or(none_yet)
end

def roles(request: JSON.Value) -> List[String] = messages(request).map { |m| string(m, "role") }

def contents(request: JSON.Value) -> List[String] = messages(request).map { |m| string(m, "content") }

# The system message and the tools, as sent.
def prefix(request: JSON.Value) -> String
  "#{JSON.encode(messages(request)[0])}\n#{JSON.encode(JSON.get(request, "tools").unwrap_or(JSON.null()))}"
end

def summary() -> String = "Summary of the session so far:\n\nThe user said hello and the agent greeted back."
