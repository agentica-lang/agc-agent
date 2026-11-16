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
  Test.eq(Width.cut("日本語", 5), ["日本", "語"])
end

def test_streamed_text_joins_the_last_entry_of_its_kind() -> Result[Void]
  entries = Transcript.add([], Transcript.Kind.User, "hi")
  entries = Transcript.add(entries, Transcript.Kind.Assistant, "Hel")
  entries = Transcript.add(entries, Transcript.Kind.Assistant, "lo")
  entries = Transcript.note(entries, "stopped")
  entries = Transcript.add(entries, Transcript.Kind.Assistant, "again")
  texts = entries.map { |entry| entry.text }
  try Test.eq(texts, ["hi", "Hello", "stopped", "again"])
  rows = Transcript.lines(entries, 20).map { |line| line.text }
  Test.eq(rows, ["> hi", "", "Hello", "", "· stopped", "", "again"])
end

def test_the_prompt_shows_its_last_rows_with_a_lead() -> Result[Void]
  text = Prompt.backspace(Prompt.insert(Prompt.insert("one", "\n"), "twoo"))
  try Test.eq(Prompt.rows(text, 20), ["> one", "  two"])
  try Test.eq(Prompt.rows("", 20), ["> "])
  Test.eq(Prompt.rows("1\n2\n3\n4\n5\n6\n7", 20).size, Prompt.MAX_ROWS)
end
