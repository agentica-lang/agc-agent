import HTTP from "std/http"
import Cli from "src/cli"
import Config from "src/config"
import Server from "src/server"

def main() -> Void
  case Cli.parse(System.args())
    ok(Cli.Command.Serve) -> serve()
    ok(command) -> puts(Cli.output(command))
    error(e) -> fail(e.message, Cli.USAGE)
  end
end

def serve() -> Void
  case start()
    ok(server) ->
      puts("Finn Agent core listening on 127.0.0.1:#{server.port}")
      IO.flush()
      _ = HTTP.wait(server.http)
    error(e) -> fail(e.message, "")
  end
end

def start() -> Result[Server.Server] = Server.start(try Config.from_env(->(name) { System.env(name) }))

def fail(message: String, usage: String) -> Void
  IO.warn(message)
  if not usage.empty?
    IO.warn(usage)
  end

  System.exit(2)
end
