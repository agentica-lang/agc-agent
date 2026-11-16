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
  # As termbox2 draws a ZWJ sequence: each emoji takes its own columns.
  family = ["👨", "👩", "👧"].join(String.from_code(0x200d))
  try Test.eq(Width.text(family), 6)
  try Test.eq(Width.cut("a#{family}b", 5), ["a👨" + String.from_code(0x200d) + "👩" + String.from_code(0x200d), "👧b"])
  Test.eq(Width.text("x⚙" + String.from_code(0xfe0f)), 2)
end

# The values of glibc's wcwidth(3), which termbox2 draws with; not printable is U+FFFD, one column.
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
  rows = Transcript.lines(entries, 20, false).map { |line| Markdown.plain(line.spans) }
  Test.eq(rows, ["> hi", "", "Hello", "", "· stopped", "", "again"])
end

def test_the_prompt_shows_its_last_rows_with_a_lead() -> Result[Void]
  text = Prompt.backspace(Prompt.insert(Prompt.insert("one", 3, "\n"), 4, "twoo"), 8)
  try Test.eq(Prompt.rows(text, 20), ["> one", "  two"])
  try Test.eq(Prompt.rows("", 20), ["> "])
  try Test.eq(Prompt.rows("1\n2\n3\n4\n5\n6\n7", 20).size, Prompt.MAX_ROWS)
  try Test.eq(Prompt.view("1\n2\n3", 5, 20, 3).rows, ["  2", "  3"])
  try Test.eq(Prompt.view("a" * 25, 25, 12, 24).rows, ["> aaaaaaaaaa", "  aaaaaaaaaa", "  aaaaa"])
  numbers = (1..20).map { |n| n.to_s }.join("\n")
  middle = Prompt.view(numbers, 4, 20, 24)
  try Test.eq([middle.rows, [middle.cursor_y.to_s]], [["  3", "  4", "  5", "  6", "  7", "  8"], ["0"]])
  last = Prompt.view(numbers, numbers.length - 1, 20, 24)
  Test.eq([last.rows, [last.cursor_y.to_s]], [["  15", "  16", "  17", "  18", "  19", "  20"], ["5"]])
end

def test_a_paste_keeps_line_ends_and_tabs_but_no_other_control() -> Result[Void]
  controls = [0x1b, 0x7f, 0x9b, 0x1].map { |code| String.from_code(code) }
  Test.eq(Prompt.pasted("a\tb\n#{controls.join("c")}d"), "a\tb\ncccd")
end

# The cursor edits in the middle; a click maps a column of a row back to the place in the text, wide characters too.
def test_the_prompt_cursor_and_clicks() -> Result[Void]
  try Test.eq(Prompt.insert("held", 2, "XY"), "heXYld")
  try Test.eq(Prompt.backspace("held", 2), "hld")
  try Test.eq(Prompt.backspace("held", 0), "held")
  text = "abcdefgh\n日本語"
  view = Prompt.view(text, 3, 7, 24)
  try Test.eq(view.rows, ["> abcde", "  fgh", "  日本", "  語"])
  try Test.eq([view.cursor_x, view.cursor_y], [5, 0])
  end_view = Prompt.view(text, text.length, 7, 24)
  try Test.eq([end_view.cursor_x, end_view.cursor_y], [4, 3])
  try Test.eq(Prompt.index_at(text, 0, 7, 24, 4, 1), 7)
  try Test.eq(Prompt.index_at(text, 0, 7, 24, 5, 2), 10)
  try Test.eq(Prompt.index_at(text, 0, 7, 24, 50, 1), 8)
  Test.eq(Prompt.index_at(text, 0, 7, 24, 0, 0), 0)
end

# The end of the rows comes from the wrapped rows the entries keep, and a change of an entry drops its own.
def test_the_tail_matches_the_lines_and_a_change_cuts_again() -> Result[Void]
  entries = Transcript.add(Transcript.note([], "one two three four"), Transcript.Kind.Thinking, "hmm")
  entries = Transcript.add(entries, Transcript.Kind.Assistant, "the answer")
  kept = Transcript.wrapped(entries, 8, false)
  all = Transcript.lines(entries, 8, false)
  for count in [0, 2, 5, all.size, all.size + 3]
    try Test.eq(Transcript.tail(kept, 8, false, count), all.drop([all.size - count, 0].max.unwrap!))
  end

  grown = Transcript.add(kept, Transcript.Kind.Assistant, " grows")
  try Test.eq(grown.last.wrapped, none)
  try Test.eq(Transcript.tail(grown, 8, false, 3), Transcript.lines(grown, 8, false).drop(all.size - 2))
  Test.eq(Transcript.tail(kept, 8, true, 9), Transcript.lines(entries, 8, true))
end

def test_thinking_is_folded_unless_shown_or_clicked_open() -> Result[Void]
  entries = Transcript.add([], Transcript.Kind.Thinking, "hmm")
  entries = Transcript.add(entries, Transcript.Kind.Assistant, "yes")
  try Test.eq(texts(entries, false), [Transcript.FOLDED_THINKING, "", "yes"])
  try Test.eq(texts(entries, true), ["hmm", "", "yes"])
  try Test.eq(Transcript.lines(entries, 20, false).map { |line| line.entry }, [0, -1, 1])
  opened = Transcript.toggle(entries, 0, false)
  try Test.eq(texts(opened, false), ["hmm", "", "yes"])
  try Test.eq(texts(Transcript.toggle(opened, 0, false), false)[0], Transcript.FOLDED_THINKING)
  try Test.eq(Transcript.toggle(entries, 1, false), entries)
  Test.eq(texts(Transcript.unfold_thinking(opened), false)[0], Transcript.FOLDED_THINKING)
end

def test_a_finished_tool_opens_to_show_its_call() -> Result[Void]
  entries = Transcript.tool([], "c1", Transcript.Kind.Tool, "⚙ bash make test")
  entries = Transcript.tool(entries, "c1", Transcript.Kind.Tool, "✓ ran (8 ms)")
  try Test.eq(texts(entries, false), ["✓ ran (8 ms)"])
  opened = Transcript.toggle(entries, 0, false)
  try Test.eq(texts(opened, false), ["⚙ bash make test", "✓ ran (8 ms)"])
  try Test.eq(texts(Transcript.toggle(opened, 0, false), false), ["✓ ran (8 ms)"])
  running = Transcript.tool([], "c2", Transcript.Kind.Tool, "⚙ bash make")
  Test.eq(Transcript.toggle(running, 0, false), running)
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
  Transcript.lines(entries, 40, thinking).map { |line| Markdown.plain(line.spans) }
end
