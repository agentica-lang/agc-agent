## Finds the server of the state folder, or starts one. A server is alive when `GET /v1/health` with the token of
## `server.json` answers, not when its pid exists. Clients that start together take an exclusive lock on `server.lock`,
## so only the first starts a server and the others find it. A server that answers badly (wrong token, no answer in
## time) is reported, never started over.
##
## The state folder must be private to the user (0700, owned by them); so must `server.json`, `server.lock` and
## `server.log` (0600). Anything else is refused with the command that fixes it.

import Client from "client"
import Args from "args"

STATE_DIR_ENV = "AGC_AGENT_STATE_DIR"
SERVER_COMMAND_ENV = "AGC_AGENT_SERVER_COMMAND"
SERVER_FILE = "server.json"
LOCK_FILE = "server.lock"
LOG_FILE = "server.log"
KIND_STATE = "cli.state"
KIND_SERVER = "cli.server"
LOCK_WAIT_MS = 20_000
START_WAIT_MS = 10_000
POLL_MS = 100
NOT_FOUND = 127
GROUP_AND_OTHERS = 63

## The folder of `server.json`: `--state-dir`, else `AGC_AGENT_STATE_DIR`, else the user's state folder.
def state_dir(options: Args.Options) -> Result[String]
  dir = case options.state_dir
    some(text) -> text
    none -> try environment_dir()
  end

  Path.resolve(dir)
end

## The running server of the folder, started first when none runs.
def connect(options: Args.Options, dir: String) -> Result[Client.Server]
  if File.stat(dir).ok?
    try check_owned(dir, "700")
  end

  case probe(dir)
    Probe.Alive(server) -> ok(server)
    Probe.Unusable(reason) -> refused(dir, reason)
    Probe.Absent(reason) -> start(options, dir, reason)
  end
end

private

struct ServerFile
  port: Int
  token: String
  pid: Int
end

enum Probe
  Alive(Client.Server)
  ## Nothing serves: start one.
  Absent(String)
  ## Something is there that does not serve this client: start nothing.
  Unusable(String)
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

def file_in(dir: String, name: String) -> String = "#{dir}/#{name}"

def refused[T](dir: String, reason: String) -> Result[T]
  error(
    "a server is registered in #{file_in(dir, SERVER_FILE)} but does not serve this client: #{reason}; " +
    "not starting another (remove the file if the server is gone)",
    kind: KIND_SERVER,
  )
end

def probe(dir: String) -> Probe
  path = file_in(dir, SERVER_FILE)
  return Probe.Absent("#{path} does not exist") if not File.stat(path).ok?

  checked = check_owned(path, "600")
  return Probe.Unusable(checked.message) if not checked.ok?

  case read_info(path)
    ok(info) -> reach(info)
    error(e) -> Probe.Absent("#{path} cannot be read: #{e.message}")
  end
end

def read_info(path: String) -> Result[ServerFile] = JSON.decode(try File.read_text(path), ServerFile)

def reach(info: ServerFile) -> Probe
  return Probe.Absent("the pid #{info.pid} of server.json is not a process of yours") if foreign_pid?(info.pid)

  server = Client.Server(url: "http://127.0.0.1:#{info.port}", token: info.token)
  case Client.health(server)
    ok(_) -> Probe.Alive(server)
    error(e) if e.kind == Client.KIND_UNREACHABLE -> Probe.Absent(e.message)
    error(e) -> Probe.Unusable(e.message)
  end
end

# Where there is a /proc, a pid that is not there or belongs to someone else is not our server.
def foreign_pid?(pid: Int) -> Bool
  return false if not File.stat("/proc/self").ok?

  case File.stat("/proc/#{pid}")
    ok(info) -> info.user_id != owner_id().unwrap_or(info.user_id)
    error(_) -> true
  end
end

# The user id of this process, from the owner of its /proc entry or of the home folder; none where neither is there.
def owner_id() -> Optional[Int]
  case File.stat("/proc/self")
    ok(info) -> some(info.user_id)
    error(_) -> home_owner()
  end
end

def home_owner() -> Optional[Int]
  case System.env("HOME")
    ok(home) ->
      case File.stat(home)
        ok(info) -> some(info.user_id)
        error(_) -> none
      end

    error(_) -> none
  end
end

# `path` must be the user's and closed to the group and the others; `mode` is what to chmod it to otherwise.
def check_owned(path: String, mode: String) -> Result[Void]
  me = owner_id()
  return ok() if me.none?

  info = try File.stat(path)
  if info.user_id != me.unwrap!
    return error("#{path} is not owned by you: do not use this state folder", kind: KIND_STATE)
  end

  if info.mode.bit_and(GROUP_AND_OTHERS) != 0
    return error("#{path} is open to other users: run `chmod #{mode} #{path}`", kind: KIND_STATE)
  end

  ok()
end

def start(options: Args.Options, dir: String, why_not: String) -> Result[Client.Server]
  try make_dir(dir)
  lock_path = file_in(dir, LOCK_FILE)
  try private_file(lock_path)
  try private_file(file_in(dir, LOG_FILE))
  File.open(lock_path, "append") do |lock|
    try take_lock(lock)
    case probe(dir)
      Probe.Alive(server) -> ok(server)
      Probe.Unusable(reason) -> refused(dir, reason)
      Probe.Absent(_) -> explained(started(options, dir), why_not)
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
    error(e) -> error("#{e.message} (no server runs: #{why_not})", kind: e.kind, cause: e)
  end
end

# The folder is made 0700; the folders above it, when missing, get the default mode.
def make_dir(dir: String) -> Result[Void]
  if not File.stat(dir).ok?
    try Dir.mkdir(parent_of(dir))
    try Dir.mkdir_private(dir)
  end

  check_owned(dir, "700")
end

def parent_of(dir: String) -> String
  parts = dir.split("/")
  parent = parts.take(parts.size - 1).join("/")
  return "/" if parent == ""

  parent
end

def private_file(path: String) -> Result[Void]
  if not File.stat(path).ok?
    try File.open(path, "create_private") do |_file| ok() end
  end

  check_owned(path, "600")
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

# TODO (issue #17): there is no default command until the core has its entry point. It must never be found in the
# current folder: a repository you cd into would run its code.
def command_words(options: Args.Options) -> Result[List[String]]
  return ok(options.server_command.unwrap!) if options.server_command.some?

  text = System.env(SERVER_COMMAND_ENV).unwrap_or("")
  words = text.split(" ").select { |word| word != "" }
  return ok(words) if not words.empty?

  error("no server command: pass --server-command, put it after --, or set #{SERVER_COMMAND_ENV}", kind: KIND_SERVER)
end

# The server must outlive this client, so a shell starts it in the background, in a session of its own.
def spawn_server(options: Args.Options, dir: String) -> Result[Void]
  command = try command_words(options)
  script = "log=$1; shift; command -v \"$1\" >/dev/null || exit #{NOT_FOUND}; \"$@\" </dev/null >>\"$log\" 2>&1 &"
  launcher = try Process.spawn(
    "sh",
    ["-c", script, "sh", file_in(dir, LOG_FILE)] + command,
    Process.Options(env: {STATE_DIR_ENV: dir}, pgroup: true),
  )

  status = try Process.wait(launcher, START_WAIT_MS)
  Process.close(launcher)
  return ok() if status == 0
  return error("the server command was not found: #{command.join(" ")}", kind: KIND_SERVER) if status == NOT_FOUND

  error("the server command could not be started (exit #{status}): #{command.join(" ")}", kind: KIND_SERVER)
end

def wait_alive(dir: String) -> Result[Client.Server]
  waited = 0
  while waited < START_WAIT_MS
    case probe(dir)
      Probe.Alive(server) -> return ok(server)
      Probe.Unusable(reason) -> return refused(dir, reason)
      Probe.Absent(_) -> Task.sleep(POLL_MS)
    end

    waited = waited + POLL_MS
  end

  error("no server answered in #{START_WAIT_MS / 1000} s; see #{file_in(dir, LOG_FILE)}", kind: KIND_SERVER)
end
