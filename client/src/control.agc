## Managing the server of a state folder: stopping it and starting it again. A stop waits until the server is gone.

import Client from "http"
import Discovery from "discovery"
import Version from "version"

## How long a stop waits for a server that does not say it is stopping (one of another version, or one that has closed
## its connections); a server that says so is waited for as long as it does.
STOP_WAIT_MS = 30_000
## How long a stop with `now` waits after it forced a server that did not stop.
KILL_WAIT_MS = 5000
POLL_MS = 100
TERMINAL_CHECK_MS = 5000
## The name of the server's process, which a signal checks: it never reaches a process that took a reused pid.
PROCESS_NAME = "agentica"

## How a client answers a server of another version: on a terminal it asks (`ask` prints the question and gives the line
## typed, none at the end of the input); `restart` answers yes without a question; with neither it changes nothing.
struct Asking
  terminal: Bool
  restart: Bool
  ask: Fn[String, Optional[String]]
end

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

## The way of this process: a terminal when stdin and stdout are one and the client is `interactive`, `restart` as the
## launch or `FINN_RESTART=1` says, the question on the screen and the answer from the input.
def asking(launch: Discovery.Launch, interactive: Bool) -> Asking
  Asking(
    terminal: interactive and terminal?(),
    restart: launch.restart or System.env(RESTART_ENV).unwrap_or("") == "1",
    ask: ->(text: String) { asked(text) },
  )
end

## The running server of the folder, started first when none runs; a server of another version is restarted when
## `asking` says yes, else it is the error of `Discovery.connect` (the version, and `finn server restart`).
def connect_asking(launch: Discovery.Launch, dir: String, asking: Asking) -> Result[Client.Server]
  case Discovery.connect(launch, dir)
    ok(server) -> ok(server)
    error(e) if e.kind == Discovery.KIND_VERSION ->
      case Discovery.find(dir)
        ok(Discovery.Found.Other(pid, version)) ->
          wanted = try restart_wanted(asking, pid, version, Discovery.running_turns(dir), Version.finn_version())
          return error(e) if not wanted

          restart(launch, dir, false)
        _ -> error(e)
      end

    error(e) -> error(e)
  end
end

## `connect_asking` with the way of this process.
def connect_or_restart(launch: Discovery.Launch, dir: String, interactive: Bool = true) -> Result[Client.Server]
  connect_asking(launch, dir, asking(launch, interactive))
end

## Whether the server (`pid`, `version`, running `turns` turns when it says) is to be restarted by the `client` version: yes without a question
## when `restart`; no without a terminal; else what the person answers, an empty line being the default of the question.
def restart_wanted(asking: Asking, pid: Int, version: String, turns: Optional[Int], client: String) -> Result[Bool]
  return ok(true) if asking.restart
  return ok(false) if not asking.terminal

  lines = Version.restart_question(client, version, pid, turns)
  default = Version.restart_default_yes?(turns)
  for _ in 0...ASKS
    answer = asking.ask.call(lines.join("\n"))
    return ok(false) if answer.none?

    said = Version.answer_yes(answer.unwrap!, default)
    return ok(said.unwrap!) if said.some?
  end

  ok(false)
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

RESTART_ENV = "FINN_RESTART"
## Asked this many times; an answer that is neither yes nor no each time is no.
ASKS = 3

# Prints the question and reads the line typed.
def asked(text: String) -> Optional[String]
  print("#{text} ")
  IO.flush()
  case IO.gets
    ok(line) -> some(line)
    error(_) -> none
  end
end

# Stdin and stdout are a terminal: a child that shares them says so.
def terminal?() -> Bool
  case Process.spawn_group("sh", ["-c", "test -t 0 && test -t 1"])
    ok(running) -> Process.wait(running, TERMINAL_CHECK_MS).unwrap_or(1) == 0
    error(_) -> false
  end
end

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
    try proven(dir, pid, "it did not stop in time")
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
