import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import Compaction from "../src/agent/compaction"
import Storage from "../src/session/storage"
import Store from "../src/session/store"

LINEAR = "tests/fixtures/sessions/linear.jsonl"
NO_TIME = "tests/fixtures/sessions/no_time.jsonl"
MEMORY = "/memory"
CALLS = 2000
BUILD_MS = 500
SESSION_BYTES = 1_048_576

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
def test_a_load_skips_broken_lines_and_reopen_ends_a_cut_one() -> Result[Void] = on_both(&broken_lines)

# A record longer than a load reads is refused, and the file keeps what it had.
def test_a_record_over_the_line_limit_is_refused() -> Result[Void] = on_both(&too_long)

# A file written before sessions were trees loads as it did: one branch, the turns of every record.
def test_a_session_file_of_the_linear_format_still_loads() -> Result[Void]
  linear = Store.Ref(port: Store.disk(), path: LINEAR)
  saved = try Store.load(linear)
  try Test.eq([saved.skipped, saved.users, saved.last_id, saved.reserved], [0, 2, 1005, 0])
  try Test.eq(saved.shown.map { |m| m.text }, ["Hi", "Hi!", "Again.", "Yes."])
  try Test.eq(saved.history.size, 4)
  try Test.eq(saved.events.map { |l| l.id }, [1, 1002, 1003, 1004, 1005])
  try Test.eq([saved.model, saved.effort], [some("m2"), some("low")])
  try Test.eq(saved.usage.map { |u| u.session_cost }, some(some(0.5)))
  tree = Store.tree(try Store.entries(linear))
  nodes = [
    Protocol.TreeNode(id: 1, text: "Hi", answer: "Hi!", last: 7, active: true),
    Protocol.TreeNode(id: 9, parent: some(1), text: "Again.", answer: "Yes.", last: 13, active: true),
  ]

  Test.eq(tree.nodes, nodes)
end

# A session of an early version has no time in its header: it loads, as the oldest.
def test_a_session_file_without_a_time_still_loads() -> Result[Void]
  saved = try Store.load(Store.Ref(port: Store.disk(), path: NO_TIME))
  Test.eq([saved.header.id, "#{saved.header.created_ms}"], ["s1-0123", "0"])
end

# A branch goes back before a message and the next records follow it; a branch to the end of a turn goes on from there.
# A tree read again reads only the lines added since, and is the tree a whole read gives. The ids, the turns, the
# settings and the cost stay those of the whole file, the end of a turn stays where it was, and a copy keeps one
# branch.
def test_a_branch_replays_its_own_records() -> Result[Void] = on_both(&branches)

# A replace of a path that is a symbolic link writes the file it points to and keeps the link; no temporary file stays.
def test_a_replace_follows_a_symbolic_link_and_keeps_it() -> Result[Void]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/agc-store-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  real = "#{dir}/real.json"
  link = "#{dir}/link.json"
  try File.write_text(real, "old\n")
  try Process.wait(try Process.spawn("ln", ["-s", real, link]), 5000)
  port = Storage.disk(1024, 1_048_576)
  try port.replace.call(link, "new\n")
  kind = (try File.lstat(link)).kind
  names = (try Dir.list(dir)).sort
  text = try File.read_text(real)
  _ = Path.remove(link)
  _ = Path.remove(real)
  _ = Path.remove(dir)
  try Test.eq(kind, "link")
  try Test.eq(text, "new\n")
  Test.eq(names, ["link.json", "real.json"])
end

# The memory adapter answers as the disk one: the same error kinds, a line limit that counts the newline, CRLF read as
# a line end, a folder with a trailing `/`, no file in a folder that is not there, and an append that makes a file.
def test_the_memory_store_answers_as_the_disk_one() -> Result[Void]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/agc-store-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  on_disk = answers(Storage.disk(1024, 1_048_576), dir)
  _ = Path.remove(dir)
  in_memory = answers(Storage.memory(1024, [dir]), dir)
  expected = [
    "ok", "io.exists", "io.not_found", "io.not_found", "a b e long", "io.too_large", "ok", "x|y\r", "x", "io.eof",
    "io.not_found", "io.not_found", "io.not_found", "ok", "z\n", "io.not_found",
  ]

  try Test.eq(on_disk, expected)
  Test.eq(in_memory, expected)
end

# The session files of a folder are its own `.jsonl` files, not those of another folder or of another kind.
def test_the_sessions_of_a_folder_are_its_session_files() -> Result[Void] = on_both(&listed)

# A tree read while the last line has no newline yet leaves it out; the read after it is written whole has it, as a
# whole read does. A node keeps the first line of its answer.
def test_a_tree_read_leaves_a_line_still_being_written() -> Result[Void] = on_both(&partial_line)

def test_a_saved_prompt_leaves_the_title_visible() -> Result[Void] = on_both(&saved_prompt)

private

def saved_prompt(port: Store.Port, dir: String) -> Result[Void]
  initial = Store.Prompt(base: "x" * (Store.TITLE_BYTES / 2 + 1), catalog: "old", skill_config: "old")
  header = Store.Header(id: "s1-ab", cwd: "/work", model: "m", created_ms: 7, prompt: some(initial))
  file = try Store.create(port, dir, header)
  updated = initial.with(catalog: "new", skill_config: "new")
  try Store.save_prompt(file, updated)
  try Store.append_user(file, "Session title")
  try Test.eq((try Store.listing(file)).title, "Session title")
  try Test.eq((try Store.load(file)).header.prompt, some(updated))
  try Store.save_prompt(file, (try Store.load(file)).header.prompt.unwrap!)
  try Test.error?(Store.save_prompt(file, updated.with(base: "x" * Store.MAX_LINE_BYTES)))
  try Test.eq((try Store.load(file)).header.prompt, some(updated))
  try Store.remove(file)
  try Test.error?(Store.save_prompt(file, updated))
  Test.eq(try port.names.call(dir), [])
end

def partial_line(port: Store.Port, dir: String) -> Result[Void]
  path = try linear_in(port, dir)
  known = try Store.entries(path)
  try port.append.call(path.path, "{\"type\":\"user\",\"te")
  partial = try Store.entries(path, some(known))
  try Test.eq([partial.lines, partial.size], [known.lines, known.size])
  try Test.eq(Store.tree(partial), Store.tree(known))
  try port.append.call(path.path, "xt\":\"Late.\"}\n")
  try Store.append_answer(path, "first line\nsecond line")
  whole = try Store.entries(path, some(partial))
  nodes = Store.tree(whole).nodes
  try Test.eq(nodes.map { |n| n.text }, ["Hi", "Again.", "Late."])
  try Test.eq(nodes.last.answer, "first line")
  Test.eq(Store.tree(whole), Store.tree(try Store.entries(path)))
end

def branches(port: Store.Port, dir: String) -> Result[Void]
  path = try linear_in(port, dir)
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
  try Test.assert(not (try port.read_text.call(copy.path)).include?("branch"), "a copy keeps the branch records")
  Test.eq(Store.tree(try Store.entries(copy)).nodes.map { |n| n.text }, ["Hi", "Again."])
end

# The answer a compaction keeps belongs to its turn: the next turn starts without it. An `answer` of the wrong type is
# left out, not the compaction.
def test_a_folded_answer_belongs_to_its_turn() -> Result[Void] = on_both(&folded_answers)

def folded_answers(port: Store.Port, dir: String) -> Result[Void]
  path = try Store.create(port, dir, Store.Header(id: "s1-cd", cwd: "/work", model: "m", created_ms: 7))
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
  try port.append.call(path.path, "{\"type\":\"compaction\",\"from\":1,\"to\":2,\"summary\":\"again\",\"answer\":5}\n")
  again = try Store.load(path)
  try Test.eq([again.skipped, again.history.size], [0, 3])
  try Test.assert(Compaction.transcript([again.history[1]]).include?("again"), "the compaction was left out")
  Test.eq(again.folded, none)
end

def said(text: String) -> LLM.Message
  LLM.Message(role: LLM.Role.Assistant, content: [LLM.Block.Text(LLM.TextPart(text: text))])
end

def too_long(port: Store.Port, dir: String) -> Result[Void]
  path = try Store.create(port, dir, Store.Header(id: "s1-ab", cwd: "/work", model: "m", created_ms: 7))
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

def broken_lines(port: Store.Port, dir: String) -> Result[Void]
  header = Store.Header(id: "s1-ab", cwd: "/work", model: "m", created_ms: 7)
  path = try Store.create(port, dir, header)
  if dir != MEMORY
    try Test.eq((try File.stat(path.path)).mode % 512, 384)
  end

  try Test.error?(Store.create(port, dir, header))
  try Store.append_user(path, "Hello.")
  try Store.append_event(path, started(1))
  try port.append.call(path.path, "not json\n{\"type\":\"event\",\"id\":2,\"name\":\"no_such_event\",\"data\":{}}\n")
  try port.append.call(path.path, "{\"type\":\"wat\"}\n")
  try Store.append_answer(path, "Hi!")
  clean = try Store.load(path)
  try Test.eq([clean.skipped, clean.events.size], [3, 1])
  try Test.eq(clean.open_end, false)
  try port.append.call(path.path, "{\"type\":\"event\",\"id\":2,\"na")
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

# The scenario on disk, in a folder of its own, and in memory.
def listed(port: Store.Port, dir: String) -> Result[Void]
  for name in ["a.jsonl", "b.jsonl", "notes.txt"]
    try port.create.call("#{dir}/#{name}", "{}\n")
  end

  # A folder whose name starts with this one's: only the memory adapter can hold one without making it.
  if dir == MEMORY
    try port.create.call("#{dir}x/c.jsonl", "{}\n")
  end

  found = try Store.all(port, dir)
  Test.eq(found.map { |r| r.path }.sort, ["#{dir}/a.jsonl", "#{dir}/b.jsonl"])
end

def answers(port: Storage.Port, dir: String) -> List[String]
  first = [
    kind(port.create.call("#{dir}/a", "#{"x" * 1023}\n")),
    kind(port.create.call("#{dir}/a", "")),
    kind(port.create.call("#{dir}/missing/c", "")),
    kind(port.names.call("#{dir}/missing")),
  ]

  _ = port.create.call("#{dir}/b", "x\r\ny\r")
  _ = port.create.call("#{dir}/long", "#{"x" * 1024}\n")
  _ = port.create.call("#{dir}/e", "")
  no_names: List[String] = []
  names = port.names.call("#{dir}/").unwrap_or(no_names).sort.join(" ")
  lines = "?"
  case port.read.call("#{dir}/b")
    ok(content) -> lines = content.lines.join("|")
    error(_) -> nil
  end

  (
    first +
    [
      names,
      kind(port.read.call("#{dir}/long")),
      kind(port.read.call("#{dir}/a")),
      lines,
      port.first_line.call("#{dir}/b").unwrap_or("?"),
      kind(port.first_line.call("#{dir}/e")),
      kind(port.read.call("#{dir}/none")),
      kind(port.remove.call("#{dir}/none")),
      kind(port.read_text.call("#{dir}/none")),
      kind(port.append.call("#{dir}/added", "z\n")),
      port.read_text.call("#{dir}/added").unwrap_or("?"),
      kind(port.append.call("#{dir}/missing/d", "z\n")),
    ]
  )
end

def kind[T](result: Result[T]) -> String
  case result
    ok(_) -> "ok"
    error(e) -> e.kind
  end
end

# The history of a session of 2000 tool calls, each with a long output, is built in a short time by what both a load
# and a running session use, and a session with it stays far under the limit of a client's read: a line of each call,
# without its output.
def test_the_history_of_many_tool_calls_is_built_fast_and_small() -> Result[Void]
  output = "x" * 4000
  rounds: List[List[Protocol.Event]] = []
  said: List[LLM.Message] = []
  for n in 1..CALLS
    call_id = "c#{n}"
    started = Protocol.ToolStarted(call_id: call_id, name: "bash", summary: "echo #{n}")
    done = Protocol.ToolFinished(call_id: call_id, ok: true, summary: "ok", duration_ms: 1, output: some(output))
    rounds = rounds.push([Protocol.Event.ToolStarted(started), Protocol.Event.ToolFinished(done)])
    call = LLM.ToolCall(id: call_id, name: "bash", arguments: "{}", input: try JSON.parse("{}"))
    blocks = [LLM.Block.Thinking(LLM.ThinkingPart(text: "Step #{n}.")), LLM.Block.ToolUse(call)]
    said = said.push(LLM.Message(role: LLM.Role.Assistant, content: blocks))
  end

  began = Time.monotonic_ms
  shown = [Protocol.Message(role: Protocol.Role.User, text: "Go.")]
  for n in 0...CALLS
    for event in rounds[n]
      shown = Store.shown_after(shown, event)
    end

    shown = Store.with_thinking(shown, [said[n]])
  end

  took = Time.monotonic_ms - began
  snapshot = Protocol.Session(
    id: "s1",
    cwd: "/",
    model: "m",
    last_event_id: 2 * CALLS,
    turn_id: none,
    turn_from_event_id: none,
    pending_approvals: [],
    history: shown,
  )

  bytes = Protocol.encode_session(snapshot).bytes.size
  try Test.eq(
    [shown.size.to_s, shown[1].text, shown.last.tool.map { |t| t.call_id }.unwrap_or("")],
    ["#{1 + 2 * CALLS}", "Step 1.", "c#{CALLS}"],
  )

  try Test.eq(shown.last.done.map { |d| [d.summary, d.output.unwrap_or("none")] }, some(["ok", "none"]))
  try Test.assert(took < BUILD_MS, "the history took #{took} ms")
  Test.assert(bytes < SESSION_BYTES, "the session is #{bytes} bytes")
end

# In code mode the tool calls of a script have ids under its own (`c1.77`): the round's thinking still goes before all
# of them, as it came live.
def test_the_thinking_of_a_round_goes_before_the_calls_of_its_script() -> Result[Void]
  shown = [Protocol.Message(role: Protocol.Role.User, text: "go")]
  for call_id in ["c1", "c1.77", "c1.88"]
    started = Protocol.ToolStarted(call_id: call_id, name: "run_script", summary: "")
    shown = Store.shown_after(shown, Protocol.Event.ToolStarted(started))
  end

  script = LLM.ToolCall(id: "c1", name: "run_script", arguments: "{}", input: try JSON.parse("{}"))
  blocks = [LLM.Block.Thinking(LLM.ThinkingPart(text: "thinking")), LLM.Block.ToolUse(script)]
  thought = Store.with_thinking(shown, [LLM.Message(role: LLM.Role.Assistant, content: blocks)])
  lines = thought.map { |m| m.tool.map { |t| t.call_id }.unwrap_or(m.text) }
  Test.eq(lines, ["go", "thinking", "c1", "c1.77", "c1.88"])
end

def on_both(scenario: Fn[Store.Port, String, Result[Void]]) -> Result[Void]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/agc-store-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  on_disk = scenario.call(Store.disk(), dir)
  _ = Path.remove(dir)
  try on_disk
  scenario.call(Store.memory([MEMORY, "#{MEMORY}x"]), MEMORY)
end

def linear_in(port: Store.Port, dir: String) -> Result[Store.Ref]
  path = "#{dir}/s1-0123.jsonl"
  try port.create.call(path, try File.read_text(LINEAR))
  ok(Store.Ref(port: port, path: path))
end
