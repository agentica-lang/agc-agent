## Finds the server of the state folder, or starts one. A server is alive when `GET /v1/health` with the token of
## `server.json` answers, not when its pid exists. Clients that start together take an exclusive lock on `server.lock`,
## so only the first starts a server and the others find it.

import Client from "client"
import Args from "args"

STATE_DIR_ENV = "AGC_AGENT_STATE_DIR"
SERVER_FILE = "server.json"
LOCK_FILE = "server.lock"
LOG_FILE = "server.log"
# TODO: the command of the core server (issue #17). The server reads its state folder from STATE_DIR_ENV and writes
# SERVER_FILE there; until it exists, `--server-command` names the program that does.
DEFAULT_COMMAND = ["agentica", "core/main.agc", "serve"]
LOCK_WAIT_MS = 20_000
START_WAIT_MS = 10_000
POLL_MS = 100
PROBE_TIMEOUT_MS = 2_000

## The folder of `server.json`: `--state-dir`, else `AGC_AGENT_STATE_DIR`, else the user's state folder.
def state_dir(options: Args.Options) -> Result[String]
  case options.state_dir
    some(dir) -> ok(dir)
    none -> environment_dir()
  end
end

## The running server of the folder, started first when none answers.
def connect(options: Args.Options, dir: String) -> Result[Client.Server]
  case probe(dir)
    ok(server) -> ok(server)
    error(reason) -> start(options, dir, reason.message)
  end
end

private

struct ServerFile
  port: Int
  token: String
end

def environment_dir() -> Result[String]
  case System.env(STATE_DIR_ENV)
    ok(dir) if dir != "" -> ok(dir)
    _ -> user_state_dir()
  end
end

def user_state_dir() -> Result[String]
  case System.env("XDG_STATE_HOME")
    ok(base) if base != "" -> Path.join([base, "agc-agent"])
    _ -> Path.join([try System.env("HOME"), ".local", "state", "agc-agent"])
  end
end

# The server of server.json when it answers its health with the token; else why it does not.
def probe(dir: String) -> Result[Client.Server]
  path = try Path.join([dir, SERVER_FILE])
  text = try File.read_text(path)
  info = try JSON.decode(text, ServerFile)
  server = Client.Server(url: "http://127.0.0.1:#{info.port}", token: info.token)
  _ = try Client.health(server)
  ok(server)
end

def start(options: Args.Options, dir: String, why_not: String) -> Result[Client.Server]
  try make_dir(dir)
  lock_path = try Path.join([dir, LOCK_FILE])
  File.open(lock_path, "append") do |lock|
    try take_lock(lock)
    case probe(dir)
      ok(server) -> ok(server)
      error(_) -> explained(started(options, dir), why_not)
    end
  end
end

def started(options: Args.Options, dir: String) -> Result[Client.Server]
  try spawn_server(options, dir)
  wait_alive(dir)
end

def explained[T](result: Result[T], why_not: String) -> Result[T]
  case result
    ok(value) -> ok(value)
    error(e) -> error("#{e.message} (the server of server.json does not answer: #{why_not})", kind: e.kind, cause: e)
  end
end

def make_dir(dir: String) -> Result[Void]
  return ok() if File.stat(dir).ok?

  case Dir.mkdir_private(dir)
    ok(_) -> ok()
    error(_) -> Dir.mkdir(dir)
  end
end

def take_lock(lock: File.Handle) -> Result[Void]
  waited = 0
  while waited < LOCK_WAIT_MS
    return ok() if try File.try_lock(lock)

    Task.sleep(POLL_MS)
    waited = waited + POLL_MS
  end

  error("another client is starting the server and did not finish in #{LOCK_WAIT_MS / 1000} s", kind: "cli.lock")
end

# The server must outlive this client, so a shell starts it in the background, in a session of its own.
def spawn_server(options: Args.Options, dir: String) -> Result[Void]
  command = case options.server_command
    some(text) -> text.split(" ").select { |word| word != "" }
    none -> DEFAULT_COMMAND
  end

  log = try Path.join([dir, LOG_FILE])
  script = "log=$1; shift; command -v \"$1\" >/dev/null || exit 127; \"$@\" </dev/null >>\"$log\" 2>&1 &"
  launcher = try Process.spawn(
    "sh",
    ["-c", script, "sh", log] + command,
    Process.Options(env: {STATE_DIR_ENV: dir}, pgroup: true),
  )

  status = try Process.wait(launcher, START_WAIT_MS)
  Process.close(launcher)
  return error("the server command was not found: #{command.join(" ")}", kind: "cli.start") if status != 0

  ok()
end

def wait_alive(dir: String) -> Result[Client.Server]
  waited = 0
  while waited < START_WAIT_MS
    case probe(dir)
      ok(server) -> return ok(server)
      error(_) -> Task.sleep(POLL_MS)
    end

    waited = waited + POLL_MS
  end

  error("no server answered in #{START_WAIT_MS / 1000} s; see #{dir}/#{LOG_FILE}", kind: "cli.start")
end
