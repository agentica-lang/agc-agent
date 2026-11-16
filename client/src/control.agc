## Managing the server of a state folder: stopping it and starting it again. A stop waits until the server is gone.

import Client from "http"
import Discovery from "discovery"

## A stop that asks the server to wait for its turns (up to 60 s) and then close its streams.
STOP_WAIT_MS = 90_000
POLL_MS = 100

## Stops the server of the folder and waits until it is gone: false when none ran. A server of another version may
## not know the stop request, so it gets the signal that ends it; its sessions are on disk.
def stop_and_wait(dir: String, now: Bool) -> Result[Bool]
  case try Discovery.find(dir)
    Discovery.Found.Absent(_) -> ok(false)
    Discovery.Found.Running(server) ->
      try Client.stop_server(server, now)
      try gone(dir)
      ok(true)
    Discovery.Found.Other(pid) ->
      try System.signal(pid, System.Signal.Term, "agentica")
      try gone(dir)
      ok(true)
  end
end

## Stops the server of the folder when one runs, then starts one the way a client does.
def restart(launch: Discovery.Launch, dir: String, now: Bool) -> Result[Client.Server]
  _ = try stop_and_wait(dir, now)
  Discovery.connect(launch, dir)
end

private

def gone(dir: String) -> Result[Void]
  waited = 0
  while waited < STOP_WAIT_MS
    case try Discovery.find(dir)
      Discovery.Found.Absent(_) -> return ok()
      _ -> Task.sleep(POLL_MS)
    end

    waited = waited + POLL_MS
  end

  error("the server of #{dir} did not stop in #{STOP_WAIT_MS / 1000} s", kind: Discovery.KIND_SERVER)
end
