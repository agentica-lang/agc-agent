import Markdown from "../src/markdown"
import Width from "../src/width"

TABLE = "| Name | Value |\n| --- | --- |\n| 界 | **yes** |"

def test_pipe_table_aligns_display_columns_and_styles_cells() -> Result[Void]
  rows = Markdown.rows(TABLE, 40)
  try Test.eq(rows.map { |row| Markdown.plain(row) }, [" Name │ Value ", "──────┼───────", " 界   │ yes   "])
  try Test.eq(rows[0][1].look, Markdown.Look.Heading)
  Test.eq(rows[2][5].look, Markdown.Look.Bold)
end

def test_pipe_table_wraps_cells_as_the_stream_grows() -> Result[Void]
  before = Markdown.rows(TABLE, 20).map { |row| Markdown.plain(row) }.join("\n")
  try Test.assert(before.include?("┼"), "the initial table fits")
  final = Markdown.rows("#{TABLE}\n| Longer name | A much longer value |", 20).map { |row| Markdown.plain(row) }
  try Test.assert(final.join("\n").include?("┼"), "a longer row keeps the table layout")
  Test.assert(final.all? { |row| Width.text(row) <= 20 }, "every rendered row fits")
end

def test_pipe_table_falls_back_when_too_narrow_and_stays_literal_in_code() -> Result[Void]
  narrow = Markdown.rows(TABLE, 8).map { |row| Markdown.plain(row) }.join("\n")
  try Test.assert(not narrow.include?("┼"), "an extremely narrow table uses normal wrapping")
  code = Markdown.rows("```\n#{TABLE}\n```", 40)
  Test.eq(code.map { |row| Markdown.plain(row) }.join("\n"), TABLE)
end
