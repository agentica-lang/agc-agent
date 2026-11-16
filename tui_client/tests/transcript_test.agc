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
  text = Prompt.backspace(Prompt.insert(Prompt.insert("one", "\n"), "twoo"))
  try Test.eq(Prompt.rows(text, 20), ["> one", "  two"])
  try Test.eq(Prompt.rows("", 20), ["> "])
  Test.eq(Prompt.rows("1\n2\n3\n4\n5\n6\n7", 20).size, Prompt.MAX_ROWS)
end

def test_thinking_is_drawn_only_when_shown() -> Result[Void]
  entries = Transcript.add([], Transcript.Kind.Thinking, "hmm")
  entries = Transcript.add(entries, Transcript.Kind.Assistant, "yes")
  try Test.eq(Transcript.lines(entries, 20, false).map { |line| Markdown.plain(line.spans) }, ["yes"])
  Test.eq(Transcript.lines(entries, 20, true).map { |line| Markdown.plain(line.spans) }, ["hmm", "", "yes"])
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
