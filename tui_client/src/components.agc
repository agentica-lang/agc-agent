## Reusable screen parts: a modal box, a side column with its edge, a one-line banner, a prompt row with its cursor,
## a floating tip and panel boxes, and a list with its selected row. Pure.

import TUI from "pkg/tui/tui"
import Theme from "theme"
import Width from "width"

## A bordered box with `title` over `rows`: the title maps to `theme.panel.head`, the frame to `theme.panel.text`.
def modal(title: String, rows: List[TUI.Node], width: Int, theme: Theme.Theme) -> TUI.Node
  inner = [width - 2, 0].max.unwrap!
  head = Width.cut(title, inner)[0]
  padded = head + " " * (inner - Width.text(head))
  title_row = TUI.line([TUI.span(padded, theme.panel.head)])
  TUI.box(TUI.col([title_row] + rows), border: TUI.Border.Line, style: theme.panel.text)
end

## The right-side column beside the content: the `│` edge maps to `theme.panel.text`, as `Screen.beside` draws it.
def sidebar(rows: List[TUI.Node], theme: Theme.Theme) -> TUI.Node
  edge = rows.map { |_| TUI.line([TUI.span("│", theme.panel.text)]) }
  TUI.row([TUI.col(edge), TUI.col(rows)])
end

## A one-line banner: the text maps to `theme.banner.text`.
def notice(text: String, theme: Theme.Theme) -> TUI.Node
  TUI.line([TUI.span(text.replace("\n", " "), theme.banner.text)])
end

## A prompt row: the text maps to `theme.editor.text`, the cell under the cursor to `theme.editor.cursor`.
def input_row(text: String, cursor_at: Int, width: Int, theme: Theme.Theme) -> TUI.Node
  cap = [width - 1, 0].max.unwrap!
  parts = Width.cut(text, [[cursor_at, 0].max.unwrap!, cap].min.unwrap!)
  return TUI.line([TUI.span(parts[0], theme.editor.text), TUI.span(" ", theme.editor.cursor)]) if parts[1] == ""

  under = parts[1].slice(0, 1)
  rest = parts[1].slice(1, parts[1].length - 1)
  TUI.line([
    TUI.span(parts[0], theme.editor.text),
    TUI.span(under, theme.editor.cursor),
    TUI.span(rest, theme.editor.text),
  ])
end

## A small floating box of one row: the frame and the row map to `theme.panel.text`, as `modal` draws them.
def tooltip(text: String, theme: Theme.Theme) -> TUI.Node
  row = TUI.line([TUI.span(text.replace("\n", " "), theme.panel.text)])
  TUI.box(row, border: TUI.Border.Line, style: theme.panel.text)
end

## A bordered box without a title: the frame maps to `theme.panel.text`, as `modal` draws it.
def popover(rows: List[TUI.Node], width: Int, theme: Theme.Theme) -> TUI.Node
  body = rows
  if body.empty?
    inner = [width - 2, 0].max.unwrap!
    body = [TUI.line([TUI.span(" " * inner, theme.panel.text)])]
  end

  TUI.box(TUI.col(body), border: TUI.Border.Line, style: theme.panel.text)
end

## Rows with the cursor row in `theme.panel.selected` and the rest in `theme.panel.text`.
def select_list(rows: List[String], cursor: Int, width: Int, theme: Theme.Theme) -> TUI.Node
  return TUI.col([]) if rows.empty?

  at = [[cursor, 0].max.unwrap!, rows.size - 1].min.unwrap!
  cap = [width, 0].max.unwrap!
  nodes: List[TUI.Node] = []
  for i in 0...rows.size
    cut = Width.cut(rows[i].replace("\n", " "), cap)[0]
    padded = cut + " " * (cap - Width.text(cut))
    shown = theme.panel.text
    if i == at
      shown = theme.panel.selected
    end

    nodes = nodes.push(TUI.line([TUI.span(padded, shown)]))
  end

  TUI.col(nodes)
end
