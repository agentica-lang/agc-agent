import OP from "std/option_parser"
import Client from "pkg/client/client"
import {Kind, Opt, Parsed} from "std/option_parser"

VERSION = "0.0.1"
# The options of a client that take the next word.
VALUE_OPTIONS = [
  "--state-dir", "--server-command", "--session", "--cwd", "--model", "--api", "--provider", "--prompt", "-p",
  "--delete", "--logout",
]

## The options of a run. `none` takes the default: the state folder from the environment, a new session in the current
## folder, the server command of `FINN_SERVER_COMMAND`. The server command is the words after `--`, or the
## `--server-command` text split on spaces (no quotes).
struct Options
  state_dir: Optional[String]
  server_command: Optional[List[String]]
  session: Optional[String]
  cwd: Optional[String]
  model: Optional[String]
  api: Optional[String] = none
  provider: Optional[String] = none
  thinking: Bool
  ## One-shot: the task to send; the client prints the turn and exits with its status.
  prompt: Optional[String] = none
  ## Every approval is allowed without asking.
  yolo: Bool = false
end

## What `finn server` does.
enum Action
  Status
  Start
  ## Waits for the running turns to end; `now` cancels them.
  Stop
  Restart
  Logs
end

## The options of `finn server`: the state folder and the server command as in `Options`, `now` for a stop, and `follow`
## for the logs.
struct ServerOptions
  action: Action
  state_dir: Optional[String]
  server_command: Optional[List[String]]
  now: Bool = false
  follow: Bool = false
end

enum Command
  Run(Options)
  Server(ServerOptions)
  ## Deletes the session of that id, on the server of the options.
  Delete(Options, String)
  ## Removes the stored key of that provider, or every one when none, on the server of the options.
  Logout(Options, Optional[String])
  Version
  Help(String)
end

def parse(args: List[String]) -> Result[Command]
  at = server_word(args)
  return parse_server(args.take(at) + args.drop(at + 1)) if at >= 0

  parser = OP.new(
    "finn chat",
    "The line-mode client of Finn Agent: it starts the server when none runs, and leaves it running. With -p it " +
    "runs one task: the answer on stdout, the rest on stderr, approvals (when on) denied unless --yolo; exit 0 " +
    "when the turn ends normally (even after a denied call), 130 when it is cancelled, 1 otherwise.",
    [],
    [
      Opt(name: "state-dir", help: "folder of server.json (default: FINN_STATE_DIR, else the user's state folder)"),
      Opt(
        name: "server-command",
        help: "program and arguments that start a server, split on spaces (or put them after --)",
      ),
      Opt(name: "session", help: "id of the session to resume (default: a new one)"),
      Opt(name: "cwd", help: "folder of a new session (default: the current folder)"),
      Opt(name: "model", help: "model of a new session (default: the server's)"),
      Opt(name: "api", help: "model API of a new session: openai or openai_responses (default: the server's)"),
      Opt(name: "provider", help: "provider of a new session (default: the server's)"),
      Opt(name: "thinking", kind: Kind.Flag, help: "show the model's thinking, dimmed"),
      Opt(
        name: "prompt",
        short: "p",
        help: "run this one task (- reads it from stdin) and exit: 0 end_turn, 130 cancelled, 1 otherwise",
      ),
      Opt(
        name: "yolo",
        kind: Kind.Flag,
        help: "with approvals on (FINN_APPROVALS=1), allow the tool calls of the turns this client starts (also -p)",
      ),
      Opt(name: "delete", help: "id of a session to delete (with its file), then exit"),
      Opt(name: "logout", help: "remove the stored key of this provider (all: every stored key), then exit"),
      Opt(name: "version", kind: Kind.Flag, help: "print the version"),
    ],
    "SERVER_COMMAND",
  )

  case OP.parse(parser, args)
    ok(parsed) -> command(parsed)
    error(e) if OP.help?(e.message) -> ok(Command.Help(OP.usage(parser)))
    error(e) -> error(OP.message(e.message), kind: "cli.usage")
  end
end

## `finn server ACTION [options]`: status, start, stop, restart or logs of the server of the state folder.
def parse_server(args: List[String]) -> Result[Command]
  parser = OP.new(
    "finn server",
    "Manages the server of the state folder. Actions: status (exit 1 when none runs), start, stop (waits for the " +
    "running turns; --now cancels them), restart, logs (the end of the log; -f follows it).",
    [],
    [
      Opt(name: "state-dir", help: "folder of server.json (default: FINN_STATE_DIR, else the user's state folder)"),
      Opt(
        name: "server-command",
        help: "program and arguments that start a server, split on spaces (or put them after --)",
      ),
      Opt(name: "now", kind: Kind.Flag, help: "stop and restart: cancel the running turns instead of waiting"),
      Opt(name: "follow", short: "f", kind: Kind.Flag, help: "logs: keep reading the log as it grows"),
    ],
    "ACTION",
  )

  case OP.parse(parser, args)
    ok(parsed) -> server_command_of(parsed)
    error(e) if OP.help?(e.message) -> ok(Command.Help(OP.usage(parser)))
    error(e) -> error(OP.message(e.message), kind: "cli.usage")
  end
end

## How this client finds or starts its server.
def launch(options: Options) -> Client.Launch
  Client.Launch(main: "cli/main.agc", state_dir: options.state_dir, server_command: options.server_command)
end

private

# Where the word `server` is, the first that is not an option or the value of one (so `finn --state-dir X server stop`
# works); -1 when there is none.
def server_word(args: List[String]) -> Int
  at = 0
  while at < args.size
    word = args[at]
    return -1 if word == "--"
    return at if word == "server"
    return -1 if not word.start_with?("-")

    takes_value = VALUE_OPTIONS.include?(word)
    at = at + 1
    if takes_value
      at = at + 1
    end
  end

  -1
end

def command(parsed: Parsed) -> Result[Command]
  return ok(Command.Version) if OP.flag(parsed, "version")

  server_command = try server_command(parsed)
  options = Options(
    state_dir: OP.optional_string(parsed, "state-dir"),
    server_command: server_command,
    session: OP.optional_string(parsed, "session"),
    cwd: OP.optional_string(parsed, "cwd"),
    model: OP.optional_string(parsed, "model"),
    api: OP.optional_string(parsed, "api"),
    provider: OP.optional_string(parsed, "provider"),
    thinking: OP.flag(parsed, "thinking"),
    prompt: OP.optional_string(parsed, "prompt"),
    yolo: OP.flag(parsed, "yolo"),
  )

  for id in option_list(OP.optional_string(parsed, "delete"))
    return ok(Command.Delete(options, id))
  end

  for name in option_list(OP.optional_string(parsed, "logout"))
    return ok(Command.Logout(options, logout_of(name)))
  end

  ok(Command.Run(options))
end

def logout_of(name: String) -> Optional[String]
  return none if name == "all"

  some(name)
end

def server_command_of(parsed: Parsed) -> Result[Command]
  after = OP.after_dashes(parsed)
  words = OP.rest(parsed).take(OP.rest(parsed).size - after.size)
  return error("give one action: status, start, stop, restart or logs", kind: "cli.usage") if words.size != 1

  action = try action_named(words[0])
  text = OP.optional_string(parsed, "server-command")
  if text.some? and not after.empty?
    return error("give the server command with --server-command or after --, not both", kind: "cli.usage")
  end

  command = case text
    some(line) -> some(line.split(" ").select { |word| word != "" })
    none if after.empty? -> none
    none -> some(after)
  end

  ok(
    Command.Server(
      ServerOptions(
        action: action,
        state_dir: OP.optional_string(parsed, "state-dir"),
        server_command: command,
        now: OP.flag(parsed, "now"),
        follow: OP.flag(parsed, "follow"),
      ),
    ),
  )
end

def action_named(name: String) -> Result[Action]
  case name
    "status" -> ok(Action.Status)
    "start" -> ok(Action.Start)
    "stop" -> ok(Action.Stop)
    "restart" -> ok(Action.Restart)
    "logs" -> ok(Action.Logs)
    _ -> error("unknown action #{name}: status, start, stop, restart or logs", kind: "cli.usage")
  end
end

def server_command(parsed: Parsed) -> Result[Optional[List[String]]]
  after = OP.after_dashes(parsed)
  if OP.rest(parsed).size != after.size
    return error("unexpected argument: the server command goes after --", kind: "cli.usage")
  end

  text = OP.optional_string(parsed, "server-command")
  return ok(some(after)) if text.none? and not after.empty?
  return ok(none) if text.none?
  if not after.empty?
    return error("give the server command with --server-command or after --, not both", kind: "cli.usage")
  end

  ok(some(text.unwrap!.split(" ").select { |word| word != "" }))
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
