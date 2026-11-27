import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import Store from "../src/session/store"
import Spill from "../src/tools/spill"
import Tools from "../src/tools/tools"
import H from "support/harness"

LIMIT = 1_048_576
LARGE_ERROR = "é" * 33_000 + "END"
ERROR_ID = "e83feb292a0270cf910564ab1e020fef1c60c03d5db4dbbd123ed5c5b70a6a64"
OLD_CALLS = 24

# The next request of an old session would exceed the cap even though each output was small. The first and
# second model calls in the resumed turn go through, and the only tool actually run is its new call.
def test_an_oversized_saved_history_does_not_poison_the_next_turn() -> Result[Void]
  calls: ATS[String, Int] = ATS.new()
  tool = echo(-> { counted(calls) })
  setup = H.Setup(replies: ["mcp_echo.sse", "text.sse"], tools: [tool], confine: true)
  H.using(setup) do |h|
    id = try H.new_session(h)
    file = session_file(h, id)
    try Store.append_user(file, "Original question.", "Original question.")
    try Store.append_messages(file, old_round())
    H.restarted(h, setup, "") do |r|
      try finished(r, id, "Can we continue?")
      first = try wire(r)
      second = try wire(r)
      carried = first.select { |m| field(m, "role") == "tool" }
      try Test.eq(carried.map { |m| field(m, "tool_call_id") }, (1..OLD_CALLS).map { |i| "old-#{i}" })
      try Test.assert(field(carried.first, "content").start_with?(Spill.MARKER), "no artifact reference")
      try Test.eq(field(first.last, "content"), "Can we continue?")
      try Test.eq(field(second.last, "content"), "ran exactly once")
      try Test.eq(calls.get("ran"), ok(1))
      id_of_output = OpenSSL.Digest.sha256_hexdigest(old_output(1).bytes)
      Test.eq(Store.artifacts(file).read.call(id_of_output), ok(old_output(1)))
    end
  end
end

# Save a failed tool call before the old generic output cap cuts it, and read its tail after a restart even
# when file access is confined. The private sibling file is not opened as a user-supplied path.
def test_a_large_error_spills_and_its_unicode_tail_reads_after_resume() -> Result[Void]
  tool = echo(-> { error(LARGE_ERROR) })
  setup = H.Setup(
    replies: ["mcp_echo.sse", "text.sse", "read_tool_output.sse", "text.sse"],
    tools: [tool],
    confine: true,
  )

  H.using(setup) do |h|
    id = try H.new_session(h)
    try finished(h, id, "Try it.")
    _ = try wire(h)
    after = try wire(h)
    result = field(after.last, "content")
    try Test.assert(result.start_with?("Error: #{Spill.MARKER}#{ERROR_ID}]"), "failed result lost its artifact")
    try Test.assert(not result.end_with?("END"), "tail leaked into preview")
    path = "#{H.session_file(h, id)}.tool-#{ERROR_ID}"
    try Test.eq((try File.stat(path)).mode % 512, 384)
    saved = try Store.load(session_file(h, id))
    try Test.eq(saved.history.flat_map { |m| m.content }.select(&failed?).size, 1)
    H.restarted(h, setup, "") do |r|
      try finished(r, id, "Check the rest.")
      _ = try wire(r)
      page = try wire(r)
      Test.eq(field(page.last, "content"), "[characters 32768–33003 of 33003; end of output]\n#{"é" * 232}END")
    end
  end
end

def test_an_unavailable_artifact_store_returns_a_bounded_notice() -> Result[Void]
  no_disk = Spill.Port(save: ->(_text) { error("disk full") }, read: ->(_id) { error("not found") })
  text = Spill.saved(LARGE_ERROR, some(no_disk), 10)
  Test.eq(text, "[tool output shortened: 66003 bytes; the rest was not saved.]\n#{"é" * 10}")
end

def test_a_copied_branch_keeps_its_artifacts_when_the_source_is_deleted() -> Result[Void]
  header = Store.Header(id: "source", cwd: "/repo", model: "model", created_ms: 0)
  file = try Store.create(Store.memory(["/data"]), "/data", header)
  port = Store.artifacts(file)
  mentioned = try port.save.call("saved result")
  hidden = try port.save.call("unrelated result")
  try Store.append_user(file, "The saved output is #{mentioned}.")
  copy = try Store.copy(file, "/data", header.with(id: "fork"), (try Store.entries(file)).leaf)
  try Store.remove(file)
  try Test.eq(port.read.call(mentioned).ok?, false)
  try Test.eq(Store.artifacts(copy).read.call(mentioned), ok("saved result"))
  Test.eq(Store.artifacts(copy).read.call(hidden).ok?, false)
end

# The summary request encodes a transcript as a string inside the regular provider request. Its byte cap can
# fail on the extra escaping even though the transcript already cuts individual texts.
def test_an_oversized_compaction_transcript_also_shortens_tool_results() -> Result[Void]
  setup = H.Setup(replies: ["summary.sse"])
  H.using(setup) do |h|
    id = try H.new_session(h)
    file = session_file(h, id)
    try Store.append_user(file, "First question.")
    for _i in 1..4
      try Store.append_messages(file, old_round())
    end

    try Store.append_user(file, "Follow-up question.")
    H.restarted(h, setup, "") do |r|
      folded = try H.post(r, Protocol.compact_path(id), "")
      try Test.eq(Protocol.decode_compacted(folded.text), ok(Protocol.Compacted(compacted: true)))
      asked = try wire(r)
      Test.assert(field(asked.last, "content").include?(Spill.MARKER), "summary got inline output")
    end
  end
end

def old_round() -> List[LLM.Message]
  calls = (1..OLD_CALLS).map do |i|
    LLM.Block.ToolUse(LLM.ToolCall(id: "old-#{i}", name: "mcp__fake__echo", arguments: "{}", input: JSON.object({})))
  end

  results = (1..OLD_CALLS).map do |i|
    LLM.Block.ToolResult(LLM.ToolOutput(tool_use_id: "old-#{i}", content: old_output(i), is_error: false))
  end

  [LLM.Message(role: LLM.Role.Assistant, content: calls), LLM.Message(role: LLM.Role.User, content: results)]
end

def old_output(i: Int) -> String = String.from_code(1) * 8000 + "#{i}"

def echo(answer: Fn[Result[String]]) -> Tools.Tool
  Tools.Tool(
    name: "mcp__fake__echo",
    description: "Echo the input",
    input_schema: JSON.object({}),
    asks: false,
    run: ->(_ctx, _input) { answer.call() },
    target: ->(_ctx, _input) { ok("echo") },
  )
end

def counted(calls: ATS[String, Int]) -> Result[String]
  _ = calls.add("ran", 1)
  ok("ran exactly once")
end

def finished(h: H.Harness, id: String, text: String) -> Result[Void]
  a = try H.subscribe(h, id, some((try H.session(h, id)).last_event_id))
  _ = try H.send(h, id, text)
  ended = try H.until(a, Protocol.EventKind.TurnFinished)
  H.close(ended)
  Test.eq(H.stop_reason(ended), "end_turn")
end

def wire(h: H.Harness) -> Result[List[JSON.Value]]
  request = try H.next_request(h)
  try Test.assert(request.body.bytesize <= LIMIT, "the provider received an oversized request")
  JSON.list(try JSON.get(try JSON.parse(request.body), "messages"))
end

def field(value: JSON.Value, key: String) -> String
  JSON.string(JSON.get(value, key).unwrap_or(JSON.null())).unwrap_or("")
end

def failed?(block: LLM.Block) -> Bool
  case block
    LLM.Block.ToolResult(result) -> result.is_error
    _ -> false
  end
end

def session_file(h: H.Harness, id: String) -> Store.Ref = Store.Ref(port: Store.disk(), path: H.session_file(h, id))
