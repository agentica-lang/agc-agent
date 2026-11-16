import OP from "std/option_parser"
import {Kind, Opt, Parsed} from "std/option_parser"

VERSION = "0.0.1"

## The options of a run. `none` takes the default: the state folder from the environment, a new session in the current
## folder, the server command of `AGC_AGENT_SERVER_COMMAND`. The server command is the words after `--`, or the
## `--server-command` text split on spaces (no quotes).
struct Options
  state_dir: Optional[String]
  server_command: Optional[List[String]]
  session: Optional[String]
  cwd: Optional[String]
  model: Optional[String]
  thinking: Bool
end

enum Command
  Run(Options)
  ## Deletes the session of that id, on the server of the options.
  Delete(Options, String)
  Version
  Help(String)
end

def parse(args: List[String]) -> Result[Command]
  parser = OP.new(
    "agc",
    "The line-mode client of agc-agent: it starts the server when none runs.",
    [],
    [
      Opt(
        name: "state-dir",
        help: "folder of server.json (default: AGC_AGENT_STATE_DIR, else the user's state folder)",
      ),
      Opt(
        name: "server-command",
        help: "program and arguments that start a server, split on spaces (or put them after --)",
      ),
      Opt(name: "session", help: "id of the session to resume (default: a new one)"),
      Opt(name: "cwd", help: "folder of a new session (default: the current folder)"),
      Opt(name: "model", help: "model of a new session (default: the server's)"),
      Opt(name: "thinking", kind: Kind.Flag, help: "show the model's thinking, dimmed"),
      Opt(name: "delete", help: "id of a session to delete (with its file), then exit"),
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

private

def command(parsed: Parsed) -> Result[Command]
  return ok(Command.Version) if OP.flag(parsed, "version")

  server_command = try server_command(parsed)
  options = Options(
    state_dir: OP.optional_string(parsed, "state-dir"),
    server_command: server_command,
    session: OP.optional_string(parsed, "session"),
    cwd: OP.optional_string(parsed, "cwd"),
    model: OP.optional_string(parsed, "model"),
    thinking: OP.flag(parsed, "thinking"),
  )

  for id in option_list(OP.optional_string(parsed, "delete"))
    return ok(Command.Delete(options, id))
  end

  ok(Command.Run(options))
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
