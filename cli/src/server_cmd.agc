## `finn server`: status, start, stop, restart and logs of the server of the state folder.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import Args from "args"

LOG_LINES = 100
FOLLOW_MS = 200
## Exit code of `status` when no server runs.
NOT_RUNNING = 1

## Does what `options` ask: the exit code.
def run(options: Args.ServerOptions) -> Result[Int]
  launch = Client.Launch(main: "cli/main.agc", state_dir: options.state_dir, server_command: options.server_command)
  dir = try Client.state_dir(launch)
  case options.action
    Args.Action.Status -> status(dir)
    Args.Action.Start -> started(launch, dir)
    Args.Action.Stop -> stopped(dir, options.now)
    Args.Action.Restart -> restarted(launch, dir, options.now)
    Args.Action.Logs -> logs(dir, options.follow)
  end
end

## `status`: the lines of `render`, from the server's answer.
def render(status: Protocol.ServerStatus, url: String, dir: String, now_s: Int) -> List[String]
  [
    "server running",
    "  address #{url}",
    "  pid #{status.pid}",
    "  version #{status.version}",
    "  uptime #{uptime(now_s - status.started_s)}",
    "  sessions #{status.sessions}",
    "  running turns #{status.running_turns}",
    "  state folder #{dir}",
  ]
end

def uptime(seconds: Int) -> String
  return "#{seconds} s" if seconds < 60
  return "#{seconds / 60} min #{seconds % 60} s" if seconds < 3600
  return "#{seconds / 3600} h #{seconds % 3600 / 60} min" if seconds < 86_400

  "#{seconds / 86_400} d #{seconds % 86_400 / 3600} h"
end

private

def status(dir: String) -> Result[Int]
  case try Client.find(dir)
    Client.Found.Running(server) -> shown(server, dir)
    Client.Found.Other(pid) ->
      puts("a server of another version of Finn Agent runs (pid #{pid}): `finn server restart` replaces it")
      ok(0)
    Client.Found.Absent(reason) ->
      puts("no server runs (#{reason})")
      ok(NOT_RUNNING)
  end
end

def shown(server: Client.Server, dir: String) -> Result[Int]
  info = try Client.server_status(server)
  for line in render(info, server.url, dir, Time.now_ms / 1000)
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

# The end of the server log; with `follow`, what is added to it, until the command is stopped.
def logs(dir: String, follow: Bool) -> Result[Int]
  path = Client.log_file(dir)
  text = case File.read_text(path)
    ok(read) -> read
    error(_) -> ""
  end

  lines = text.split("\n")
  tail = lines.drop([lines.size - LOG_LINES, 0].max.unwrap!)
  puts(tail.join("\n").strip)
  return ok(0) if not follow

  IO.flush()
  follow_log(path, text.length)
end

def follow_log(path: String, shown: Int) -> Result[Int]
  while true
    Task.sleep(FOLLOW_MS)
    text = File.read_text(path).unwrap_or("")
    if text.length < shown
      shown = 0
    end

    if text.length > shown
      puts(text.slice(shown, text.length - shown).strip)
      IO.flush()
      shown = text.length
    end
  end

  ok(0)
end
