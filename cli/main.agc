import Client from "pkg/client/client"
import App from "src/app"
import Args from "src/args"
import Docs from "src/docs"
import ServerCmd from "src/server_cmd"

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
    Args.Command.Version -> puts("Finn Agent cli #{Client.finn_version()}")
    Args.Command.Help(text) -> puts(text)
    Args.Command.Run(options) -> finish(App.run(options))
    Args.Command.Server(options) -> finish(ServerCmd.run(options))
    Args.Command.Delete(options, id) -> finish(App.delete(options, id))
    Args.Command.Export(options, id, path, force) -> finish(App.export_session(options, id, path, force))
    Args.Command.Logout(options, name) -> finish(App.logout(options, name))
    Args.Command.Docs(page) -> finish(Docs.run(page))
  end
end

def finish(result: Result[Int]) -> Void
  case result
    ok(code) ->
      IO.flush()
      System.exit(code)
    error(e) ->
      IO.warn("finn: #{e.message}")
      System.exit(1)
  end
end
