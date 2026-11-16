## Managing the server of a state folder: stopping it and starting it again. A stop waits until the server is gone.

import Client from "http"
import Discovery from "discovery"

## How long a stop waits for a server that does not say it is stopping (one of another version, or one that has closed
## its connections); a server that says so is waited for as long as it does.
STOP_WAIT_MS = 30_000
POLL_MS = 100

## Stops the server of the folder and waits until it is gone (its file removed or its process ended, not until it stops
## answering: it refuses connections while it still ends its turns): false when none ran. A server of another version
## may not know the stop request, so it gets the signal that ends it; its sessions are on disk. A second stop with `now`
## makes a server that waits for its turns cancel them.
def stop_and_wait(dir: String, now: Bool) -> Result[Bool]
  case try Discovery.find(dir)
    Discovery.Found.Absent(_) -> ok(false)
    Discovery.Found.Running(server) ->
      pid = try Discovery.server_pid(dir)
      try Client.stop_server(server, now)
      try gone(dir, pid)
      ok(true)
    Discovery.Found.Other(pid) ->
      try System.signal(pid, System.Signal.Term, "agentica")
      try gone(dir, pid)
      ok(true)
  end
end

## Stops the server of the folder when one runs, then starts one the way a client does.
def restart(launch: Discovery.Launch, dir: String, now: Bool) -> Result[Client.Server]
  stopped = try stop_and_wait(dir, now)
  case Discovery.connect(launch, dir)
    ok(server) -> ok(server)
    error(e) ->
      before = "no server ran"
      if stopped
        before = "the old server was stopped"
      end

      error("#{before} and no new one started: #{e.message}", kind: e.kind, cause: e)
  end
end

private

# Whether the server of the folder answers and says that it stops: it waits for its turns, for as long as the setting
# `FINN_DRAIN_MS` of that server says.
def stopping?(dir: String) -> Bool
  case Discovery.find(dir)
    ok(Discovery.Found.Running(server)) ->
      case Client.server_status(server)
        ok(status) -> status.stopping
        error(_) -> false
      end

    _ -> false
  end
end

def gone(dir: String, pid: Int) -> Result[Void]
  waited = 0
  while waited < STOP_WAIT_MS
    return ok() if Discovery.exited?(dir, pid)

    if not stopping?(dir)
      waited = waited + POLL_MS
    end

    Task.sleep(POLL_MS)
  end

  error("the server of #{dir} did not stop in #{STOP_WAIT_MS / 1000} s", kind: Discovery.KIND_SERVER)
end
