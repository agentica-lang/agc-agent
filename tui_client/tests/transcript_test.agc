import Protocol from "pkg/protocol/protocol"
import Markdown from "../src/markdown"
import Prompt from "../src/prompt"
import Transcript from "../src/transcript"
import Width from "../src/width"

def test_wrap_cuts_at_spaces_and_splits_long_words() -> Result[Void]
  try Test.eq(Transcript.wrap("the quick brown fox", 9), ["the quick", "brown fox"])
  try Test.eq(Transcript.wrap("abcdefghij", 4), ["abcd", "efgh", "ij"])
  try Test.eq(Transcript.wrap("one\n\ntwo", 10), ["one", "", "two"])
  Test.eq(Transcript.wrap("日本語 テキスト", 7), ["日本語", "テキス", "ト"])
end

def test_width_counts_wide_and_zero_width_characters() -> Result[Void]
  try Test.eq(Width.text("aé日本"), 6)
  try Test.eq(Width.text("e" + String.from_code(0x301)), 1)
  try Test.eq(Width.cut("日本語", 5), ["日本", "語"])
  try Test.eq(["🚀", "✅", "⚙", "🇪🇸", "🦀"].map { |text| Width.text(text) }, [2, 2, 1, 2, 2])
  try Test.eq(Width.text("ש" + String.from_code(0x5b0) + "x" + String.from_code(0x20d7)), 2)
  # A ZWJ sequence: each emoji takes its own columns.
  family = ["👨", "👩", "👧"].join(String.from_code(0x200d))
  try Test.eq(Width.text(family), 6)
  try Test.eq(Width.cut("a#{family}b", 5), ["a👨" + String.from_code(0x200d) + "👩" + String.from_code(0x200d), "👧b"])
  Test.eq(Width.text("x⚙" + String.from_code(0xfe0f)), 2)
end

# The values of glibc's wcwidth(3), which agentica-tui draws with; not printable is U+FFFD, one column.
def test_width_follows_wcwidth() -> Result[Void]
  wide = [0x1f680, 0x2614, 0x26a1, 0x2705, 0x27bf, 0x1fa70, 0x1f468, 0x4e00, 0xac00, 0x20000]
  zero = [0x483, 0x1ab0, 0x1dc0, 0x20d0, 0xfe20, 0x200d, 0xfe0f, 0xe0001, 0xe0100]
  one = [0x2600, 0x2699, 0x1f1e6, 0x1f6ff, 0x1faff, 0x10ffff, 0x41]
  try Test.eq(wide.map { |code| Width.char(String.from_code(code)) }.uniq, [2])
  try Test.eq(zero.map { |code| Width.char(String.from_code(code)) }.uniq, [0])
  Test.eq(one.map { |code| Width.char(String.from_code(code)) }.uniq, [1])
end

def test_streamed_text_joins_the_last_entry_of_its_kind() -> Result[Void]
  entries = Transcript.add([], Transcript.Kind.User, "hi")
  entries = Transcript.add(entries, Transcript.Kind.Assistant, "Hel")
  entries = Transcript.add(entries, Transcript.Kind.Assistant, "lo")
  entries = Transcript.note(entries, "stopped")
  entries = Transcript.add(entries, Transcript.Kind.Assistant, "again")
  texts = entries.map { |entry| entry.text }
  try Test.eq(texts, ["hi", "Hello", "stopped", "again"])
  rows = Transcript.lines(entries, 20, Transcript.Folds()).map { |line| Markdown.plain(line.spans) }
  Test.eq(rows, ["  hi", "", " Hello", "", " stopped", "", " again"])
end

def test_the_prompt_shows_its_last_rows_with_a_lead() -> Result[Void]
  text = Prompt.insert(Prompt.insert("one", 3, "\n"), 4, "two")
  try Test.eq(Prompt.rows(text, 20), [" one", " two"])
  try Test.eq(Prompt.rows("", 20), [" "])
  try Test.eq(Prompt.rows("1\n2\n3\n4\n5\n6\n7", 20).size, Prompt.MAX_ROWS)
  try Test.eq(Prompt.view("1\n2\n3", 5, 20, 5).rows, [" 2", " 3"])
  try Test.eq(Prompt.view("a" * 25, 25, 12, 24).rows, [" aaaaaaaaaa", " aaaaaaaaaa", " aaaaa"])
  numbers = (1..20).map { |n| n.to_s }.join("\n")
  middle = Prompt.view(numbers, 4, 20, 24)
  try Test.eq([middle.rows, [middle.cursor_y.to_s]], [[" 3", " 4", " 5", " 6", " 7", " 8"], ["0"]])
  last = Prompt.view(numbers, numbers.length - 1, 20, 24)
  Test.eq([last.rows, [last.cursor_y.to_s]], [[" 15", " 16", " 17", " 18", " 19", " 20"], ["5"]])
end

def test_a_paste_keeps_line_ends_and_tabs_but_no_other_control() -> Result[Void]
  controls = [0x1b, 0x7f, 0x9b, 0x1].map { |code| String.from_code(code) }
  Test.eq(Prompt.pasted("a\tb\n#{controls.join("c")}d"), "a\tb\ncccd")
end

# The cursor edits in the middle; a click maps a column of a row back to the place in the text, wide characters too.
def test_the_prompt_cursor_and_clicks() -> Result[Void]
  # A row keeps its last column for the cursor, so a wide character at the end of a full row is not under it.
  try Test.eq([Prompt.view("日本語", 3, 8, 24).rows, [Prompt.view("日本語", 3, 8, 24).cursor_x.to_s]], [[" 日本語"], ["7"]])
  try Test.eq(Prompt.insert("held", 2, "XY"), "heXYld")
  text = "abcdefgh\n日本語"
  view = Prompt.view(text, 3, 7, 24)
  try Test.eq(view.rows, [" abcde", " fgh", " 日本", " 語"])
  try Test.eq([view.cursor_x, view.cursor_y], [4, 0])
  end_view = Prompt.view(text, text.length, 7, 24)
  try Test.eq([end_view.cursor_x, end_view.cursor_y], [3, 3])
  try Test.eq(Prompt.index_at(text, 0, 7, 24, 3, 1), 7)
  try Test.eq(Prompt.index_at(text, 0, 7, 24, 4, 2), 10)
  try Test.eq(Prompt.index_at(text, 0, 7, 24, 50, 1), 8)
  Test.eq(Prompt.index_at(text, 0, 7, 24, 0, 0), 0)
end

# The end of the rows comes from the wrapped rows the entries keep, and a change of an entry drops its own.
def test_the_tail_matches_the_lines_and_a_change_cuts_again() -> Result[Void]
  entries = Transcript.add(Transcript.note([], "one two three four"), Transcript.Kind.Thinking, "hmm")
  entries = Transcript.add(entries, Transcript.Kind.Assistant, "the answer")
  kept = Transcript.wrapped(entries, 8, Transcript.Folds())
  all = Transcript.lines(entries, 8, Transcript.Folds())
  for count in [0, 2, 5, all.size, all.size + 3]
    try Test.eq(Transcript.tail(kept, 8, Transcript.Folds(), count), all.drop([all.size - count, 0].max.unwrap!))
  end

  grown = Transcript.add(kept, Transcript.Kind.Assistant, " grows")
  try Test.eq(grown.last.wrapped, none)
  try Test.eq(
    Transcript.tail(grown, 8, Transcript.Folds(), 3),
    Transcript.lines(grown, 8, Transcript.Folds()).drop(all.size - 2),
  )

  Test.eq(
    Transcript.tail(kept, 8, Transcript.Folds(thinking: true), 9),
    Transcript.lines(entries, 8, Transcript.Folds(thinking: true)),
  )
end

# An entry with no rows (an answer that only called tools) takes no empty row, at the start or between.
def test_an_entry_without_rows_adds_no_empty_row() -> Result[Void]
  empty = Transcript.Entry(kind: Transcript.Kind.Assistant, text: "")
  entries = [empty] + Transcript.note([], "one") + [empty] + Transcript.note([], "two")
  all = Transcript.lines(entries, 20, Transcript.Folds())
  try Test.eq(all.map { |line| Markdown.plain(line.spans) }, [" one", "", " two"])
  for count in 0..4
    try Test.eq(Transcript.tail(entries, 20, Transcript.Folds(), count), all.drop([all.size - count, 0].max.unwrap!))
  end

  ok()
end

def test_thinking_is_folded_unless_shown_or_clicked_open() -> Result[Void]
  entries = Transcript.add([], Transcript.Kind.Thinking, "hmm")
  entries = Transcript.add(entries, Transcript.Kind.Assistant, "yes")
  try Test.eq(texts(entries, false), ["▸ thinking (click or ^T shows it)", "", "yes"])
  try Test.eq(texts(entries, true), ["hmm", "", "yes"])
  try Test.eq(Transcript.lines(entries, 20, Transcript.Folds()).map { |line| line.entry }, [0, -1, 1])
  opened = Transcript.toggle(entries, 0, Transcript.Folds())
  try Test.eq(texts(opened, false), ["hmm", "", "yes"])
  try Test.eq(texts(Transcript.toggle(opened, 0, Transcript.Folds()), false)[0], "▸ thinking (click or ^T shows it)")
  try Test.eq(Transcript.toggle(entries, 1, Transcript.Folds()), entries)
  Test.eq(texts(Transcript.unfold_thinking(opened), false)[0], "▸ thinking (click or ^T shows it)")
end

# A tool call is a shell line; once it ran its output is folded to a few rows (a click opens it) and says how long
# it took; a diff shows its numbered lines.
def test_a_tool_call_is_a_shell_line_with_its_folded_output() -> Result[Void]
  started = Protocol.ToolStarted(call_id: "c1", name: "bash", summary: "make test")
  running = Transcript.tool_started([], started)
  try Test.eq(texts(running, false), ["$ make test"])
  try Test.eq(Transcript.toggle(running, 0, Transcript.Folds()), running)
  try Test.eq(
    Transcript.lines(running, 40, Transcript.Folds())[0].spans.map { |span| span.look },
    [Markdown.Look.Plain, Markdown.Look.Title, Markdown.Look.Plain, Markdown.Look.Arg],
  )

  output = "1\n2\n3\n4\n5\n6"
  done = Protocol.ToolFinished(call_id: "c1", ok: true, summary: "1", duration_ms: 1234, output: some(output))
  ran = Transcript.tool_finished(running, done)
  try Test.eq(
    texts(ran, false),
    ["$ make test", "1", "2", "3", "4", "… 2 more lines (click or ^O shows them)", "Took 1.2s"],
  )

  try Test.eq(texts(Transcript.toggle(ran, 0, Transcript.Folds()), false).size, 8)
  edit = Transcript.tool_started([], Protocol.ToolStarted(call_id: "c2", name: "edit_file", summary: "a.txt"))
  failed = Protocol.ToolFinished(
    call_id: "c2",
    ok: false,
    summary: "old_string not found",
    duration_ms: 5,
    diff: some("- 1 a"),
  )

  Test.eq(
    texts(Transcript.tool_finished(edit, failed), false),
    ["edit a.txt", "- 1 a", "old_string not found", "Took 0.0s"],
  )
end

# Two children may use the same call id: their calls stay apart, labelled by child, and each end finds its own
# start. A child's call with no open `agent` call of its own keeps its own labelled group at the end.
def test_overlapping_call_ids_of_two_children_stay_apart() -> Result[Void]
  s2 = Protocol.ToolStarted(call_id: "c1", name: "bash", summary: "ls", session: some("s2"))
  s3 = Protocol.ToolStarted(call_id: "c1", name: "read_file", summary: "notes.txt", session: some("s3"))
  entries = Transcript.tool_started(Transcript.tool_started([], s2), s3)
  try Test.eq(entries.map { |e| e.call_id }, ["c1", "c1"])
  entries = Transcript.tool_finished(
    entries,
    Protocol.ToolFinished(call_id: "c1", ok: true, summary: "ok", duration_ms: 4, session: some("s2")),
  )

  entries = Transcript.tool_finished(
    entries,
    Protocol.ToolFinished(call_id: "c1", ok: false, summary: "denied", duration_ms: 0, session: some("s3")),
  )

  try Test.eq(entries.map { |e| e.call_id }, ["c1", "c1"])
  Test.eq(
    texts(entries, false),
    ["child s2 · $ ls", "ok", "Took 0.0s", "", "child s3 · read notes.txt", "denied", "Took 0.0s"],
  )
end

# A child's call goes under the open `agent` call that started it; with two open, or with its call already over, the
# child keeps its own labelled group at the end instead of joining a call that may not be its.
def test_a_child_call_nests_under_the_open_agent_call() -> Result[Void]
  agent = Protocol.ToolStarted(call_id: "c0", name: "agent", summary: "2 tasks")
  child = Protocol.ToolStarted(call_id: "c1", name: "bash", summary: "ls", session: some("s2"))
  nested = Transcript.tool_started(Transcript.tool_started([], agent), child)
  try Test.eq(nested.map { |e| e.call_id }, ["c0", "c1"])
  done = Protocol.ToolFinished(call_id: "c0", ok: true, summary: "s2: done", duration_ms: 9)
  finished = Transcript.tool_finished(Transcript.tool_finished(nested, child_done()), done)
  try Test.eq(texts(finished, false)[0], "agent 2 tasks")
  try Test.eq(texts(finished, false)[4], "child s2 · $ ls")
  two = Transcript.tool_started(Transcript.tool_started([], agent), agent.with(call_id: "c9"))
  try Test.eq(Transcript.tool_started(two, child).map { |e| e.call_id }, ["c0", "c9", "c1"])
  over = Transcript.tool_finished(Transcript.tool_started([], agent), done)
  Test.eq(Transcript.tool_started(over, child).map { |e| e.call_id }, ["c0", "c1"])
end

# Two children under one open `agent` call keep their arrival order, with overlapping call ids and a parent entry
# between them; each end still finds its own start. A replay from the history shows the same order where no parent
# entry comes between the children's calls.
def test_two_children_under_one_agent_keep_their_arrival_order() -> Result[Void]
  agent = Protocol.ToolStarted(call_id: "c0", name: "agent", summary: "2 tasks")
  first = Protocol.ToolStarted(call_id: "c1", name: "bash", summary: "ls", session: some("s2"))
  second = Protocol.ToolStarted(call_id: "c1", name: "read_file", summary: "notes.txt", session: some("s3"))
  plain = Transcript.tool_started(Transcript.tool_started(Transcript.tool_started([], agent), first), second)
  try Test.eq(plain.map { |e| e.session }, [none, some("s2"), some("s3")])
  try Test.eq(plain.map { |e| e.call_id }, ["c0", "c1", "c1"])
  parent = Protocol.ToolStarted(call_id: "c9", name: "bash", summary: "uptime")
  mixed = Transcript.tool_started(Transcript.tool_started(Transcript.tool_started([], agent), first), parent)
  mixed = Transcript.tool_started(mixed, second)
  try Test.eq(mixed.map { |e| e.session }, [none, some("s2"), some("s3"), none])
  try Test.eq(mixed.map { |e| e.call_id }, ["c0", "c1", "c1", "c9"])
  finished = Transcript.tool_finished(
    Transcript.tool_finished(mixed, child_done()),
    Protocol.ToolFinished(call_id: "c1", ok: false, summary: "denied", duration_ms: 0, session: some("s3")),
  )

  try Test.eq(
    texts(finished, false).select { |row| row.start_with?("child") },
    ["child s2 · $ ls", "child s3 · read notes.txt"],
  )

  history = [
    Protocol.Message(role: Protocol.Role.User, text: "go"),
    Protocol.Message(
      role: Protocol.Role.Assistant,
      text: "",
      tool: some(agent),
      done: some(Protocol.ToolFinished(call_id: "c0", ok: true, summary: "done", duration_ms: 9)),
    ),
    Protocol.Message(role: Protocol.Role.Assistant, text: "", tool: some(first), done: some(child_done())),
    Protocol.Message(
      role: Protocol.Role.Assistant,
      text: "",
      tool: some(second),
      done: some(
        Protocol.ToolFinished(call_id: "c1", ok: false, summary: "denied", duration_ms: 0, session: some("s3")),
      ),
    ),
  ]

  replayed = Transcript.from_history(history)
  try Test.eq(replayed.map { |e| e.session }, [none, none, some("s2"), some("s3")])
  Test.eq(
    texts(replayed, false).select { |row| row.start_with?("child") },
    ["child s2 · $ ls", "child s3 · read notes.txt"],
  )
end

def child_done() -> Protocol.ToolFinished
  Protocol.ToolFinished(call_id: "c1", ok: true, summary: "ok", duration_ms: 4, session: some("s2"))
end

# A replayed history keeps the children's calls after their `agent` call, labelled by child, since the file holds
# the session of every call.
def test_a_replayed_history_groups_child_calls() -> Result[Void]
  history = [
    Protocol.Message(role: Protocol.Role.User, text: "go"),
    Protocol.Message(
      role: Protocol.Role.Assistant,
      text: "",
      tool: some(Protocol.ToolStarted(call_id: "c0", name: "agent", summary: "2 tasks")),
      done: some(Protocol.ToolFinished(call_id: "c0", ok: true, summary: "s2: done", duration_ms: 9)),
    ),
    Protocol.Message(
      role: Protocol.Role.Assistant,
      text: "",
      tool: some(Protocol.ToolStarted(call_id: "c1", name: "bash", summary: "ls", session: some("s2"))),
      done: some(child_done()),
    ),
  ]

  entries = Transcript.from_history(history)
  try Test.eq(entries.map { |e| e.call_id }, ["", "c0", "c1"])
  Test.eq(
    texts(entries, false),
    ["go", "", "agent 2 tasks", "s2: done", "Took 0.0s", "", "child s2 · $ ls", "ok", "Took 0.0s"],
  )
end

def test_markdown_headings_lists_code_and_bold() -> Result[Void]
  text = "## Plan\n- one **two** three\n12. last\n```\n  let x = 1\n```\nsee **this**, ok"
  rows = Markdown.rows(text, 40)
  try Test.eq(
    rows.map { |row| Markdown.plain(row) },
    ["Plan", "• one two three", "12. last", "  let x = 1", "see this, ok"],
  )

  try Test.eq(rows[0], [Markdown.Span(text: "Plan", look: Markdown.Look.Heading)])
  try Test.eq(rows[1].map { |span| span.look }, [Markdown.Look.Plain, Markdown.Look.Bold, Markdown.Look.Plain])
  try Test.eq(rows[3][0].look, Markdown.Look.Code)
  Test.eq(rows[4].map { |span| span.text }, ["see ", "this", ", ok"])
end

def test_a_list_item_wraps_under_its_text() -> Result[Void]
  rows = Markdown.rows("- alpha beta gamma", 12)
  Test.eq(rows.map { |row| Markdown.plain(row) }, ["• alpha beta", "  gamma"])
end

def test_a_long_code_line_wraps_and_keeps_its_spaces() -> Result[Void]
  rows = Markdown.rows("```\nlet  x = 1234567890\n日本語x\n\n```", 6)
  texts = rows.map { |row| Markdown.plain(row) }
  try Test.eq(texts, ["let  x", " = 123", "456789", "0", "日本語", "x", ""])
  Test.eq(Markdown.rows("```\n日本\n```", 1).map { |row| Markdown.plain(row) }, ["日", "本"])
end

def texts(entries: List[Transcript.Entry], thinking: Bool) -> List[String]
  Transcript.lines(entries, 40, Transcript.Folds(thinking: thinking)).map { |line| Markdown.plain(line.spans).strip }
end
