## What the main loop waits for, all on one channel: the keys of the terminal and the events of the stream.

import Client from "pkg/client/client"
import TUI from "pkg/tui/tui"

enum Input
  Terminal(TUI.Event)
  Signal(System.Signal)
  ## A note for the transcript from a task of the loop (a compaction's end).
  Note(String)
  ## The terminal can no longer be read: the reason.
  Closed(String)
  ## The first value is the generation of the stream that sent it, so the loop drops what an old stream sent.
  Stream(Int, Client.Item)
end
