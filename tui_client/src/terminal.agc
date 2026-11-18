## What the full screen writes to the terminal outside the grid it draws: the copy to the clipboard and the mouse
## reporting. Pure, but for `write`.

ESC = String.from_code(27)
BEL = String.from_code(7)

## The sequence that sets the clipboard of the terminal to `text` (OSC 52), which works in local terminals, over SSH
## and in tmux with `set-clipboard on`.
def osc52(text: String) -> String = "#{ESC}]52;c;#{Base64.strict_encode64(text.bytes)}#{BEL}"

## The sequences that turn the mouse reporting of the terminal off and on, as termbox2 sets it (button events, SGR).
def mouse(on: Bool) -> String
  mode = "l"
  if on
    mode = "h"
  end

  "#{ESC}[?1000#{mode}#{ESC}[?1002#{mode}#{ESC}[?1006#{mode}"
end

## Writes to the terminal.
def write(text: String) -> Void
  print(text)
  IO.flush()
end
