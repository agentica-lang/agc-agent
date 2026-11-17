import Catalog from "src/agent/catalog"
import Cli from "src/config/cli"
import Config from "src/config/config"
import McpTools from "src/ext/mcp"
import Server from "src/http/server"

## How long the task of the signals waits for one before it waits again.
SIGNAL_POLL_MS = 3_600_000

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
      if not server.control.approvals
        puts("approvals are off: tools run without asking (finn serve --approvals turns them on)")
      end

      IO.flush()
      stop_on_signals(server)
      Server.shutdown(server, Server.stop_requested(server))
      puts("Finn Agent core stopped")
      IO.flush()
    error(e) -> fail(e.message, "")
  end
end

# A signal that ends a container (SIGTERM, or Ctrl-C) stops the server as `finn server stop --now` does; each one asks
# again, so a second signal cancels the turns of a stop that waits for them.
def stop_on_signals(server: Server.Server) -> Void
  case System.subscribe([System.Signal.Term, System.Signal.Int])
    ok(signals) ->
      _ = Task.spawn(
        -> {
          while true
            case signals.recv(SIGNAL_POLL_MS)
              ok(_) -> Server.request_stop(server, true)
              error(_) -> nil
            end
          end
        },
      )
    error(e) -> IO.warn("no signal handling: #{e.message}")
  end
end

# The MCP servers run as long as the server: the end of the process stops them.
def start() -> Result[Server.Server]
  read = ->(name) { System.env(name) }
  options = try Config.from_env(read)
  for warning in options.warnings
    IO.warn(warning)
  end

  mcp = McpTools.background(try McpTools.servers(read, options.state_dir), ->(warning: String) { IO.warn(warning) })

  catalog = Catalog.start(
    Catalog.Options(url: options.models_url, cache: "#{options.state_dir}/#{Catalog.CACHE_FILE}"),
  )

  Server.start(options.with(late_tools: some(-> { McpTools.tools(mcp) }), catalog: some(catalog)))
end

def fail(message: String, usage: String) -> Void
  IO.warn(message)
  if not usage.empty?
    IO.warn(usage)
  end

  System.exit(2)
end
