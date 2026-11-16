## What the main loop waits for, all on one channel: the keys of the terminal and the events of the stream.

import TUI from "pkg/tui/tui"
import Protocol from "pkg/protocol/protocol"

enum Input
  Terminal(TUI.Event)
  ## The terminal can no longer be read: the reason.
  Closed(String)
  ## The first value is the generation of the stream that sent it, so the loop drops what an old stream sent.
  Stream(Int, Item)
end

enum Item
  Opened
  ## The event and its id (none when the stream gave none).
  Event(Optional[Int], Protocol.Event)
  ## The stream ended, or could not start: the reason.
  Ended(String)
end
