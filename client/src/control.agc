## Managing the server of a state folder: stopping it and starting it again. A stop waits until the server is gone.

import Client from "http"
import Discovery from "discovery"

## How long a stop waits for a server that does not say it is stopping (one of another version, or one that has closed
## its connections); a server that says so is waited for as long as it does.
STOP_WAIT_MS = 30_000
## How long a stop with `now` waits after the kill of a server that did not stop.
KILL_WAIT_MS = 5000
POLL_MS = 100
## The name of the server's process, which a signal checks: it never reaches a process that took a reused pid.
PROCESS_NAME = "agentica"

## Stops the server of the folder and waits until it is gone (its file removed or its process ended, not until it stops
## answering: it refuses connections while it still ends its turns): false when none ran. A second stop with `now`
## makes a server that waits for its turns cancel them.
##
## A server that does not take the request (one of another version, one whose answer fails, or one that holds the
## lock of the folder but does not answer) gets the signal that ends it, `SIGTERM`, and with `now` `SIGKILL`; its
## sessions are on disk.
def stop_and_wait(dir: String, now: Bool) -> Result[Bool]
  case Discovery.find(dir)
    ok(found) -> stop_found(dir, found, now)
    error(e) -> unanswered(dir, now, error(e))
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

def stop_found(dir: String, found: Discovery.Found, now: Bool) -> Result[Bool]
  case found
    Discovery.Found.Running(server) ->
      pid = try Discovery.server_pid(dir)
      if not Client.stop_server(server, now).ok?
        try signal(pid, now)
      end

      try gone(dir, pid, now)
      ok(true)
    Discovery.Found.Other(pid, _) -> signalled(dir, pid, now)
    Discovery.Found.Absent(_) -> unanswered(dir, now, ok(false))
  end
end

# A server that holds the lock of the folder but does not answer, or answers badly, is stopped by the pid of its
# `server.json`; `otherwise` is the answer when none holds it.
def unanswered(dir: String, now: Bool, otherwise: Result[Bool]) -> Result[Bool]
  return otherwise if not Discovery.held?(dir)

  case Discovery.server_pid(dir)
    ok(pid) -> signalled(dir, pid, now)
    error(_) -> otherwise
  end
end

def signalled(dir: String, pid: Int, now: Bool) -> Result[Bool]
  try signal(pid, now)
  try gone(dir, pid, now)
  ok(true)
end

def signal(pid: Int, now: Bool) -> Result[Void]
  return System.signal(pid, System.Signal.Kill, PROCESS_NAME) if now

  System.signal(pid, System.Signal.Term, PROCESS_NAME)
end

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

# A server still there after the wait is killed with `now`; without it, the error names the stop that does that.
def gone(dir: String, pid: Int, now: Bool) -> Result[Void]
  return ok() if stopped_in_time(dir, pid)

  if now
    try signal(pid, true)
    return ok() if exited_within(dir, pid, KILL_WAIT_MS)

    return error("the server of #{dir} (pid #{pid}) did not end after SIGKILL", kind: Discovery.KIND_SERVER)
  end

  error(
    "the server of #{dir} (pid #{pid}) did not stop in #{STOP_WAIT_MS / 1000} s: " +
    "`#{Discovery.server_command(dir, "stop --now")}` ends it at once (the sessions are kept)",
    kind: Discovery.KIND_SERVER,
  )
end

# Waits for the server to go, as long as it says it stops and `STOP_WAIT_MS` besides.
def stopped_in_time(dir: String, pid: Int) -> Bool
  waited = 0
  while waited < STOP_WAIT_MS
    return true if Discovery.exited?(dir, pid)

    if not stopping?(dir)
      waited = waited + POLL_MS
    end

    Task.sleep(POLL_MS)
  end

  false
end

def exited_within(dir: String, pid: Int, limit_ms: Int) -> Bool
  waited = 0
  while waited < limit_ms
    return true if Discovery.exited?(dir, pid)

    Task.sleep(POLL_MS)
    waited = waited + POLL_MS
  end

  Discovery.exited?(dir, pid)
end
