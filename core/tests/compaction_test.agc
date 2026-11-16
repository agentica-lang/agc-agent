import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import Compaction from "../src/compaction"
import H from "support/harness"

# The window comes from llama-server's `/props` (120 tokens). The tool round of the second turn reaches 100 tokens,
# past 80 per cent: the compaction model summarizes what lies between the first task and the running turn, and the
# next call carries the first task, the summary and the running turn after the same system prompt and tools. The
# event ids go on, and a restart keeps the compacted history; there `/props` fails and `GET /models` gives the window.
def test_past_the_window_the_history_is_compacted_and_keeps_the_first_task() -> Result[Void]
  replies = [
    "props_small.json",
    "text.sse",
    "write_file.sse",
    "summary.sse",
    "text.sse",
    "404:not_found.json",
    "models_small.json",
    "text.sse",
  ]

  setup = H.Setup(replies: replies, context_window: 0, compact_model: "cheap", props: true)
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
    props = try H.next_request(h)
    try Test.eq([props.method, props.path], ["GET", "/props"])
    first = try body(h)
    _ = try body(h)
    summary_request = try body(h)
    after = try body(h)
    try Test.eq(string(summary_request, "model"), "cheap")
    asked = try JSON.list(try JSON.get(summary_request, "messages"))
    try Test.eq(asked.map { |m| string(m, "role") }, ["system", "user"])
    try Test.eq(transcript(asked[1]), ["assistant text"])
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
      try Test.eq(failures(b.seen), [])
      try Test.eq((try H.next_request(r)).path, "/props")
      try Test.eq((try H.next_request(r)).path, "/v1/models")
      again = try body(r)
      try Test.eq(roles(again), ["system", "user", "assistant", "user", "assistant", "tool", "assistant", "user"])
      try Test.eq(prefix(again), prefix(first))
      Test.eq(contents(again).take(3).drop(1), ["Say hello.", summary()])
    end
  end
end

# On the Responses format the summary request keeps nothing on the API side either: `store: false`, and the
# reasoning asked back encrypted.
def test_the_summary_request_on_the_responses_format_stores_nothing() -> Result[Void]
  replies = ["text.sse", "write_file.sse", "summary.sse", "text.sse"]
  H.using(H.Setup(api: "openai_responses", replies: replies, context_window: 120)) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Say hello.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a.with(seen: []), Protocol.EventKind.ApprovalRequested)
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq([H.stop_reason(a), failures(a.seen).join(",")], ["end_turn", ""])
    _ = try body(h)
    _ = try body(h)
    summary_request = try body(h)
    try Test.eq(string(summary_request, "instructions"), Compaction.SYSTEM)
    try Test.eq(JSON.get(summary_request, "store"), ok(JSON.from(false)))
    Test.eq(JSON.get(summary_request, "include"), ok(JSON.from(["reasoning.encrypted_content"])))
  end
end

# The last call of a turn left the context past the limit: the next turn compacts before its first call. The summary
# folds several messages, tool calls and results among them (as JSON data), and the answer of the turn is still shown.
def test_a_turn_compacts_at_its_start() -> Result[Void]
  replies = ["write_file.sse", "text.sse", "text_cached.sse", "summary.sse", "text.sse"]
  H.using(H.Setup(replies: replies, context_window: 120)) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    _ = try H.send(h, id, "Hi again.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    _ = try H.send(h, id, "Go on.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    _ = try H.next_request(h)
    tool_output = string((try JSON.list(try JSON.get(try body(h), "messages"))).last, "content")
    _ = try H.next_request(h)
    summary_request = try body(h)
    asked = try JSON.list(try JSON.get(summary_request, "messages"))
    items = try JSON.list(try JSON.parse(string(asked[1], "content")))
    results = items.select { |item| string(item, "type") == "tool_result" }.map { |item| string(item, "content") }
    try Test.assert(not tool_output.empty?, "the tool gave no output")
    try Test.eq(results, [tool_output])
    try Test.eq(
      transcript(asked[1]),
      ["assistant text", "assistant tool_call", "user tool_result", "assistant text", "user text", "assistant text"],
    )

    after = try body(h)
    try Test.eq(roles(after), ["system", "user", "assistant", "user"])
    try Test.eq(contents(after).drop(1), ["Write hello.txt.", summary(), "Go on."])
    shown = (try H.session(h, id)).history
    try Test.eq(shown.size, 6)
    Test.assert(shown[5].text.start_with?("Hello!"), "the answer of the compacted turn is not shown")
  end
end

# One long turn of tool rounds compacts too: past the limit, its older rounds become the summary, and the last round
# stays whole, its tool call with its result, after a user message that goes on with the task. After a restart the
# history is the same.
def test_the_older_rounds_of_the_running_turn_are_compacted() -> Result[Void]
  replies = ["write_file.sse", "bash_echo.sse", "summary.sse", "text.sse", "text.sse"]
  setup = H.Setup(replies: replies, context_window: 120)
  H.using(setup) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt, then echo.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    a = try H.until(a.with(seen: []), Protocol.EventKind.ApprovalRequested)
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq([H.stop_reason(a), failures(a.seen).size.to_s], ["end_turn", "0"])
    _ = try body(h)
    _ = try body(h)
    asked = try JSON.list(try JSON.get(try body(h), "messages"))
    try Test.eq(transcript(asked[1]), ["assistant text", "assistant tool_call", "user tool_result"])
    after = try body(h)
    try Test.eq(roles(after), ["system", "user", "assistant", "user", "assistant", "tool"])
    try Test.eq(contents(after).take(4).drop(1), ["Write hello.txt, then echo.", summary(), Compaction.GO_ON])
    try Test.assert(JSON.get(messages(after)[4], "tool_calls").ok?, "the last tool call is not kept")
    shown = (try H.session(h, id)).history
    try Test.eq(shown.map { |m| Protocol.role_name(m.role) }, ["user", "assistant"])
    # The text of the folded round stays in the answer, as without a compaction.
    try Test.assert(shown[1].text.start_with?("I will write it.\n\nHello!"), "the answer is cut: #{shown[1].text}")
    H.restarted(h, setup, "") do |r|
      try Test.eq((try H.session(r, id)).history, shown)
      _ = try H.send(r, id, "Again.")
      _ = try H.idle(r, id)
      again = try body(r)
      Test.eq(contents(again).take(4).drop(1), ["Write hello.txt, then echo.", summary(), Compaction.GO_ON])
    end
  end
end

# A fold that leaves the context past the limit does not fold again in that turn: one summary call, an `error` event,
# and the turn goes on.
def test_a_fold_that_does_not_help_is_not_repeated_in_the_turn() -> Result[Void]
  replies = ["write_file.sse", "bash_echo.sse", "summary.sse", "bash_echo.sse", "text.sse"]
  H.using(H.Setup(replies: replies, context_window: 120)) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt, then echo twice.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    a = try H.until(a.with(seen: []), Protocol.EventKind.ApprovalRequested)
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.AllowSession)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq([H.stop_reason(a), failures(a.seen).join(",")], ["end_turn", Compaction.KIND_FAILED])
    bodies: List[JSON.Value] = []
    for _i in 1..5
      bodies = bodies.push(try body(h))
    end

    Test.eq(bodies.select { |b| contents(b).first == Compaction.SYSTEM }.size, 1)
  end
end

# A turn that a restart cuts after a fold of its older rounds keeps their text in its cancelled answer, with the text
# of the round committed after the fold, each once.
def test_a_cut_turn_keeps_the_text_of_its_folded_rounds() -> Result[Void]
  replies = ["write_file.sse", "long_text_then_write.sse", "summary.sse", "write_file.sse", "long_text_then_write.sse"]
  setup = H.Setup(replies: replies, context_window: 120)
  H.using(setup) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write two files twice.")
    for _ in 1..3
      a = try H.until(a.with(seen: []), Protocol.EventKind.ApprovalRequested)
      _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    end

    a = try H.until(a.with(seen: []), Protocol.EventKind.ApprovalRequested)
    H.close(a)
    H.restarted(h, setup, "") do |r|
      shown = (try H.session(r, id)).history
      long = (0..11).map { |n| "word#{n} " }.join("")
      written = ["I will write it.", long, "I will write it."].join("\n\n")
      Test.eq(shown.map { |m| m.text }, ["Write two files twice.", written])
    end
  end
end

# A turn that folds, then has a round under the limit, folds again when it passes the limit again.
def test_a_turn_folds_again_after_a_round_under_the_limit() -> Result[Void]
  replies = [
    "write_file.sse",
    "bash_echo.sse",
    "summary.sse",
    "bash_echo_small.sse",
    "read_file.sse",
    "summary.sse",
    "text.sse",
  ]

  H.using(H.Setup(replies: replies, context_window: 120)) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt, echo twice, then read.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    a = try H.until(a.with(seen: []), Protocol.EventKind.ApprovalRequested)
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.AllowSession)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq([H.stop_reason(a), failures(a.seen).join(",")], ["end_turn", ""])
    bodies: List[JSON.Value] = []
    for _i in 1..7
      bodies = bodies.push(try body(h))
    end

    Test.eq(bodies.select { |b| contents(b).first == Compaction.SYSTEM }.size, 2)
  end
end

# When the span takes the task of the running turn, that task goes after the summary, word for word; a later
# compaction folds the summary again.
def test_a_span_into_a_later_turn_keeps_its_task_after_the_summary() -> Result[Void]
  history = [user("first"), said("hi"), user("second"), said("call 1"), result("1"), said("call 2"), result("2")]
  span = try Compaction.span(history).to_result("no span")
  try Test.eq([span.from, span.to], [1, 5])
  folded = Compaction.apply(history, span.with(summary: "S"))
  try Test.eq(
    folded.map { |m| m.content },
    [history[0], said(Compaction.summary_text("S")), history[2], history[5], history[6]].map { |m| m.content },
  )

  try Test.eq(Compaction.span(history.take(5)).map { |c| c.to }, some(2))
  Test.eq(Compaction.span([user("only"), said("call"), result("1")]), none)
end

# The kept round loses its thinking blocks, which were bound to the history the fold replaced; its text and tool
# call stay, and the thinking of the first task, before the fold, stays too (#81).
def test_a_fold_drops_the_thinking_of_the_kept_messages() -> Result[Void]
  thought = LLM.Block.Thinking(LLM.ThinkingPart(text: "t", replay: some(JSON.from("signed"))))
  call = LLM.Block.ToolUse(LLM.ToolCall(id: "c", name: "read_file", arguments: "{}", input: JSON.object({})))
  thinking = ->(text: String) {
    LLM.Message(role: LLM.Role.Assistant, content: [thought, said(text).content[0], call])
  }

  history = [
    user("first"),
    thinking.call("hi"),
    user("second"),
    thinking.call("one"),
    result("1"),
    thinking.call("two"),
    result("2"),
  ]

  span = try Compaction.span(history).to_result("no span")
  folded = Compaction.apply(history, span.with(summary: "S"))
  try Test.eq(folded[1], said(Compaction.summary_text("S")))
  try Test.eq(folded[3].content, [said("two").content[0], call])
  Test.eq(folded.take(1), history.take(1))
end

# A summary that fails, comes back empty or is cut at the token limit is an `error` event; the turn goes on with its
# history whole and does not
# ask again, and a later turn asks again.
def test_a_failed_or_empty_summary_is_an_error_and_not_asked_again_in_the_turn() -> Result[Void]
  replies = [
    "text.sse",
    "write_file.sse",
    "400:bad_request.json",
    "write_file.sse",
    "text.sse",
    "write_file.sse",
    "summary_empty.sse",
    "text.sse",
    "write_file.sse",
    "summary_length.sse",
    "text.sse",
  ]

  H.using(H.Setup(replies: replies, context_window: 120)) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Say hello.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    _ = try H.send(h, id, "Write hello.txt twice.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.AllowSession)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    try Test.eq(H.stop_reason(a), "end_turn")
    _ = try H.send(h, id, "Once more.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    _ = try H.send(h, id, "And again.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(H.stop_reason(a), "end_turn")
    try Test.eq(failures(a.seen), [Compaction.KIND_FAILED, Compaction.KIND_FAILED, Compaction.KIND_FAILED])
    bodies: List[JSON.Value] = []
    for _i in 1..11
      bodies = bodies.push(try body(h))
    end

    try Test.eq(bodies.select { |b| contents(b).first == Compaction.SYSTEM }.size, 3)
    try Test.eq(contents(bodies[10])[1], "Say hello.")
    try Test.eq(roles(bodies[10]).select { |r| r == "user" }.size, 4)
    Test.eq((try H.session(h, id)).history.size, 8)
  end
end

private

def failures(seen: List[H.Seen]) -> List[String]
  kinds: List[String] = []
  for s in seen
    case s.event
      Protocol.Event.Error(failure) -> kinds = kinds.push(failure.kind)
      _ -> nil
    end
  end

  kinds
end

# The role and type of each item of the transcript a summary request carries.
def transcript(message: JSON.Value) -> List[String]
  items = JSON.list(JSON.parse(string(message, "content")).unwrap_or(JSON.null())).unwrap_or(messages(JSON.null()))
  items.map { |item| "#{string(item, "role")} #{string(item, "type")}" }
end

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

def user(text: String) -> LLM.Message
  LLM.Message(role: LLM.Role.User, content: [LLM.Block.Text(LLM.TextPart(text: text))])
end

def said(text: String) -> LLM.Message
  LLM.Message(role: LLM.Role.Assistant, content: [LLM.Block.Text(LLM.TextPart(text: text))])
end

def result(text: String) -> LLM.Message
  LLM.Message(role: LLM.Role.User, content: [LLM.Block.ToolResult(LLM.ToolOutput(tool_use_id: "c", content: text))])
end

def summary() -> String = "Summary of the session so far:\n\nThe user said hello and the agent greeted back."
