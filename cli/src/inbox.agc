## What the main loop waits for: the lines of the terminal, the signals and the events of the stream, all on one
## channel (Agentica has no `select`).

import Client from "pkg/client/client"

enum Input
  Line(String)
  Eof
  Interrupt
  Terminate
  ## A line to print from a task of the loop (a compaction's end).
  Note(String)
  ## The first value is the generation of the stream that sent it, so the main loop drops what an old stream sent.
  Stream(Int, Client.Item)
end
