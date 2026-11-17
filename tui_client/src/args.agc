import OP from "std/option_parser"
import {Kind, Opt, Parsed} from "std/option_parser"
import Client from "pkg/client/client"

VERSION = "0.0.1"

## The options of a run; `none` takes the default, as in the line-mode client.
struct Options
  state_dir: Optional[String]
  server_command: Optional[List[String]]
  session: Optional[String]
  cwd: Optional[String]
  model: Optional[String]
  api: Optional[String]
  provider: Optional[String] = none
  profile: Optional[String] = none
  thinking: Bool
  ## Every approval asked during this run is allowed without asking.
  yolo: Bool = false
  ## The code mode asked for: off with `--no-codemode`, else as `FINN_CODE_MODE` says; none when neither says.
  code_mode: Optional[Bool] = none
  ## What the session says first about its server (`Client.code_mode_note`).
  server_note: String = ""
end

enum Command
  Run(Options)
  ## `finn login`: the login of the provider of the options (the picker when none), then the client ends.
  Login(Options)
  Version
  Help(String)
end

def parse(args: List[String]) -> Result[Command]
  parser = OP.new(
    "finn",
    "The terminal UI client of Finn Agent: it starts the server when none runs.",
    [],
    [
      Opt(name: "state-dir", help: "folder of server.json (default: FINN_STATE_DIR, else the user's state folder)"),
      Opt(name: "session", help: "id of the session to resume (default: a new one)"),
      Opt(name: "cwd", help: "folder of a new session (default: the current folder)"),
      Opt(name: "model", help: "model of a new session (default: the server's)"),
      Opt(name: "api", help: "model API of a new session: openai or openai_responses (default: the server's)"),
      Opt(name: "provider", help: "provider of a new session (default: the server's)"),
      Opt(name: "profile", help: "profile of a new session: the tools its model sees (default: build)"),
      Opt(name: "thinking", kind: Kind.Flag, help: "show the model's thinking from the start (Ctrl+T toggles it)"),
      Opt(
        name: "yolo",
        kind: Kind.Flag,
        help: "with approvals on, allow the tool calls of the turns sent from here (other turns are still asked)",
      ),
      Opt(
        name: "no-codemode",
        kind: Kind.Flag,
        help: "a server this client starts has no code mode (run_script); one that runs with it must be stopped first",
      ),
      Opt(
        name: "login",
        kind: Kind.Flag,
        help: (
          "set up the --provider with its key, or local with its base URL (pick one when none is given), then exit"
        ),
      ),
      Opt(name: "version", kind: Kind.Flag, help: "print the version"),
    ],
    "SERVER_COMMAND",
  )

  case OP.parse(parser, args)
    ok(parsed) -> command(parsed)
    # `finn tui` is the same program: the usage line says so, the hint of an error names the shorter form.
    error(e) if OP.help?(e.message) -> ok(Command.Help(OP.usage(parser).replace("Usage: finn ", "Usage: finn [tui] ")))
    error(e) -> error(OP.message(e.message), kind: "tui.usage")
  end
end

## How this client finds or starts its server.
def launch(options: Options) -> Client.Launch
  Client.Launch(
    main: "tui_client/main.agc",
    state_dir: options.state_dir,
    server_command: options.server_command,
    code_mode: options.code_mode != some(false),
  )
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
    provider: OP.optional_string(parsed, "provider"),
    profile: OP.optional_string(parsed, "profile"),
    thinking: OP.flag(parsed, "thinking"),
    yolo: OP.flag(parsed, "yolo"),
    code_mode: Client.code_mode_asked(OP.flag(parsed, "no-codemode")),
  )

  return ok(Command.Login(options)) if OP.flag(parsed, "login")

  ok(Command.Run(options))
end

def extra?(parsed: Parsed) -> Bool = OP.rest(parsed).size != OP.after_dashes(parsed).size
