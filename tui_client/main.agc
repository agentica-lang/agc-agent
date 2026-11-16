import TUI from "pkg/tui/tui"
import App from "src/app"
import Args from "src/args"
import Server from "src/server"

def main() -> Void
  case Args.parse(System.args())
    ok(command) -> dispatch(command)
    error(e) ->
      IO.warn(e.message)
      System.exit(2)
  end
end

private

def dispatch(command: Args.Command) -> Void
  case command
    Args.Command.Version -> puts("Finn Agent tui #{Args.VERSION}")
    Args.Command.Help(text) -> puts(text)
    Args.Command.Run(options) -> finish(run(options))
  end
end

def run(options: Args.Options) -> Result[Int]
  server = try Server.connect(options, try Server.state_dir(options))
  TUI.open(->(screen) { App.run(screen, server, options) })
end

def finish(result: Result[Int]) -> Void
  case result
    ok(code) ->
      IO.flush()
      System.exit(code)
    error(e) ->
      IO.warn("finn tui: #{e.message}")
      System.exit(1)
  end
end
