import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import Compaction from "../src/agent/compaction"
import Store from "../src/session/store"

LINEAR = "tests/fixtures/sessions/linear.jsonl"

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
        LLM.Block.Thinking(LLM.ThinkingPart(text: "plan", replay: some(replay), source: "local/openai")),
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
    try Test.eq(back.role, message.role)
    try Test.eq(back.content.map { |b| block_kind(b) }, message.content.map { |b| block_kind(b) })
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

# A record longer than a load reads is refused, and the file keeps what it had.
def test_a_record_over_the_line_limit_is_refused() -> Result[Void]
  dir = try temp_dir()
  result = too_long(dir)
  _ = Path.remove(dir)
  result
end

# A file written before sessions were trees loads as it did: one branch, the turns of every record.
def test_a_session_file_of_the_linear_format_still_loads() -> Result[Void]
  saved = try Store.load(LINEAR)
  try Test.eq([saved.skipped, saved.users, saved.last_id, saved.reserved], [0, 2, 1005, 0])
  try Test.eq(saved.shown.map { |m| m.text }, ["Hi", "Hi!", "Again.", "Yes."])
  try Test.eq(saved.history.size, 4)
  try Test.eq(saved.events.map { |l| l.id }, [1, 1002, 1003, 1004, 1005])
  try Test.eq([saved.model, saved.effort], [some("m2"), some("low")])
  try Test.eq(saved.usage.map { |u| u.session_cost }, some(some(0.5)))
  tree = Store.tree(try Store.entries(LINEAR))
  nodes = [
    Protocol.TreeNode(id: 1, text: "Hi", answer: "Hi!", last: 7, active: true),
    Protocol.TreeNode(id: 9, parent: some(1), text: "Again.", answer: "Yes.", last: 13, active: true),
  ]

  Test.eq(tree.nodes, nodes)
end

# A branch goes back before a message and the next records follow it; a branch to the end of a turn goes on from there.
# A tree read again reads only the lines added since, and is the tree a whole read gives. The ids, the turns, the
# settings and the cost stay those of the whole file, the end of a turn stays where it was, and a copy keeps one
# branch.
def test_a_branch_replays_its_own_records() -> Result[Void]
  dir = try temp_dir()
  result = branches(dir)
  _ = Path.remove(dir)
  result
end

# A tree read while the last line has no newline yet leaves it out; the read after it is written whole has it, as a
# whole read does. A node keeps the first line of its answer.
def test_a_tree_read_leaves_a_line_still_being_written() -> Result[Void]
  dir = try temp_dir()
  result = partial_line(dir)
  _ = Path.remove(dir)
  result
end

private

def partial_line(dir: String) -> Result[Void]
  path = "#{dir}/s1-0123.jsonl"
  try File.write_text(path, try File.read_text(LINEAR))
  known = try Store.entries(path)
  try File.append_text(path, "{\"type\":\"user\",\"te")
  partial = try Store.entries(path, some(known))
  try Test.eq([partial.lines, partial.size], [known.lines, known.size])
  try Test.eq(Store.tree(partial), Store.tree(known))
  try File.append_text(path, "xt\":\"Late.\"}\n")
  try Store.append_answer(path, "first line\nsecond line")
  whole = try Store.entries(path, some(partial))
  nodes = Store.tree(whole).nodes
  try Test.eq(nodes.map { |n| n.text }, ["Hi", "Again.", "Late."])
  try Test.eq(nodes.last.answer, "first line")
  Test.eq(Store.tree(whole), Store.tree(try Store.entries(path)))
end

def branches(dir: String) -> Result[Void]
  path = "#{dir}/s1-0123.jsonl"
  try File.write_text(path, try File.read_text(LINEAR))
  known = try Store.entries(path)
  before = try Store.point(known, some(9))
  try Test.eq(before, Store.Point(leaf: 8, text: "Again."))
  try Test.error?(Store.point(known, some(3)))
  try Store.append_branch(path, before.leaf, 1006)
  try Store.append_user(path, "Other.")
  try Store.append_event(path, started(1007))
  try Store.append_answer(path, "Sure.")
  try Store.append_settings(path, Store.Choice(model: "m3", effort: none, provider: "fw", api: "openai"))
  moved = try Store.load(path)
  try Test.eq(moved.shown.map { |m| m.text }, ["Hi", "Hi!", "Other.", "Sure."])
  try Test.eq([moved.history.size, moved.users, moved.turns, moved.last_id, moved.skipped], [3, 2, 3, 1007, 0])
  try Test.eq([moved.model, moved.effort, moved.provider, moved.api], [some("m3"), none, some("fw"), some("openai")])
  known = try Store.entries(path, some(known))
  tree = Store.tree(known).nodes
  try Test.eq(tree, Store.tree(try Store.entries(path)).nodes)
  try Test.eq(tree.map { |n| "#{n.id}<#{n.parent.unwrap_or(0)} #{n.active}" }, ["1<0 true", "9<1 false", "16<1 true"])
  try Store.append_branch(path, (try Store.point(known, some(tree[1].last))).leaf, 1008)
  back = try Store.load(path)
  try Test.eq(back.shown.map { |m| m.text }, ["Hi", "Hi!", "Again.", "Yes."])
  try Test.eq([back.events.size, back.last_id, back.reserved], [5, 1007, 1008])
  try Store.append_settings(path, Store.Choice(model: "m4", effort: none, provider: "local", api: "openai"))
  known = try Store.entries(path, some(known))
  try Test.eq(Store.tree(known), Store.tree(try Store.entries(path)))
  try Test.eq(Store.tree(known).nodes.map { |n| n.last }, tree.map { |n| n.last })
  try Test.eq((try Store.point(known, some(tree[0].last))).leaf, tree[0].last)
  header = Store.Header(id: "s2-4567", cwd: "/work", model: "m", created_ms: 8)
  copy = try Store.copy(path, dir, header, (try Store.point(known, none)).leaf)
  copied = try Store.load(copy)
  try Test.eq(copied.shown, back.shown)
  try Test.assert(not (try File.read_text(copy)).include?("branch"), "a copy keeps the branch records")
  Test.eq(Store.tree(try Store.entries(copy)).nodes.map { |n| n.text }, ["Hi", "Again."])
end

# The answer a compaction keeps belongs to its turn: the next turn starts without it. An `answer` of the wrong type is
# left out, not the compaction.
def test_a_folded_answer_belongs_to_its_turn() -> Result[Void]
  dir = try temp_dir()
  result = folded_answers(dir)
  _ = Path.remove(dir)
  result
end

def folded_answers(dir: String) -> Result[Void]
  path = try Store.create(dir, Store.Header(id: "s1-cd", cwd: "/work", model: "m", created_ms: 7))
  try Store.append_user(path, "one")
  try Store.append_event(path, started(1))
  try Store.append_messages(path, [said("first answer")])
  try Store.append_compaction(path, Compaction.Compaction(from: 1, to: 2, summary: "s"), ["first answer"])
  folded = try Store.load(path)
  try Test.eq(folded.folded, some(Store.Folded(texts: ["first answer"], at: 2)))
  try Store.append_answer(path, "first answer")
  try Store.append_user(path, "two")
  try Store.append_event(path, started(2))
  try Test.eq((try Store.load(path)).folded, none)
  try File.append_text(path, "{\"type\":\"compaction\",\"from\":1,\"to\":2,\"summary\":\"again\",\"answer\":5}\n")
  again = try Store.load(path)
  try Test.eq([again.skipped, again.history.size], [0, 3])
  try Test.assert(Compaction.transcript([again.history[1]]).include?("again"), "the compaction was left out")
  Test.eq(again.folded, none)
end

def said(text: String) -> LLM.Message
  LLM.Message(role: LLM.Role.Assistant, content: [LLM.Block.Text(LLM.TextPart(text: text))])
end

def too_long(dir: String) -> Result[Void]
  path = try Store.create(dir, Store.Header(id: "s1-ab", cwd: "/work", model: "m", created_ms: 7))
  try Test.error?(Store.append_user(path, "x" * Store.MAX_LINE_BYTES))
  try Store.append_user(path, "x" * (Store.MAX_LINE_BYTES - 100))
  saved = try Store.load(path)
  Test.eq([saved.users, saved.skipped], [1, 0])
end

def block_kind(block: LLM.Block) -> String
  case block
    LLM.Block.Text(part) -> "text #{part.text} #{part.replay.some?}"
    LLM.Block.Thinking(part) -> "thinking #{part.text} #{part.replay.some?} #{part.source}"
    LLM.Block.ToolUse(call) ->
      "tool_use #{call.id} #{call.name} #{call.input_error.some?} #{call.kind == LLM.ToolKind.Custom}"
    LLM.Block.ToolResult(output) -> "tool_result #{output.tool_use_id} #{output.content} #{output.is_error}"
  end
end

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
  try Store.append_compaction(path, Compaction.Compaction(from: 1, to: 3, summary: "past the end"), [])
  try Test.eq([(try Store.load(path)).skipped, (try Store.load(path)).history.size], [5, 1])
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
