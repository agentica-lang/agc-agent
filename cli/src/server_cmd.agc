## `finn server`: status, start, stop, restart and logs of the server of the state folder.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import Args from "args"

LOG_LINES = 100
FOLLOW_MS = 200
CHECK_EVERY = 10
READ_BYTES = 65_536
REPLACEMENT = String.from_code(65533)
## Exit code of `status` when no server runs.
NOT_RUNNING = 1

## Does what `options` ask: the exit code.
def run(options: Args.ServerOptions) -> Result[Int]
  launch = Client.Launch(
    main: "cli/main.agc",
    state_dir: options.state_dir,
    server_command: options.server_command,
    code_mode: options.code_mode != some(false),
  )

  dir = try Client.state_dir(launch)
  case options.action
    Args.Action.Status -> status(dir)
    Args.Action.Start -> started(launch, dir)
    Args.Action.Stop -> stopped(dir, options.now)
    Args.Action.Restart -> restarted(launch, dir, options.now)
    Args.Action.Logs -> logs(dir, options.follow)
  end
end

## `status`: the lines of `render`, from the server's answer; its version is compared with `client`, this client's.
def render(status: Protocol.ServerStatus, url: String, dir: String, now_s: Int, client: String) -> List[String]
  restart = Client.server_command(dir, "restart")
  (
    [
      "server running",
      "  address #{url}",
      "  pid #{status.pid}",
      "  version #{Client.shown_version(status.version)}#{Client.version_suffix(client, status.version, restart)}",
      "  uptime #{uptime(now_s - status.started_s)}",
      "  sessions #{status.sessions}",
      "  running turns #{status.running_turns}",
      "  stopping #{stopping_word(status.stopping)}",
      "  state folder #{dir}",
    ] +
    status.approvals.map { |on| ["  approvals #{approvals_word(on)}"] }.unwrap_or([]) +
    status.code_mode.map { |on| ["  code mode #{code_mode_word(on, status.no_worker == some(true))}"] }.unwrap_or([])
  )
end

def code_mode_word(on: Bool, no_worker: Bool) -> String
  return "on" if on
  return "off (no Monty worker for this system)" if no_worker

  "off"
end

def approvals_word(on: Bool) -> String
  return "on" if on

  "off (tools run without asking)"
end

def stopping_word(stopping: Bool) -> String
  return "yes (waiting for the running turns)" if stopping

  "no"
end

def uptime(seconds: Int) -> String
  return "#{seconds} s" if seconds < 60
  return "#{seconds / 60} min #{seconds % 60} s" if seconds < 3600
  return "#{seconds / 3600} h #{seconds % 3600 / 60} min" if seconds < 86_400

  "#{seconds / 86_400} d #{seconds % 86_400 / 3600} h"
end

private

struct Chunk
  text: String
  pending: Bytes
end

## The last lines of a file, and the start of the line the file ends in.
struct Tail
  lines: List[String]
  rest: String
end

def status(dir: String) -> Result[Int]
  case try Client.find(dir)
    Client.Found.Running(server) -> shown(server, dir)
    Client.Found.Other(pid, version) ->
      puts(Client.other_version_text(dir, pid, version))
      ok(0)
    Client.Found.Absent(reason) ->
      puts("no server runs (#{reason})")
      ok(NOT_RUNNING)
  end
end

def shown(server: Client.Server, dir: String) -> Result[Int]
  info = try Client.server_status(server)
  for line in render(info, server.url, dir, Time.now_ms / 1000, Client.finn_version())
    puts(line)
  end

  ok(0)
end

def started(launch: Client.Launch, dir: String) -> Result[Int]
  server = try Client.connect(launch, dir)
  info = try Client.server_status(server)
  puts("server running at #{server.url} (pid #{info.pid})")
  ok(0)
end

def stopped(dir: String, now: Bool) -> Result[Int]
  if try Client.stop_and_wait(dir, now)
    puts("server stopped")
  else
    puts("no server runs")
  end

  ok(0)
end

def restarted(launch: Client.Launch, dir: String, now: Bool) -> Result[Int]
  server = try Client.restart(launch, dir, now)
  info = try Client.server_status(server)
  puts("server restarted at #{server.url} (pid #{info.pid})")
  ok(0)
end

# The end of the server log, read once from its start in pieces (the file may be big); with `follow`, what is added to
# it, until the server is gone or the command is stopped.
def logs(dir: String, follow: Bool) -> Result[Int]
  path = Client.log_file(dir)
  if not File.stat(path).ok?
    return error("no server log: #{path} does not exist (no server was started in this folder)")
  end

  File.open(path) do |file|
    seen = try read_tail(file)
    puts(seen.lines.join("\n"))
    IO.flush()
    if follow
      try follow_log(file, dir, seen.rest)
    end

    ok(0)
  end
end

# Reads to the end of the file: the last `LOG_LINES` whole lines, and the part after the last line end.
def read_tail(file: File.Handle) -> Result[Tail]
  lines: List[String] = []
  rest = ""
  pending = "".bytes
  while true
    piece = try File.read_bytes(file, READ_BYTES)
    break if piece.size == 0

    chunk = decode_chunk(Bytes.concat([pending, piece]), false)
    pending = chunk.pending
    parts = (rest + chunk.text).split("\n")
    rest = parts[parts.size - 1]
    lines = lines + parts.take(parts.size - 1)
    lines = lines.drop([lines.size - LOG_LINES, 0].max.unwrap!)
  end

  parts = (rest + decode_chunk(pending, true).text).split("\n")
  lines = lines + parts.take(parts.size - 1)
  ok(Tail(lines: lines.drop([lines.size - LOG_LINES, 0].max.unwrap!), rest: parts[parts.size - 1]))
end

# Prints what the file gets, by the position of the handle; every `CHECK_EVERY` idle polls it asks whether the
# server runs.
def follow_log(file: File.Handle, dir: String, start: String) -> Result[Void]
  rest = start
  pending = "".bytes
  idle = 0
  while true
    piece = try File.read_bytes(file, READ_BYTES)
    if piece.size == 0
      idle = idle + 1
      return ok() if idle % CHECK_EVERY == 0 and not running?(dir)

      Task.sleep(FOLLOW_MS)
    else
      idle = 0
      chunk = decode_chunk(Bytes.concat([pending, piece]), false)
      pending = chunk.pending
      parts = (rest + chunk.text).split("\n")
      rest = parts[parts.size - 1]
      for line in parts.take(parts.size - 1)
        puts(line)
      end

      IO.flush()
    end
  end

  ok()
end

# The text of `bytes` with U+FFFD for each byte that is not UTF-8. Unless `final`, the end that may be the start of a
# character (at most 3 bytes) stays in `pending` for the next piece.
def decode_chunk(bytes: Bytes, final: Bool) -> Chunk
  text = ""
  rest = bytes
  while rest.size > 0
    case rest.decode("utf-8")
      ok(done) ->
        text = text + done
        rest = Bytes.slice(rest, 0, 0)
      error(e) ->
        parts = e.message.split(" ")
        at = parts[parts.size - 1].to_i.unwrap_or(0)
        text = text + Bytes.slice(rest, 0, at).decode("utf-8").unwrap_or("")
        return Chunk(text: text, pending: Bytes.slice(rest, at, rest.size - at)) if not final and at >= rest.size - 3

        text = text + REPLACEMENT
        rest = Bytes.slice(rest, at + 1, rest.size - at - 1)
    end
  end

  Chunk(text: text, pending: rest)
end

def running?(dir: String) -> Bool
  case Client.find(dir)
    ok(Client.Found.Absent(_)) -> false
    ok(_) -> true
    error(_) -> false
  end
end
