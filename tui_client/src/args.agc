import OP from "std/option_parser"
import {Kind, Opt, Parsed} from "std/option_parser"

VERSION = "0.0.1"

## The options of a run; `none` takes the default, as in the line-mode client.
struct Options
  state_dir: Optional[String]
  server_command: Optional[List[String]]
  session: Optional[String]
  cwd: Optional[String]
  model: Optional[String]
  api: Optional[String]
end

enum Command
  Run(Options)
  Version
  Help(String)
end

def parse(args: List[String]) -> Result[Command]
  parser = OP.new(
    "finn tui",
    "The terminal UI client of Finn Agent: it starts the server when none runs.",
    [],
    [
      Opt(name: "state-dir", help: "folder of server.json (default: FINN_STATE_DIR, else the user's state folder)"),
      Opt(name: "session", help: "id of the session to resume (default: a new one)"),
      Opt(name: "cwd", help: "folder of a new session (default: the current folder)"),
      Opt(name: "model", help: "model of a new session (default: the server's)"),
      Opt(name: "api", help: "model API of a new session: openai or openai_responses (default: the server's)"),
      Opt(name: "version", kind: Kind.Flag, help: "print the version"),
    ],
    "SERVER_COMMAND",
  )

  case OP.parse(parser, args)
    ok(parsed) -> command(parsed)
    error(e) if OP.help?(e.message) -> ok(Command.Help(OP.usage(parser)))
    error(e) -> error(OP.message(e.message), kind: "tui.usage")
  end
end

private

def command(parsed: Parsed) -> Result[Command]
  return ok(Command.Version) if OP.flag(parsed, "version")
  return error("unexpected argument: the server command goes after --", kind: "tui.usage") if extra?(parsed)

  after = OP.after_dashes(parsed)
  server_command: Optional[List[String]] = none
  if not after.empty?
    server_command = some(after)
  end

  options = Options(
    state_dir: OP.optional_string(parsed, "state-dir"),
    server_command: server_command,
    session: OP.optional_string(parsed, "session"),
    cwd: OP.optional_string(parsed, "cwd"),
    model: OP.optional_string(parsed, "model"),
    api: OP.optional_string(parsed, "api"),
  )

  ok(Command.Run(options))
end

def extra?(parsed: Parsed) -> Bool = OP.rest(parsed).size != OP.after_dashes(parsed).size
