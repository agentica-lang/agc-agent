import HTTP from "std/http"
import Catalog from "src/catalog"
import Cli from "src/cli"
import Config from "src/config"
import McpTools from "src/mcp_tools"
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

# The MCP servers run as long as the server: the end of the process stops them.
def start() -> Result[Server.Server]
  read = ->(name) { System.env(name) }
  options = try Config.from_env(read)
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
