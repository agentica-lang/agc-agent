import OP from "std/option_parser"
import {Kind, Opt, Parsed} from "std/option_parser"

VERSION = "0.0.1"

## The options of a run. `none` takes the default: the state folder from the environment, a new session in the current
## folder, the server command of `Server.DEFAULT_COMMAND`.
struct Options
  state_dir: Optional[String]
  server_command: Optional[String]
  session: Optional[String]
  cwd: Optional[String]
  model: Optional[String]
  thinking: Bool
end

enum Command
  Run(Options)
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
      Opt(name: "server-command", help: "program and arguments that start a server (default: the core's)"),
      Opt(name: "session", help: "id of the session to resume (default: a new one)"),
      Opt(name: "cwd", help: "folder of a new session (default: the current folder)"),
      Opt(name: "model", help: "model of a new session (default: the server's)"),
      Opt(name: "thinking", kind: Kind.Flag, help: "show the model's thinking, dimmed"),
      Opt(name: "version", kind: Kind.Flag, help: "print the version"),
    ],
  )

  case OP.parse(parser, args)
    ok(parsed) -> ok(command(parsed))
    error(e) if OP.help?(e.message) -> ok(Command.Help(OP.usage(parser)))
    error(e) -> error(OP.message(e.message), kind: "cli.usage")
  end
end

private

def command(parsed: Parsed) -> Command
  return Command.Version if OP.flag(parsed, "version")

  Command.Run(
    Options(
      state_dir: OP.optional_string(parsed, "state-dir"),
      server_command: OP.optional_string(parsed, "server-command"),
      session: OP.optional_string(parsed, "session"),
      cwd: OP.optional_string(parsed, "cwd"),
      model: OP.optional_string(parsed, "model"),
      thinking: OP.flag(parsed, "thinking"),
    ),
  )
end
