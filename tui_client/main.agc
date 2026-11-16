import Client from "pkg/client/client"
import TUI from "pkg/tui/tui"
import App from "src/app"
import Args from "src/args"

RESTORE_MS = 150

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
    Args.Command.Login(options) -> finish(login(options))
  end
end

def run(options: Args.Options) -> Result[Int]
  launch = Args.launch(options)
  server = try Client.connect(launch, try Client.state_dir(launch))
  TUI.Raw.open(->(screen) { App.run(screen, server, options) })
end

def login(options: Args.Options) -> Result[Int]
  launch = Args.launch(options)
  server = try Client.connect(launch, try Client.state_dir(launch))
  TUI.Raw.open(->(screen) { App.login(screen, server, options) })
end

def finish(result: Result[Int]) -> Void
  case result
    ok(code) ->
      IO.flush()
      System.exit(code)
    error(e) ->
      # The screen closes once the key reader's wait ends (at most 50 ms): an error written before is wiped.
      Task.sleep(RESTORE_MS)
      IO.warn("finn tui: #{e.message}")
      System.exit(1)
  end
end
