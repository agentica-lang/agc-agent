## What the main loop waits for: the lines of the terminal, the signals and the events of the stream, all on one
## channel (Agentica has no `select`).

import Protocol from "pkg/protocol/protocol"

enum Input
  Line(String)
  Eof
  Interrupt
  Terminate
  ## The first value is the generation of the stream that sent it, so the main loop drops what an old stream sent.
  Stream(Int, Item)
end

enum Item
  ## The server accepted the subscription.
  Opened
  ## The event and its id (none when the stream gave none).
  Event(Optional[Int], Protocol.Event)
  ## The stream ended, or could not start: the reason.
  Ended(String)
end
