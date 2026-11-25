## Runs the client as a child process on pipes, against a fake server, and reads what it prints.

import HTTP from "std/http"
import Fake from "fake_server"

READ_MS = 10_000
EXIT_MS = 15_000
COMPILE_MS = 120_000
## How long a server of a test folder has for SIGTERM before its process group gets SIGKILL.
STOP_MS = 5000
POLL_MS = 50
FOLDER_PREFIX = "agc-cli-"
NUL = String.from_code(0)
ENTRIES = ["main.agc", "cli/main.agc"]
CORES = ["../core/main.agc", "core/main.agc"]
SETTINGS = [
  "FINN_CONFIG",
  "FINN_MCP_CONFIG",
  "FINN_TRUSTED_DIRS",
  "FINN_CODE_MODE",
  "FINN_MONTY",
  "FINN_API",
  "FINN_BASE_URL",
  "FINN_API_KEY",
  "FINN_MODEL",
  "FINN_CONTEXT_WINDOW",
  "FINN_COMPACT_MODEL",
  "FINN_MODELS_PROVIDER",
  "FINN_DRAIN_MS",
  "FINN_VERSION",
]

OTHER_SETTINGS = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"]
FAKE_MAINS = ["tests/support/fake_main.agc", "cli/tests/support/fake_main.agc"]
SLEEPERS = ["tests/support/sleeper.agc", "cli/tests/support/sleeper.agc"]

## A process with `FINN_STATE_DIR` in its environment: a server, and the folder it serves.
struct Served
  pid: Int
  dir: String
  ## The name and start time it had when it was found: a signal goes only to that process.
  comm: String
  started: Int
end

## A fake server and the state folder that points at it.
struct Rig
  fake: Fake.Fake
  dir: String
  token: String
end

## What a client printed and how it ended.
struct Done
  lines: List[String]
  code: Int
  errors: String
end

## A fake server with `routes` and a state folder, whose `server.json` names it with `token` once published.
def rig(routes: List[Fake.Route], token: String = Fake.TOKEN, published: Bool = true) -> Result[Rig]
  fake = try Fake.start(routes)
  dir = try make_dir()
  made = Rig(fake: fake, dir: dir, token: token)
  if published
    try publish(made)
  end

  ok(made)
end

## Writes the `server.json` of the rig.
def publish(rig: Rig) -> Result[Void]
  Fake.write_private("#{rig.dir}/server.json", Fake.server_file(rig.fake, rig.token))
end

## Runs `body` on a rig, and stops the fake, every server of the state folder and the folder itself after it, whether it
## passed or not.
def within(
  routes: List[Fake.Route],
  body: Fn[Rig, Result[Void]],
  token: String = Fake.TOKEN,
  published: Bool = true,
) -> Result[Void]
  made = try rig(routes, token, published)
  result = body.call(made)
  cleaned = clean_up(made)
  try result
  cleaned
end

## Runs `body` on an empty state folder. Whether it passed or not, every server of the folder is stopped
## (`stop_servers`) and the folder is removed.
def within_dir(body: Fn[String, Result[Void]]) -> Result[Void]
  dir = try make_dir()
  result = body.call(dir)
  cleaned = removed(dir)
  try result
  cleaned
end

## Stops every server of a state folder: the processes of this user whose environment names the folder
## (`FINN_STATE_DIR`, which a client gives the server it starts). Each gets SIGTERM, and its process group SIGKILL when
## it is still there after `STOP_MS`. Linux: it reads /proc; elsewhere it stops nothing.
def stop_servers(dir: String) -> Void
  stop_all(served().select { |server| server.dir == dir })
end

## The client on `dir`, with `NO_COLOR` set to `no_color` ("" turns the colors on), run from the folder `chdir`. It runs
## the bytecode that `make` compiled once (CLI_BYTECODE) unless `compiled` is false: a client finds the core by the path of
## its source. `state_dir` false leaves out `--state-dir`, for a command that has no such option.
def start(
  dir: String,
  args: List[String],
  no_color: String = "1",
  chdir: String = ".",
  compiled: Bool = true,
  extra: Map[String, String] = {},
  state_dir: Bool = true,
) -> Result[Process]
  program = try program_words(ENTRIES, "CLI_BYTECODE", compiled)
  state: List[String] = []
  if state_dir
    state = ["--state-dir", dir]
  end

  Process.spawn_captured(
    program[0],
    program.drop(1) + state + args,
    Process.Options(env: with_extra(environment(no_color, dir), extra), chdir: chdir),
  )
end

## The environment of a client on `dir` run from source with its own bytecode cache `build`, where the client and the
## core are compiled first. A run from source with the test's home compiles again and rewrites the entry of the
## package's `_build/`, which other tests read at the same time; compiled here, the client starts its server at once.
## The package cache is the caller's, which holds the native module of `bash` that a compile of the core builds.
def own_cache(dir: String, build: String) -> Result[Map[String, String]]
  home = System.env("HOME").unwrap_or("/nonexistent")
  extra = {"AGENTICA_BUILD_DIR": build, "XDG_CACHE_HOME": System.env("XDG_CACHE_HOME").unwrap_or("#{home}/.cache")}
  env = with_extra(environment("1", dir), extra)
  for entries in [ENTRIES, CORES]
    source = try Path.resolve(try existing(entries))
    compile = try Process.spawn_captured(
      binary(),
      ["compile", source, "-o", "#{build}/warm.agcb"],
      Process.Options(env: env),
    )

    # Closed before the result is read: a compile still running at the timeout is killed, not left behind.
    waited = Process.wait(compile, COMPILE_MS)
    Process.close(compile)
    code = try waited
    return error("compiling #{source} failed with #{code}") if code != 0
  end

  ok(extra)
end

## `finn server ACTION` on `dir`; `command` is the server command it starts a server with (none: the action starts none).
def start_server(
  dir: String,
  action: List[String],
  command: List[String] = [],
  extra: Map[String, String] = {},
) -> Result[Process]
  program = try program_words(ENTRIES, "CLI_BYTECODE", true)
  tail = ["--state-dir", dir]
  if not command.empty?
    tail = tail + ["--"] + command
  end

  Process.spawn_captured(
    program[0],
    program.drop(1) + ["server"] + action + tail,
    Process.Options(env: with_extra(environment("1", dir), extra)),
  )
end

## The words that start the real server: the bytecode `make` compiled once (CORE_BYTECODE), else the source.
def core_command() -> Result[List[String]]
  words = try program_words(CORES, "CORE_BYTECODE", true)
  ok(words + ["serve"])
end

## The words that start a program that serves nothing (`sleeper.agc`), run from its source.
def sleeper_command() -> Result[List[String]] = ok([binary(), try Path.resolve(try existing(SLEEPERS))])

## The words that start the fake server program.
def fake_command() -> Result[List[String]] = program_words(FAKE_MAINS, "FAKE_BYTECODE", true)

def say(cli: Process, text: String) -> Result[Void] = Process.send(cli, "#{text}\n", READ_MS)

## The lines the client prints until one has `marker` (that line included).
def read_until(cli: Process, marker: String) -> Result[List[String]]
  lines: List[String] = []
  while true
    line = try Process.read_line(cli, READ_MS)
    lines = lines.push(line)
    return ok(lines) if line.include?(marker)
  end

  ok(lines)
end

## Closes the input of the client and waits for it to end.
def finish(cli: Process) -> Result[Done]
  _ = Process.close_stdin(cli, READ_MS)
  exited(cli)
end

## Waits for the client to end by itself, with its input open. The client is closed on every path, so one that did not
## end in time does not start a server after the test.
def exited(cli: Process) -> Result[Done]
  done = read_done(cli)
  Process.close(cli)
  done
end

## True when the request carried the token of the fake.
def authorized?(seen: Fake.Seen) -> Bool
  HTTP.header_values(seen.headers, "authorization") == ["Bearer #{Fake.TOKEN}"]
end

def header(seen: Fake.Seen, name: String) -> List[String] = HTTP.header_values(seen.headers, name)

private

# The stop of a rig comes last, so what a test read from the fake is read before it goes.
def clean_up(rig: Rig) -> Result[Void]
  stopped = Fake.stop(rig.fake)
  cleaned = removed(rig.dir)
  try stopped
  cleaned
end

def read_done(cli: Process) -> Result[Done]
  lines: List[String] = []
  while true
    case Process.read_line(cli, EXIT_MS)
      ok(line) -> lines = lines.push(line)
      error(_) -> break
    end
  end

  code = try Process.wait(cli, EXIT_MS)
  output = try Process.output(cli, EXIT_MS)
  ok(Done(lines: lines, code: code, errors: output.stderr))
end

# The source of the first of `paths` that exists, or the bytecode named by the environment variable `bytecode_env`.
def program_words(paths: List[String], bytecode_env: String, compiled: Bool) -> Result[List[String]]
  case System.env(bytecode_env)
    ok(bytecode) if compiled and bytecode != "" -> ok([binary(), "run", "--", bytecode])
    _ -> ok([binary(), try Path.resolve(try existing(paths))])
  end
end

# The settings of the host never reach a client or the real server it starts: those a test does not set are empty (the
# programs take an empty value as none), home and the XDG folders are the state folder, no model catalog is fetched and
# the data of a real server goes into it too.
def environment(no_color: String, dir: String) -> Map[String, String]
  blank = SETTINGS.flat_map { |name| [name, "AGC_AGENT_#{name.slice(5, name.length - 5)}"] }
  env: Map[String, String] = {}
  for name in blank + OTHER_SETTINGS
    env = env.put(name, "")
  end

  set = {
    "NO_COLOR": no_color,
    "FINN_SERVER_COMMAND": "",
    "FINN_MODELS_URL": "off",
    "FINN_DATA_DIR": "#{dir}/data",
    "HOME": "#{dir}/home",
    "XDG_CONFIG_HOME": "#{dir}/home/.config",
    "XDG_DATA_HOME": "#{dir}/home/.local/share",
    "XDG_STATE_HOME": "#{dir}/home/.local/state",
    "XDG_CACHE_HOME": "#{dir}/home/.cache",
  }

  for name in set.keys
    env = env.put(name, set[name])
  end

  env
end

def with_extra(env: Map[String, String], extra: Map[String, String]) -> Map[String, String]
  merged = env
  for name in extra.keys
    merged = merged.put(name, extra[name])
  end

  merged
end

def binary() -> String
  case System.env("AGENTICA")
    ok(path) if path != "" -> path
    _ -> "agentica"
  end
end

def existing(paths: List[String]) -> Result[String]
  found = paths.find { |path| File.stat(path).ok? }
  case found
    ok(path) -> ok(path)
    error(_) -> error("none of #{paths.join(", ")} exists: run the tests from the repository root or the package")
  end
end

# The folders of the tests are removed only once no server writes there any more.
def removed(dir: String) -> Result[Void] = removed_from(dir, served())

def removed_from(dir: String, servers: List[Served]) -> Result[Void]
  stop_all(servers.select { |server| server.dir == dir })
  Path.remove(dir)
end

# A folder `agc-cli-PID-N` whose test process PID is gone was left by a run that was stopped (a test that timed out
# ends its file's run with no cleanup): its servers are stopped and it is removed, before a new folder is made. The
# folder is a real path, with no symlink in it, as the `FINN_STATE_DIR` that a client gives its server is: the cleanup
# compares the two as text.
def make_dir() -> Result[String]
  base = try Path.real(System.env("TMPDIR").unwrap_or("/tmp"))
  sweep(base)
  dir = try Path.join([base, "#{FOLDER_PREFIX}#{System.pid()}-#{Random.int(0, 999_999_999)}"])
  try Dir.mkdir_private(dir)
  try Dir.mkdir("#{dir}/home")
  ok(dir)
end

def sweep(base: String) -> Void
  names: List[String] = []
  stale = Dir.list(base).unwrap_or(names).select { |name| stale?(name) }
  return if stale.empty?

  servers = served()
  for name in stale
    case Path.join([base, name])
      ok(path) -> _ = removed_from(path, servers)
      error(_) -> nil
    end
  end
end

# A folder whose pid now belongs to another process is kept: a leak, which is the safe direction.
def stale?(name: String) -> Bool
  return false if not name.start_with?(FOLDER_PREFIX)

  owner = name.slice(FOLDER_PREFIX.length, name.length - FOLDER_PREFIX.length).split("-")[0].to_i.unwrap_or(0)
  owner > 0 and not alive?(owner)
end

# The processes of this user whose environment has a `FINN_STATE_DIR`, read once from /proc (none where there is no
# /proc). Only those are ever signalled: the pid of a `server.json` alone may be gone and taken by another program.
def served() -> List[Served]
  found: List[Served] = []
  names: List[String] = []
  for name in Dir.list("/proc").unwrap_or(names)
    pid = name.to_i.unwrap_or(0)
    next if pid <= 0 or pid == System.pid()

    for dir in option_list(state_dir_of(pid))
      for started in option_list(start_time(pid))
        comm = File.read_text("/proc/#{pid}/comm").unwrap_or("").strip
        found = found.push(Served(pid: pid, dir: dir, comm: comm, started: started))
      end
    end
  end

  found
end

def state_dir_of(pid: Int) -> Optional[String]
  environ = NUL + File.read_text("/proc/#{pid}/environ").unwrap_or("") + NUL
  key = "#{NUL}FINN_STATE_DIR="
  case environ.index_of(key)
    some(start) ->
      rest = environ.slice(start + key.length, environ.length - start - key.length)
      some(rest.slice(0, rest.index_of(NUL).unwrap_or(rest.length)))
    none -> none
  end
end

# SIGTERM to each exact process, by the name it had when it was found; once they all had `STOP_MS`, SIGKILL to the
# process group of each one still there (the server leads none, but runs in the one of the shell that started it, with
# what it started), unless it is no longer the same process (its start time) or the group is this test's own.
def stop_all(servers: List[Served]) -> Void
  return if servers.empty?

  for server in servers
    if same_alive?(server)
      _ = System.signal(server.pid, System.Signal.Term, server.comm)
    end
  end

  return if all_gone_within(servers, STOP_MS)

  own = process_group(System.pid())
  for server in servers
    next if start_time(server.pid) != some(server.started)

    group = process_group(server.pid)
    if group > 0 and group != own
      _ = run_kill(["-KILL", "--", "-#{group}"])
    else
      _ = System.signal(server.pid, System.Signal.Kill, server.comm)
    end
  end

  _ = all_gone_within(servers, STOP_MS)
end

def all_gone_within(servers: List[Served], limit_ms: Int) -> Bool
  waited = 0
  while waited < limit_ms
    return true if servers.all? { |server| not same_alive?(server) }

    Task.sleep(POLL_MS)
    waited = waited + POLL_MS
  end

  servers.all? { |server| not same_alive?(server) }
end

def same_alive?(server: Served) -> Bool = alive?(server.pid) and start_time(server.pid) == some(server.started)

# A zombie has ended: only its parent's wait is left.
def alive?(pid: Int) -> Bool
  case File.read_text("/proc/#{pid}/stat")
    ok(stat) -> stat_fields(stat)[0] != "Z"
    error(_) -> false
  end
end

def process_group(pid: Int) -> Int
  case File.read_text("/proc/#{pid}/stat")
    ok(stat) -> stat_fields(stat)[2].to_i.unwrap_or(0)
    error(_) -> 0
  end
end

# When the process started, in clock ticks after boot (field 22 of /proc/PID/stat): another process that takes the pid
# has another.
def start_time(pid: Int) -> Optional[Int]
  case File.read_text("/proc/#{pid}/stat")
    ok(stat) ->
      case stat_fields(stat)[19].to_i
        ok(ticks) -> some(ticks)
        error(_) -> none
      end

    error(_) -> none
  end
end

# The fields of /proc/PID/stat after the name, which may hold spaces and parentheses: state, ppid, pgrp, ...
def stat_fields(stat: String) -> List[String]
  parts = stat.split(") ")
  parts[parts.size - 1].split(" ")
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end

def run_kill(args: List[String]) -> Result[Int]
  process = try Process.spawn("kill", args)
  code = Process.wait(process, STOP_MS)
  Process.close(process)
  code
end
