## The text the user types, edited at its end. Pure.

import Transcript from "transcript"

MAX_ROWS = 6
LEAD = "> "

def insert(text: String, piece: String) -> String = text + piece

def backspace(text: String) -> String
  return text if text == ""

  text.slice(0, text.length - 1)
end

## The rows the prompt draws in `width` (the last `MAX_ROWS` of them), each led by `LEAD` or its indent.
def rows(text: String, width: Int) -> List[String]
  wrapped = Transcript.wrap(text, width - LEAD.length)
  led = [LEAD + wrapped[0]] + wrapped.drop(1).map { |row| " " * LEAD.length + row }
  led.drop([led.size - MAX_ROWS, 0].max.unwrap!)
end
