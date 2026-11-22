import TUI from "pkg/tui/tui"
import Components from "../src/components"
import Theme from "../src/theme"

def test_modal_shows_the_title_in_the_head_style_inside_a_border() -> Result[Void]
  theme = Theme.default()
  body = TUI.line([TUI.span("body", theme.panel.text)])
  cells = TUI.layout(Components.modal("Hi", [body], 10, theme), 10, 4)
  try Test.eq(row_text(cells, 0, 10), "┌" + "─" * 8 + "┐")
  try Test.eq((try at(cells, 1, 1).to_result("no cell at 1,1")).style, TUI.merge(theme.panel.text, theme.panel.head))
  try Test.eq(row_text(cells, 1, 10), "│Hi" + " " * 6 + "│")
  try Test.eq(row_text(cells, 3, 10), "└" + "─" * 8 + "┘")
  Test.eq(row_text(cells, 2, 10), "│body" + " " * 4 + "│")
end

def test_modal_caps_the_title_at_the_width() -> Result[Void]
  theme = Theme.default()
  cells = TUI.layout(Components.modal("alongtitlehere", [], 6, theme), 6, 3)
  for cell in cells
    try Test.assert(cell.x < 6, "a cell past the width: #{cell.x}")
  end

  Test.eq(row_text(cells, 1, 6), "│alon│")
end

def test_modal_with_no_rows_still_draws_its_border() -> Result[Void]
  cells = TUI.layout(Components.modal("T", [], 6, Theme.default()), 6, 3)
  try Test.eq(row_text(cells, 0, 6), "┌" + "─" * 4 + "┐")
  try Test.eq(row_text(cells, 1, 6), "│T" + " " * 3 + "│")
  Test.eq(row_text(cells, 2, 6), "└" + "─" * 4 + "┘")
end

def test_sidebar_carries_the_edge_in_the_panel_style() -> Result[Void]
  theme = Theme.default()
  rows = [TUI.line([TUI.span("a", theme.panel.text)]), TUI.line([TUI.span("bb", theme.panel.text)])]
  cells = TUI.layout(Components.sidebar(rows, theme), 4, 2)
  try Test.eq((try at(cells, 0, 0).to_result("no cell at 0,0")).char, "│")
  try Test.eq((try at(cells, 0, 0).to_result("no cell at 0,0")).style, theme.panel.text)
  try Test.eq((try at(cells, 0, 1).to_result("no cell at 0,1")).char, "│")
  try Test.eq(row_text(cells, 0, 4), "│a  ")
  Test.eq(row_text(cells, 1, 4), "│bb ")
end

def test_sidebar_with_no_rows_draws_nothing() -> Result[Void]
  Test.eq(TUI.layout(Components.sidebar([], Theme.default()), 4, 2).size, 0)
end

def test_notice_draws_a_single_line_in_the_banner_style() -> Result[Void]
  theme = Theme.default()
  cells = TUI.layout(Components.notice("hello", theme), 8, 1)
  try Test.eq((try at(cells, 0, 0).to_result("no cell at 0,0")).style, theme.banner.text)
  Test.eq(row_text(cells, 0, 8), "hello   ")
end

def test_notice_draws_a_newline_as_a_space_and_empty_text_draws_nothing() -> Result[Void]
  theme = Theme.default()
  cells = TUI.layout(Components.notice("a\nb", theme), 4, 1)
  try Test.eq(row_text(cells, 0, 4), "a b ")
  Test.eq(TUI.layout(Components.notice("", theme), 4, 1).size, 0)
end

def test_input_row_draws_the_cursor_in_the_cursor_style() -> Result[Void]
  theme = Theme.default()
  cells = TUI.layout(Components.input_row("hi", 1, 6, theme), 6, 1)
  try Test.eq(row_text(cells, 0, 6), "hi    ")
  try Test.eq((try at(cells, 0, 0).to_result("no cell at 0,0")).style, theme.editor.text)
  try Test.eq((try at(cells, 1, 0).to_result("no cell at 1,0")).char, "i")
  Test.eq((try at(cells, 1, 0).to_result("no cell at 1,0")).style, theme.editor.cursor)
end

def test_input_row_clamps_the_cursor_at_both_ends() -> Result[Void]
  theme = Theme.default()
  low = TUI.layout(Components.input_row("hi", -3, 6, theme), 6, 1)
  try Test.eq((try at(low, 0, 0).to_result("no cursor at 0,0")).style, theme.editor.cursor)
  high = TUI.layout(Components.input_row("hi", 99, 6, theme), 6, 1)
  try Test.eq((try at(high, 2, 0).to_result("no cursor at 2,0")).char, " ")
  Test.eq((try at(high, 2, 0).to_result("no cursor at 2,0")).style, theme.editor.cursor)
end

def test_input_row_with_empty_text_still_draws_the_cursor() -> Result[Void]
  theme = Theme.default()
  cells = TUI.layout(Components.input_row("", 0, 4, theme), 4, 1)
  try Test.eq((try at(cells, 0, 0).to_result("no cursor at 0,0")).char, " ")
  Test.eq((try at(cells, 0, 0).to_result("no cursor at 0,0")).style, theme.editor.cursor)
end

def test_input_row_caps_at_the_width() -> Result[Void]
  theme = Theme.default()
  cells = TUI.layout(Components.input_row("alongtext", 0, 4, theme), 4, 1)
  for cell in cells
    try Test.assert(cell.x < 4, "a cell past the width: #{cell.x}")
  end

  Test.eq(row_text(cells, 0, 4), "alon")
end

def test_tooltip_draws_a_bordered_box_in_the_panel_style() -> Result[Void]
  theme = Theme.default()
  cells = TUI.layout(Components.tooltip("tip", theme), 5, 3)
  try Test.eq(row_text(cells, 0, 5), "┌" + "─" * 3 + "┐")
  try Test.eq(row_text(cells, 1, 5), "│tip│")
  try Test.eq((try at(cells, 1, 1).to_result("no cell at 1,1")).style, TUI.merge(theme.panel.text, theme.panel.text))
  Test.eq(row_text(cells, 2, 5), "└" + "─" * 3 + "┘")
end

def test_popover_draws_a_bordered_box_without_a_title() -> Result[Void]
  theme = Theme.default()
  rows = [TUI.line([TUI.span("one", theme.panel.text)]), TUI.line([TUI.span("two", theme.panel.text)])]
  cells = TUI.layout(Components.popover(rows, 5, theme), 5, 4)
  try Test.eq(row_text(cells, 0, 5), "┌" + "─" * 3 + "┐")
  try Test.eq(row_text(cells, 1, 5), "│one│")
  try Test.eq(row_text(cells, 2, 5), "│two│")
  Test.eq(row_text(cells, 3, 5), "└" + "─" * 3 + "┘")
end

def test_popover_caps_at_the_width() -> Result[Void]
  theme = Theme.default()
  rows = [TUI.line([TUI.span("alongrowhere", theme.panel.text)])]
  cells = TUI.layout(Components.popover(rows, 6, theme), 6, 3)
  for cell in cells
    try Test.assert(cell.x < 6, "a cell past the width: #{cell.x}")
  end

  Test.eq(row_text(cells, 1, 6), "│alon" + "│")
end

def test_popover_with_no_rows_still_draws_its_border() -> Result[Void]
  cells = TUI.layout(Components.popover([], 6, Theme.default()), 6, 3)
  try Test.eq(row_text(cells, 0, 6), "┌" + "─" * 4 + "┐")
  try Test.eq(row_text(cells, 1, 6), "│" + " " * 4 + "│")
  Test.eq(row_text(cells, 2, 6), "└" + "─" * 4 + "┘")
end

def test_select_list_marks_the_cursor_row_selected() -> Result[Void]
  theme = Theme.default()
  cells = TUI.layout(Components.select_list(["a", "bb"], 1, 4, theme), 4, 2)
  try Test.eq(row_text(cells, 0, 4), "a   ")
  try Test.eq(row_text(cells, 1, 4), "bb  ")
  try Test.eq((try at(cells, 0, 0).to_result("no cell at 0,0")).style, theme.panel.text)
  Test.eq((try at(cells, 0, 1).to_result("no cell at 0,1")).style, theme.panel.selected)
end

def test_select_list_clamps_the_cursor_at_both_ends() -> Result[Void]
  theme = Theme.default()
  low = TUI.layout(Components.select_list(["a", "b"], -5, 3, theme), 3, 2)
  try Test.eq((try at(low, 0, 0).to_result("no cell at 0,0")).style, theme.panel.selected)
  high = TUI.layout(Components.select_list(["a", "b"], 9, 3, theme), 3, 2)
  try Test.eq((try at(high, 0, 0).to_result("no cell at 0,0")).style, theme.panel.text)
  Test.eq((try at(high, 0, 1).to_result("no cell at 0,1")).style, theme.panel.selected)
end

def test_select_list_caps_rows_at_the_width() -> Result[Void]
  theme = Theme.default()
  cells = TUI.layout(Components.select_list(["alongrowhere"], 0, 6, theme), 6, 1)
  for cell in cells
    try Test.assert(cell.x < 6, "a cell past the width: #{cell.x}")
  end

  try Test.eq(row_text(cells, 0, 6), "alongr")
  Test.eq((try at(cells, 0, 0).to_result("no cell at 0,0")).style, theme.panel.selected)
end

def test_select_list_with_no_rows_draws_nothing() -> Result[Void]
  Test.eq(TUI.layout(Components.select_list([], 0, 4, Theme.default()), 4, 2).size, 0)
end

private

# The last cell drawn at column x, row y: later cells cover the earlier ones of a box fill.
def at(cells: List[TUI.Cell], x: Int, y: Int) -> Optional[TUI.Cell]
  found: Optional[TUI.Cell] = none
  for cell in cells
    if cell.x == x and cell.y == y
      found = some(cell)
    end
  end

  found
end

# The row as drawn: the last cell of each column, a space where none drew.
def row_text(cells: List[TUI.Cell], y: Int, width: Int) -> String
  out = ""
  for x in 0...width
    char = " "
    for cell in cells
      if cell.x == x and cell.y == y
        char = cell.char
      end
    end

    out = out + char
  end

  out
end
