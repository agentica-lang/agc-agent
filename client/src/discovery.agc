## Finds the server of the state folder, or starts one. A server is alive when `GET /v1/health` with the token of
## `server.json` answers, not when its pid exists. Clients that start together take an exclusive lock on `server.lock`,
## so only the first starts a server and the others find it. A server that answers badly (wrong token, no answer in
## time) is reported, never started over.
##
## The state folder must be private to the user (0700, owned by them); so must `server.json`, `server.lock` and
## `server.log` (0600). Anything else is refused with the command that fixes it.

import Protocol from "pkg/protocol/protocol"
import Client from "http"

STATE_DIR_ENV = "FINN_STATE_DIR"
SERVER_COMMAND_ENV = "FINN_SERVER_COMMAND"
CODE_MODE_ENV = "FINN_CODE_MODE"
SERVER_FILE = "server.json"
LOCK_FILE = "server.lock"
LOG_FILE = "server.log"
KIND_STATE = "client.state"
KIND_SERVER = "client.server"
KIND_VERSION = "client.version"
## A first start compiles the core and builds the native module of `bash`, which can take most of a minute.
START_WAIT_MS = 60_000
## Longer than a start, which another client may be waiting for.
LOCK_WAIT_MS = 70_000
## When a start that has not answered yet says that it builds.
SLOW_START_MS = 5_000
POLL_MS = 100
NOT_FOUND = 127
GROUP_AND_OTHERS = 63
LOG_KEEP_BYTES = 10_485_760

## How a client finds or starts its server. `none` takes the default: the state folder of the environment, and the
## server command of `FINN_SERVER_COMMAND`, else `core/main.agc serve` of the repository the client runs from, which
## `main` names (`cli/main.agc`, the client's own entry point from the repository root).
struct Launch
  main: String
  state_dir: Optional[String] = none
  server_command: Optional[List[String]] = none
  ## Off (`--no-codemode` or `FINN_CODE_MODE=0`): a server this client starts has no code mode.
  code_mode: Bool = true
end

## What runs in the folder: a server of this client's version, one of another version (its pid), or nothing (why).
enum Found
  Running(Client.Server)
  Other(Int)
  Absent(String)
end

## The folder of `server.json`: `--state-dir`, else `FINN_STATE_DIR`, else the user's state folder, with its
## symlinks resolved. A symlink that is not yours is refused.
def state_dir(options: Launch) -> Result[String]
  dir = case options.state_dir
    some(text) -> text
    none -> try environment_dir()
  end

  path = try Path.resolve(dir)
  return ok(path) if not File.lstat(path).ok?

  try check_link(path)
  Path.real(path)
end

## The running server of the folder, started first when none runs.
def connect(options: Launch, dir: String) -> Result[Client.Server]
  if File.stat(dir).ok?
    try check_owned(dir, "700")
  end

  case probe(dir)
    Probe.Alive(server) -> ok(server)
    Probe.Unusable(reason) -> refused(dir, reason)
    Probe.Other(pid) -> other_version(dir, pid)
    Probe.Absent(reason) -> start(options, dir, reason)
  end
end

## The code mode a client asks for: off with `--no-codemode`, else what `FINN_CODE_MODE` (`env`) says; none when
## neither says.
def code_mode_wanted(no_codemode: Bool, env: Optional[String]) -> Optional[Bool]
  return some(false) if no_codemode

  case env
    some("0") -> some(false)
    some("1") -> some(true)
    _ -> none
  end
end

## `code_mode_wanted` of this process's `FINN_CODE_MODE`.
def code_mode_asked(no_codemode: Bool) -> Optional[Bool]
  case System.env(CODE_MODE_ENV)
    ok(value) -> code_mode_wanted(no_codemode, some(value))
    error(_) -> code_mode_wanted(no_codemode, none)
  end
end

## Code mode is the server's, set when it starts: one line when the running server's is not the one `wanted`, saying
## how to apply it; "" when it is, when nothing is wanted, or when the server does not say.
def code_mode_note(server: Client.Server, wanted: Optional[Bool]) -> String
  for want in option_list(wanted)
    case Client.server_status(server)
      ok(status) if status.code_mode == some(not want) -> return code_mode_line(want)
      _ -> nil
    end
  end

  ""
end

## The server of the folder, without starting one. A server that answers badly is an error.
def find(dir: String) -> Result[Found]
  if File.stat(dir).ok?
    try check_owned(dir, "700")
  end

  case probe(dir)
    Probe.Alive(server) -> ok(Found.Running(server))
    Probe.Other(pid) -> ok(Found.Other(pid))
    Probe.Absent(reason) -> ok(Found.Absent(reason))
    Probe.Unusable(reason) -> refused(dir, reason)
  end
end

## The pid in the `server.json` of the folder.
def server_pid(dir: String) -> Result[Int]
  info = try read_info(file_in(dir, SERVER_FILE))
  ok(info.pid)
end

## True once the server that had `pid` is gone: its `server.json` is removed (or names another server), or, where there
## is a /proc, the process has exited. A server that stops refuses connections before it is gone, so the answer of its
## health check says nothing about this.
def exited?(dir: String, pid: Int) -> Bool
  case server_pid(dir)
    ok(now) if now == pid -> pid_gone?(pid)
    _ -> true
  end
end

## The file the server writes its output to.
def log_file(dir: String) -> String = file_in(dir, LOG_FILE)

## Checks again that the server is of this client's version, as a client does before it reads the event stream again.
## A server that does not answer is left to the reconnect.
def recheck(server: Client.Server) -> Result[Void]
  case Client.health(server)
    ok(health) if health.wire != some(Protocol.wire_digest()) ->
      error(
        "the server now runs another version of Finn Agent than this client: start the client again",
        kind: KIND_VERSION,
      )
    _ -> ok()
  end
end

private

enum Probe
  Alive(Client.Server)
  ## Nothing serves: start one.
  Absent(String)
  ## Something is there that does not serve this client: start nothing.
  Unusable(String)
  ## A server of another version, with its pid.
  Other(Int)
end

def environment_dir() -> Result[String]
  dir = setting(STATE_DIR_ENV)
  return ok(dir) if dir != ""

  user_state_dir()
end

## The value of a `FINN_` variable, else of its name before Finn (`AGC_AGENT_`); empty when neither is set.
def setting(name: String) -> String
  value = System.env(name).unwrap_or("")
  return value if value != ""

  System.env("AGC_AGENT_#{name.slice(5, name.length - 5)}").unwrap_or("")
end

## `finn` of the user's state folder, else `agc-agent` while only that one is there.
def user_state_dir() -> Result[String]
  base = case System.env("XDG_STATE_HOME")
    ok(xdg) if xdg != "" -> xdg
    _ -> try Path.join([try System.env("HOME"), ".local", "state"])
  end

  dir = try Path.join([base, "finn"])
  old = try Path.join([base, "agc-agent"])
  return ok(old) if not File.stat(dir).ok? and File.stat(old).ok?

  ok(dir)
end

def file_in(dir: String, name: String) -> String = "#{dir}/#{name}"

def refused[T](dir: String, reason: String) -> Result[T]
  error(
    "a server is registered in #{file_in(dir, SERVER_FILE)} but does not serve this client: #{reason}; " +
    "not starting another (remove the file if the server is gone)",
    kind: KIND_SERVER,
  )
end

# A server from other code may not read what this client sends, nor send what it reads: it is never used. Stopping it
# ends the turn it runs; the sessions are on disk, so the next server reads them.
def other_version[T](dir: String, pid: Int) -> Result[T]
  error(
    "the server of #{dir} (pid #{pid}) runs another version of Finn Agent than this client: " +
    "once no turn runs there, stop it with `kill #{pid}` and start the client again (the sessions are kept)",
    kind: KIND_VERSION,
  )
end

def probe(dir: String) -> Probe
  path = file_in(dir, SERVER_FILE)
  return Probe.Absent("#{path} does not exist") if not File.stat(path).ok?

  checked = check_owned(path, "600")
  # A server that stops removes its file at any time: gone since the check is not unusable.
  return Probe.Absent("#{path} does not exist") if not checked.ok? and not File.stat(path).ok?
  return Probe.Unusable(checked.message) if not checked.ok?

  case read_info(path)
    ok(info) -> reach(info)
    error(e) -> Probe.Absent("#{path} cannot be read: #{e.message}")
  end
end

def read_info(path: String) -> Result[Protocol.ServerInfo] = Protocol.decode_server_info(try File.read_text(path))

def reach(info: Protocol.ServerInfo) -> Probe
  return Probe.Absent("the pid #{info.pid} of server.json is not a process of yours") if foreign_pid?(info.pid)

  server = Client.Server(url: "http://127.0.0.1:#{info.port}", token: info.token)
  case Client.health(server)
    ok(health) if health.wire != some(Protocol.wire_digest()) -> Probe.Other(info.pid)
    ok(_) -> Probe.Alive(server)
    error(e) if e.kind == Client.KIND_UNREACHABLE -> Probe.Absent(e.message)
    error(e) -> Probe.Unusable(e.message)
  end
end

def pid_gone?(pid: Int) -> Bool = File.stat("/proc/self").ok? and not File.stat("/proc/#{pid}").ok?

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

  try check_link(path)
  info = try File.stat(path)
  if info.user_id != me.unwrap!
    return error("#{path} is not owned by you: do not use this state folder", kind: KIND_STATE)
  end

  if info.mode.bit_and(GROUP_AND_OTHERS) != 0
    return error("#{path} is open to other users: run `chmod #{mode} #{path}`", kind: KIND_STATE)
  end

  ok()
end

def check_link(path: String) -> Result[Void]
  me = owner_id()
  return ok() if me.none?

  info = try File.lstat(path)
  if info.kind == "link" and info.user_id != me.unwrap!
    return error("#{path} is a symlink you do not own: do not use this state folder", kind: KIND_STATE)
  end

  ok()
end

def start(options: Launch, dir: String, why_not: String) -> Result[Client.Server]
  try make_dir(dir)
  lock_path = file_in(dir, LOCK_FILE)
  try private_file(lock_path)
  try private_file(file_in(dir, LOG_FILE))
  File.open(lock_path, "append") do |lock|
    try take_lock(lock)
    case probe(dir)
      Probe.Alive(server) -> ok(server)
      Probe.Unusable(reason) -> refused(dir, reason)
      Probe.Other(pid) -> other_version(dir, pid)
      Probe.Absent(_) -> explained(started(options, dir), why_not)
    end
  end
end

def code_mode_line(wanted: Bool) -> String
  return "the running server has code mode off; `finn server restart` applies it" if wanted

  "the running server has code mode on; `finn server restart --no-codemode` applies it"
end

def started(options: Launch, dir: String) -> Result[Client.Server]
  try rotate_log(dir)
  try spawn_server(options, dir)
  wait_alive(dir)
end

# A log over `LOG_KEEP_BYTES` becomes `server.log.1` (the one before it goes), and a new one starts private.
def rotate_log(dir: String) -> Result[Void]
  path = file_in(dir, LOG_FILE)
  big = case File.stat(path)
    ok(info) -> info.size_bytes > LOG_KEEP_BYTES
    error(_) -> false
  end

  return ok() if not big

  _ = Path.remove("#{path}.1")
  try Path.rename(path, "#{path}.1")
  private_file(path)
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
    # Another client may make it first: it is checked below.
    _ = Dir.mkdir_private(dir)
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
    # Another client may create it first: it is checked below.
    _ = File.open(path, "create_private") do |_file| ok() end
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

  error("another client is starting the server and did not finish in #{LOCK_WAIT_MS / 1000} s", kind: "client.lock")
end

# The server command: the one given, else FINN_SERVER_COMMAND, else the core's entry point next to this client.
def command_words(options: Launch) -> Result[List[String]]
  return ok(options.server_command.unwrap!) if options.server_command.some?

  words = setting(SERVER_COMMAND_ENV).split(" ").select { |word| word != "" }
  return ok(words) if not words.empty?

  default_command(options.main)
end

# `core/main.agc serve` of the repository this client runs from, found by the path of the main file on the command line
# of this process (Linux). Never the current folder: a repository you cd into must not run its code.
def default_command(main_file: String) -> Result[List[String]]
  words = (try File.read_text("/proc/self/cmdline")).split(String.from_code(0))
  found = words.find { |word| word.end_with?("main.agc") }
  case found
    ok(main) -> core_command(words[0], main, main_file)
    error(_) -> no_command()
  end
end

def core_command(program: String, main: String, main_file: String) -> Result[List[String]]
  resolved = try Path.resolve(main)
  return no_command() if not resolved.end_with?("/#{main_file}")

  root = parent_of(parent_of(resolved))
  core = "#{root}/core/main.agc"
  return no_command() if not File.stat(core).ok?

  ok([program, core, "serve"])
end

def no_command() -> Result[List[String]]
  error("no server command: give one after --, or set #{SERVER_COMMAND_ENV}", kind: KIND_SERVER)
end

# The server must outlive this client, so a shell starts it in the background, in a session of its own.
def spawn_server(options: Launch, dir: String) -> Result[Void]
  command = try command_words(options)
  script = "log=$1; shift; command -v \"$1\" >/dev/null || exit #{NOT_FOUND}; \"$@\" </dev/null >>\"$log\" 2>&1 &"
  launcher = try Process.spawn(
    "sh",
    ["-c", script, "sh", file_in(dir, LOG_FILE)] + command,
    Process.Options(env: server_env(options, dir), pgroup: true),
  )

  status = try Process.wait(launcher, START_WAIT_MS)
  Process.close(launcher)
  return ok() if status == 0
  return error("the server command was not found: #{command.join(" ")}", kind: KIND_SERVER) if status == NOT_FOUND

  error("the server command could not be started (exit #{status}): #{command.join(" ")}", kind: KIND_SERVER)
end

def server_env(options: Launch, dir: String) -> Map[String, String]
  return {STATE_DIR_ENV: dir} if options.code_mode

  {STATE_DIR_ENV: dir, CODE_MODE_ENV: "0"}
end

def wait_alive(dir: String) -> Result[Client.Server]
  waited = 0
  while waited < START_WAIT_MS
    case probe(dir)
      Probe.Alive(server) -> return ok(server)
      Probe.Unusable(reason) -> return refused(dir, reason)
      Probe.Other(pid) -> return other_version(dir, pid)
      Probe.Absent(_) -> Task.sleep(POLL_MS)
    end

    waited = waited + POLL_MS
    if waited == SLOW_START_MS
      IO.warn("the server is still starting: a first start builds it, which can take a minute")
    end
  end

  error("no server answered in #{START_WAIT_MS / 1000} s; see #{file_in(dir, LOG_FILE)}", kind: KIND_SERVER)
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
