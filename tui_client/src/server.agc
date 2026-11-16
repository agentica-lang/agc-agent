## Finds the server of the state folder, or starts one, with the rules of the line-mode client: the folder and its
## files must be private to the user, a server is alive when `GET /v1/health` with the token of `server.json` answers,
## and clients that start together take a lock on `server.lock` so only the first starts a server.

import Protocol from "pkg/protocol/protocol"
import Args from "args"
import Client from "client"

STATE_DIR_ENV = "FINN_STATE_DIR"
SERVER_COMMAND_ENV = "FINN_SERVER_COMMAND"
KIND_STATE = "tui.state"
KIND_SERVER = "tui.server"
LOCK_WAIT_MS = 20_000
START_WAIT_MS = 10_000
POLL_MS = 100
NOT_FOUND = 127
GROUP_AND_OTHERS = 63

## `--state-dir`, else `FINN_STATE_DIR`, else the user's state folder, with its symlinks resolved.
def state_dir(options: Args.Options) -> Result[String]
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
def connect(options: Args.Options, dir: String) -> Result[Client.Server]
  if File.stat(dir).ok?
    try check_owned(dir, "700")
  end

  case probe(dir)
    Probe.Alive(server) -> ok(server)
    Probe.Unusable(reason) -> refused(dir, reason)
    Probe.Absent(_) -> start(options, dir)
  end
end

private

enum Probe
  Alive(Client.Server)
  Absent(String)
  Unusable(String)
end

def environment_dir() -> Result[String]
  dir = setting(STATE_DIR_ENV)
  return ok(dir) if dir != ""

  base = case System.env("XDG_STATE_HOME")
    ok(xdg) if xdg != "" -> xdg
    _ -> try Path.join([try System.env("HOME"), ".local", "state"])
  end

  finn = try Path.join([base, "finn"])
  old = try Path.join([base, "agc-agent"])
  return ok(old) if not File.stat(finn).ok? and File.stat(old).ok?

  ok(finn)
end

# A `FINN_` variable, else its name before Finn (`AGC_AGENT_`); empty when neither is set.
def setting(name: String) -> String
  value = System.env(name).unwrap_or("")
  return value if value != ""

  System.env("AGC_AGENT_#{name.slice(5, name.length - 5)}").unwrap_or("")
end

def parent_of(path: String) -> String
  parts = path.split("/")
  parent = parts.take(parts.size - 1).join("/")
  return "/" if parent == ""

  parent
end

def file_in(dir: String, name: String) -> String = "#{dir}/#{name}"

def refused[T](dir: String, reason: String) -> Result[T]
  error(
    "a server is registered in #{file_in(dir, "server.json")} but does not serve this client: #{reason}",
    kind: KIND_SERVER,
  )
end

def probe(dir: String) -> Probe
  path = file_in(dir, "server.json")
  return Probe.Absent("no #{path}") if not File.stat(path).ok?

  checked = check_owned(path, "600")
  return Probe.Unusable(checked.message) if not checked.ok?

  case File.read_text(path)
    ok(text) ->
      case Protocol.decode_server_info(text)
        ok(info) -> reach(Client.Server(url: "http://127.0.0.1:#{info.port}", token: info.token))
        error(e) -> Probe.Absent(e.message)
      end

    error(e) -> Probe.Absent(e.message)
  end
end

# A server that does not answer at all is gone; one that answers badly, or too late, is reported.
def reach(server: Client.Server) -> Probe
  case Client.health(server)
    ok(_) -> Probe.Alive(server)
    error(e) if e.kind == Client.KIND_UNREACHABLE and not e.message.include?("timed out") -> Probe.Absent(e.message)
    error(e) -> Probe.Unusable(e.message)
  end
end

def owner_id() -> Optional[Int]
  case File.stat("/proc/self")
    ok(info) -> some(info.user_id)
    error(_) -> none
  end
end

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

def start(options: Args.Options, dir: String) -> Result[Client.Server]
  if not File.stat(dir).ok?
    try Dir.mkdir(parent_of(dir))
    _ = Dir.mkdir_private(dir)
  end

  try check_owned(dir, "700")
  lock_path = file_in(dir, "server.lock")
  for path in [lock_path, file_in(dir, "server.log")]
    try private_file(path)
  end

  File.open(lock_path, "append") do |lock|
    try take_lock(lock)
    case probe(dir)
      Probe.Alive(server) -> ok(server)
      Probe.Unusable(reason) -> refused(dir, reason)
      Probe.Absent(_) ->
        try spawn_server(options, dir)
        wait_alive(dir)
    end
  end
end

def private_file(path: String) -> Result[Void]
  if not File.stat(path).ok?
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

  error("another client is starting the server and did not finish in #{LOCK_WAIT_MS / 1000} s", kind: KIND_SERVER)
end

# The words after --, else FINN_SERVER_COMMAND, else `core/main.agc serve` of the repository this client runs
# from, found by the path of the main file on the command line of this process (never the current folder).
def command_words(options: Args.Options) -> Result[List[String]]
  return ok(options.server_command.unwrap!) if options.server_command.some?

  words = setting(SERVER_COMMAND_ENV).split(" ").select { |word| word != "" }
  return ok(words) if not words.empty?

  line = (try File.read_text("/proc/self/cmdline")).split(String.from_code(0))
  main = try no_command(line.find { |word| word.end_with?("main.agc") })
  resolved = try Path.resolve(main)
  return no_command(error("not the client")) if not resolved.end_with?("/tui_client/main.agc")

  core = "#{parent_of(parent_of(resolved))}/core/main.agc"
  return no_command(error("no core")) if not File.stat(core).ok?

  ok([line[0], core, "serve"])
end

def no_command[T](result: Result[T]) -> Result[T]
  case result
    ok(value) -> ok(value)
    error(_) -> error("no server command: put it after -- or set #{SERVER_COMMAND_ENV}", kind: KIND_SERVER)
  end
end

# The server outlives this client: a shell starts it in the background, in a session of its own.
def spawn_server(options: Args.Options, dir: String) -> Result[Void]
  command = try command_words(options)
  script = "log=$1; shift; command -v \"$1\" >/dev/null || exit #{NOT_FOUND}; \"$@\" </dev/null >>\"$log\" 2>&1 &"
  launcher = try Process.spawn(
    "sh",
    ["-c", script, "sh", file_in(dir, "server.log")] + command,
    Process.Options(env: {STATE_DIR_ENV: dir}, pgroup: true),
  )

  status = try Process.wait(launcher, START_WAIT_MS)
  Process.close(launcher)
  return ok() if status == 0

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

  error("no server answered in #{START_WAIT_MS / 1000} s; see #{file_in(dir, "server.log")}", kind: KIND_SERVER)
end
