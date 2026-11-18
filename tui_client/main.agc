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
    Args.Command.Version -> puts("Finn Agent tui #{Client.finn_version()}")
    Args.Command.Help(text) -> puts(text)
    Args.Command.Run(options) -> finish(run(options))
    Args.Command.Login(options) -> finish(login(options))
  end
end

def run(options: Args.Options) -> Result[App.Ended]
  launch = Args.launch(options)
  dir = try Client.state_dir(launch)
  server = try Client.connect(launch, dir)
  notes = [Client.code_mode_note(server, options.code_mode), Client.version_note(server, dir)]
  noted = options.with(server_notes: notes.select { |note| not note.empty? })
  TUI.Raw.open(->(screen) { App.run(screen, Client.http_backend(server), noted) })
end

def login(options: Args.Options) -> Result[App.Ended]
  launch = Args.launch(options)
  server = try Client.connect(launch, try Client.state_dir(launch))
  TUI.Raw.open(->(screen) { App.login(screen, Client.http_backend(server), options) })
end

def finish(result: Result[App.Ended]) -> Void
  case result
    ok(ended) ->
      case ended.hint
        some(hint) ->
          # Written once the screen is closed, as an error below.
          Task.sleep(RESTORE_MS)
          puts(hint)
        none -> nil
      end

      IO.flush()
      System.exit(ended.code)
    error(e) ->
      # The screen closes once the key reader's wait ends (at most 50 ms): an error written before is wiped.
      Task.sleep(RESTORE_MS)
      IO.warn("finn: #{e.message}")
      System.exit(1)
  end
end
