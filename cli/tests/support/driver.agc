## Runs the client as a child process on pipes, against a fake server, and reads what it prints.

import HTTP from "std/http"
import Fake from "fake_server"

READ_MS = 10_000
EXIT_MS = 15_000
COMPILE_MS = 120_000
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
]

OTHER_SETTINGS = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"]
FAKE_MAINS = ["tests/support/fake_main.agc", "cli/tests/support/fake_main.agc"]

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

## Runs `body` on a rig, and stops the fake and removes the state folder after it, whether it passed or not.
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

## Runs `body` on an empty state folder, which is removed after it, whether it passed or not.
def within_dir(body: Fn[String, Result[Void]]) -> Result[Void]
  dir = try make_dir()
  result = body.call(dir)
  cleaned = Path.remove(dir)
  try result
  cleaned
end

## The client on `dir`, with `NO_COLOR` set to `no_color` ("" turns the colors on), run from the folder `chdir`. It runs
## the bytecode that `make` compiled once (CLI_BYTECODE) unless `compiled` is false: a client finds the core by the path of
## its source.
def start(
  dir: String,
  args: List[String],
  no_color: String = "1",
  chdir: String = ".",
  compiled: Bool = true,
  extra: Map[String, String] = {},
) -> Result[Process]
  program = try program_words(ENTRIES, "CLI_BYTECODE", compiled)
  Process.spawn_captured(
    program[0],
    program.drop(1) + ["--state-dir", dir] + args,
    Process.Options(env: with_extra(environment(no_color, dir), extra), chdir: chdir),
  )
end

## The environment of a client on `dir` run from source with its own bytecode cache `build`, where the client and the
## core are compiled first. A run from source with the test's home compiles again and rewrites the entry of the
## package's `_build/`, which other tests read at the same time; compiled here, the client starts its server at once.
def own_cache(dir: String, build: String) -> Result[Map[String, String]]
  extra = {"AGENTICA_BUILD_DIR": build}
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

## Waits for the client to end by itself, with its input open.
def exited(cli: Process) -> Result[Done]
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

## True when the request carried the token of the fake.
def authorized?(seen: Fake.Seen) -> Bool
  HTTP.header_values(seen.headers, "authorization") == ["Bearer #{Fake.TOKEN}"]
end

def header(seen: Fake.Seen, name: String) -> List[String] = HTTP.header_values(seen.headers, name)

private

# The stop of a rig comes last, so what a test read from the fake is read before it goes.
def clean_up(rig: Rig) -> Result[Void]
  try Fake.stop(rig.fake)
  Path.remove(rig.dir)
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

def make_dir() -> Result[String]
  base = System.env("TMPDIR").unwrap_or("/tmp")
  dir = try Path.join([base, "agc-cli-#{System.pid()}-#{Random.int(0, 999_999_999)}"])
  try Dir.mkdir_private(dir)
  try Dir.mkdir("#{dir}/home")
  ok(dir)
end
