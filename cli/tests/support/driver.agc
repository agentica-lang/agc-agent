## Runs the client as a child process on pipes, against a fake server, and reads what it prints.

import HTTP from "std/http"
import Fake from "fake_server"

READ_MS = 10_000
EXIT_MS = 15_000
ENTRIES = ["main.agc", "cli/main.agc"]
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

## The client on `dir`, with `NO_COLOR` set to `no_color` ("" turns the colors on).
def start(dir: String, args: List[String], no_color: String = "1") -> Result[Process]
  entry = try existing(ENTRIES)
  Process.spawn_captured(
    binary(),
    [entry, "--state-dir", dir] + args,
    Process.Options(env: {"NO_COLOR": no_color, "AGC_AGENT_SERVER_COMMAND": ""}),
  )
end

## The words that start the fake server program.
def fake_command() -> Result[List[String]]
  main = try existing(FAKE_MAINS)
  ok([binary(), main])
end

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
  ok(dir)
end
