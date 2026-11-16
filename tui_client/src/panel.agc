## The layout of a panel over the prompt (an approval, the session picker): a head, a body and the key rows, fitted
## in the rows left on the screen. The keys stay when rows are cut, then the head; the body gets what is left. Pure.

import TUI from "pkg/tui/tui"
import Transcript from "transcript"

struct Row
  text: String
  style: TUI.Style
end

## `head` and `keys` are wrapped to `width`; `body` gets the number of rows left for it.
def fit(head: String, keys: String, body: Fn[Int, List[Row]], width: Int, room: Int) -> List[Row]
  return [] if room <= 0

  key_rows = strong_rows(keys, width)
  key_rows = key_rows.drop([key_rows.size - room, 0].max.unwrap!)
  left = room - key_rows.size
  head_rows = strong_rows(head, width).take(left)
  body_rows = body.call(left - head_rows.size)
  head_rows + body_rows + key_rows
end

private

def strong_rows(text: String, width: Int) -> List[Row]
  strong = TUI.Style(fg: TUI.Color.Yellow, attrs: [TUI.Attr.Bold])
  Transcript.wrap(text, width).map { |line| Row(text: line, style: strong) }
end
