import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import Store from "../src/store"

# Every kind of block reads back as it was written, so the history a restart gives the model is the same.
def test_a_message_reads_back_with_every_kind_of_block() -> Result[Void]
  replay = try JSON.parse("{\"signature\":\"sig-1\",\"items\":[1,2]}")
  bad = LLM.ToolCall(
    id: "c2",
    name: "apply_patch",
    arguments: "*** Begin",
    input: try JSON.parse("{}"),
    input_error: some("not a JSON object"),
    kind: LLM.ToolKind.Custom,
    replay: some(replay),
  )

  good = LLM.ToolCall(
    id: "c1",
    name: "bash",
    arguments: "{\"command\":\"ls\"}",
    input: try JSON.parse("{\"command\":\"ls\"}"),
  )

  messages = [
    LLM.Message(role: LLM.Role.User, content: [LLM.Block.Text(LLM.TextPart(text: "Hi \"there\"\n"))]),
    LLM.Message(
      role: LLM.Role.Assistant,
      content: [
        LLM.Block.Thinking(LLM.ThinkingPart(text: "plan", replay: some(replay))),
        LLM.Block.Text(LLM.TextPart(text: "ok", replay: some(replay))),
        LLM.Block.ToolUse(good),
        LLM.Block.ToolUse(bad),
      ],
    ),
    LLM.Message(
      role: LLM.Role.User,
      content: [
        LLM.Block.ToolResult(LLM.ToolOutput(tool_use_id: "c1", content: "a\nb", is_error: false)),
        LLM.Block.ToolResult(LLM.ToolOutput(tool_use_id: "c2", content: "bad input", is_error: true)),
      ],
    ),
  ]

  for message in messages
    json = Store.encode_message(message)
    back = try Store.decode_message(json)
    try Test.eq(JSON.encode(Store.encode_message(back)), JSON.encode(json))
  end

  back = try Store.decode_message(Store.encode_message(messages[1]))
  case back.content[3]
    LLM.Block.ToolUse(call) ->
      try Test.eq([call.id, call.arguments, call.input_error.unwrap_or("")], ["c2", "*** Begin", "not a JSON object"])
      try Test.eq(call.kind == LLM.ToolKind.Custom, true)
      Test.eq(call.replay.map { |r| JSON.encode(r) }, some(JSON.encode(replay)))
    _ -> Test.assert(false, "not a tool use")
  end
end

# A crash can cut the last line and leave a line that does not parse; a record of a kind or event it does not know is
# skipped too. The rest loads, and after `reopen` the next record starts on a line of its own.
def test_a_load_skips_broken_lines_and_reopen_ends_a_cut_one() -> Result[Void]
  dir = try temp_dir()
  result = broken_lines(dir)
  _ = Path.remove(dir)
  result
end

private

def broken_lines(dir: String) -> Result[Void]
  header = Store.Header(id: "s1-ab", cwd: "/work", model: "m", created_ms: 7)
  path = try Store.create(dir, header)
  try Test.eq((try File.stat(path)).mode % 512, 384)
  try Test.error?(Store.create(dir, header))
  try Store.append_user(path, "Hello.")
  try Store.append_event(path, started(1))
  try File.append_text(path, "not json\n{\"type\":\"event\",\"id\":2,\"name\":\"no_such_event\",\"data\":{}}\n")
  try File.append_text(path, "{\"type\":\"wat\"}\n")
  try Store.append_answer(path, "Hi!")
  clean = try Store.load(path)
  try Test.eq([clean.skipped, clean.events.size], [3, 1])
  try Test.eq(clean.open_end, false)
  try File.append_text(path, "{\"type\":\"event\",\"id\":2,\"na")
  cut = try Store.load(path)
  try Test.eq([cut.skipped, cut.events.size], [4, 1])
  try Test.eq(cut.open_end, true)
  try Store.reopen(path)
  try Store.append_event(path, started(2))
  again = try Store.load(path)
  try Test.eq(again.header, header)
  try Test.eq([again.skipped, again.events.size, again.history.size], [4, 2, 1])
  try Test.eq(again.open_end, false)
  try Test.eq(again.events.map { |l| l.id }, [1, 2])
  Test.eq(again.shown.map { |m| "#{Protocol.role_name(m.role)}: #{m.text}" }, ["user: Hello.", "assistant: Hi!"])
end

def started(id: Int) -> Store.Logged
  Store.Logged(id: id, event: Protocol.Event.TurnStarted(Protocol.TurnStarted(turn_id: "turn-#{id}")))
end

def temp_dir() -> Result[String]
  tmp = System.env("TMPDIR").unwrap_or("/tmp")
  dir = "#{tmp}/agc-store-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  ok(dir)
end
