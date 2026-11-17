## Finn's core as a package. A program of its own serves the core with extensions: it builds a `Registry` (tools,
## wrappers of every tool, prompts, event handlers and services) and gives it to `serve`, which reads the environment
## as `finn serve` does. `examples/extension` is one.
##
## ```agc
## import Core from "pkg/core/core"
##
## def main() -> Void
##   Core.serve(Core.registry() |> Core.add_prompt("Answer in English."))
## end
## ```

import Catalog from "src/agent/catalog"
import Config from "src/config/config"
import Extensions from "src/config/registry"
import McpTools from "src/ext/mcp"
import Server from "src/http/server"
import Spec from "src/tools/spec"

## How long the task of the signals waits for one before it waits again.
SIGNAL_POLL_MS = 3_600_000

export Extensions.Registry
export Extensions.Event
export Extensions.Service
export Spec.Tool
export Spec.Context

def registry() -> Extensions.Registry = Extensions.Registry()

## A tool the model may call, after the built-in ones.
def add_tool(registry: Extensions.Registry, tool: Spec.Tool) -> Extensions.Registry
  registry.with(tools: registry.tools.push(tool))
end

## Puts `wrap` around every tool, the built-in ones too; the first wrapper added is the outermost.
def wrap_tools(registry: Extensions.Registry, wrap: Fn[Spec.Tool, Spec.Tool]) -> Extensions.Registry
  registry.with(wrappers: registry.wrappers.push(wrap))
end

## Text after the system prompt of each new session.
def add_prompt(registry: Extensions.Registry, text: String) -> Extensions.Registry
  registry.with(prompts: registry.prompts.push(text))
end

## A handler of the `Message` or `Fold` event of every session.
def on(registry: Extensions.Registry, event: Extensions.Event) -> Extensions.Registry
  registry.with(events: registry.events.push(event))
end

def add_service(registry: Extensions.Registry, service: Extensions.Service) -> Extensions.Registry
  registry.with(services: registry.services.push(service))
end

## Runs the server with `registry` until a signal or `finn server stop` ends it. The services start first, in order,
## and stop after the server, in the reverse order; a failed start stops the process with status 2.
def serve(registry: Extensions.Registry) -> Void
  case start(registry)
    ok(server) ->
      puts("Finn Agent core listening on 127.0.0.1:#{server.port}")
      if not server.control.approvals
        puts("approvals are off: tools run without asking (finn serve --approvals turns them on)")
      end

      IO.flush()
      stop_on_signals(server)
      Server.shutdown(server, Server.stop_requested(server))
      stopped(registry.services)
      puts("Finn Agent core stopped")
      IO.flush()
    error(e) -> fail(e.message)
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
def start(registry: Extensions.Registry) -> Result[Server.Server]
  read = ->(name) { System.env(name) }
  options = try Config.from_env(read)
  for warning in options.warnings
    IO.warn(warning)
  end

  mcp = McpTools.background(try McpTools.servers(read, options.state_dir), ->(warning: String) { IO.warn(warning) })

  catalog = Catalog.start(
    Catalog.Options(url: options.models_url, cache: "#{options.state_dir}/#{Catalog.CACHE_FILE}"),
  )

  try started(registry.services, [])
  extended = options.with(
    tools: options.tools + registry.tools,
    registry: some(registry),
    late_tools: some(-> { McpTools.tools(mcp) }),
    catalog: some(catalog),
  )

  case Server.start(extended)
    ok(server) -> ok(server)
    error(e) ->
      stopped(registry.services)
      error(e.message)
  end
end

# Starts `services` in order; when one fails, those started before it stop.
def started(services: List[Extensions.Service], done: List[Extensions.Service]) -> Result[Void]
  for service in services
    case service.start.call()
      ok(_) -> done = done.push(service)
      error(e) ->
        stopped(done)
        return error("service #{service.name}: #{e.message}")
    end
  end

  ok()
end

def stopped(services: List[Extensions.Service]) -> Void
  for service in services.reverse
    service.stop.call()
  end
end

def fail(message: String) -> Void
  IO.warn(message)
  System.exit(2)
end
