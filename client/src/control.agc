## Managing the server of a state folder: stopping it and starting it again. A stop waits until the server is gone.

import Client from "http"
import Discovery from "discovery"

## How long a stop waits for a server that does not say it is stopping (one of another version, or one that has closed
## its connections); a server that says so is waited for as long as it does.
STOP_WAIT_MS = 30_000
## How long a stop with `now` waits after it forced a server that did not stop.
KILL_WAIT_MS = 5000
POLL_MS = 100
## The name of the server's process, which a signal checks: it never reaches a process that took a reused pid.
PROCESS_NAME = "agentica"

## Stops the server of the folder and waits until it is gone (its file removed or its process ended, not until it stops
## answering: it refuses connections while it still ends its turns): false when none ran. A second stop with `now`
## makes a server that waits for its turns cancel them. `wait_ms` is how long it waits for a server that does not say
## it stops.
##
## A server that does not take the request (one of another version, one whose answer fails, or one that holds the
## lock of the folder but answers badly or not at all) gets the signal that ends it, `SIGTERM`, and with `now` it is
## forced (`SIGKILL`); its sessions are on disk. A signal goes only to a process that proves to be the folder's server
## (`Discovery.server_process?`); a folder that is not safe to read (its owner or mode) gets none.
def stop_and_wait(dir: String, now: Bool, wait_ms: Int = STOP_WAIT_MS) -> Result[Bool]
  case Discovery.find(dir)
    ok(found) -> stop_found(dir, found, now, wait_ms)
    error(e) if e.kind == Discovery.KIND_SERVER -> unanswered(dir, now, wait_ms, error(e))
    error(e) -> error(e)
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

def stop_found(dir: String, found: Discovery.Found, now: Bool, wait_ms: Int) -> Result[Bool]
  case found
    Discovery.Found.Running(server) ->
      pid = try Discovery.server_pid(dir)
      asked = Client.stop_server(server, now)
      if not asked.ok?
        try proven(dir, pid, asked.message)
        try signal(pid, now)
      end

      try gone(dir, pid, now, wait_ms)
      ok(true)
    Discovery.Found.Other(pid, _) ->
      try proven(dir, pid, "it is of another version")
      signalled(dir, pid, now, wait_ms)
    Discovery.Found.Absent(_) -> unanswered(dir, now, wait_ms, ok(false))
  end
end

# A server that holds the lock of the folder but does not answer, or answers badly, is stopped by the pid of its
# `server.json` once it proves to be the folder's server; `otherwise` is the answer when it does not.
def unanswered(dir: String, now: Bool, wait_ms: Int, otherwise: Result[Bool]) -> Result[Bool]
  case Discovery.server_pid(dir)
    ok(pid) if Discovery.server_process?(dir, pid) -> signalled(dir, pid, now, wait_ms)
    _ -> otherwise
  end
end

def proven(dir: String, pid: Int, why: String) -> Result[Void]
  return ok() if Discovery.server_process?(dir, pid)

  error(
    "the server of #{dir} (pid #{pid}) did not take the stop (#{why}), and the process is not proved to be it " +
    "(the lock of the folder, its name, start time and state folder): nothing was signalled",
    kind: Discovery.KIND_SERVER,
  )
end

def signalled(dir: String, pid: Int, now: Bool, wait_ms: Int) -> Result[Bool]
  try signal(pid, now)
  try gone(dir, pid, now, wait_ms)
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

# A server still there after the wait is forced with `now`; without it, the error names the stop that does that.
def gone(dir: String, pid: Int, now: Bool, wait_ms: Int) -> Result[Void]
  return ok() if stopped_in_time(dir, pid, wait_ms)

  if now
    try signal(pid, true)
    return ok() if exited_within(dir, pid, KILL_WAIT_MS)

    return error("the server of #{dir} (pid #{pid}) did not end when forced", kind: Discovery.KIND_SERVER)
  end

  error(
    "the server of #{dir} (pid #{pid}) did not stop in #{wait_ms / 1000} s: " +
    "`#{Discovery.server_command(dir, "stop --now")}` ends it at once (the sessions are kept)",
    kind: Discovery.KIND_SERVER,
  )
end

# Waits for the server to go, as long as it says it stops and `wait_ms` besides.
def stopped_in_time(dir: String, pid: Int, wait_ms: Int) -> Bool
  waited = 0
  while waited < wait_ms
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
