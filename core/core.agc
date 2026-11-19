## Finn's core as a package. A program of its own serves the core with extensions: it builds a `Registry` (tools,
## wrappers of the runs of every tool, prompts, event handlers and services) and gives it to `serve`, which reads the
## environment as `finn serve` does. `examples/extension` is one.
##
## ```agc
## import Core from "pkg/core/core"
##
## def main() -> Void
##   Core.serve(Core.registry() |> Core.add_prompt("Answer in English."))
## end
## ```
##
## The code of an extension runs in a task of its own, with a time limit: a crash or a hang fails that tool call, refuses
## that message or adds nothing to that fold, and never stops a session or the server.

import Catalog from "src/providers/catalog"
import Protocol from "pkg/protocol/protocol"
import Config from "src/config/config"
import Extensions from "src/config/registry"
import Server from "src/http/server"
import Builtins from "src/session/builtins"
import Tools from "src/tools/tools"
import Log from "src/log"
import Logger from "std/logger"

## The version of the core package, informational (no tag follows it). A server runs the version of Finn, the time of
## its commit (`/v1/health`).
VERSION = "0.0.1"

export Extensions.Registry
export Extensions.Call
export Extensions.Tool
export Extensions.Event
export Extensions.Seen
export Extensions.Pending
export Extensions.Check
export Extensions.Service

def registry() -> Extensions.Registry = Extensions.Registry()

## Replaces the full screen's status layout with the ordered components on each side.
def set_statusline(registry: Extensions.Registry, left: List[String], right: List[String]) -> Extensions.Registry
  registry.with(statusline: some(Protocol.StatusLine(left: left, right: right)))
end

## A tool the model may call, after the built-in ones. Its name must not be one of theirs, `apply_patch`, `run_script`,
## `activate_skill`, another extension tool's, or start with `mcp__`: `serve` refuses it.
def add_tool(registry: Extensions.Registry, tool: Extensions.Tool) -> Extensions.Registry
  registry.with(tools: registry.tools.push(tool))
end

## Puts `wrapper` around the run of every tool but `activate_skill` and `run_script` (the calls a script makes are
## wrapped): it gets the tool's name, the call and the next run, and gives the output. The first wrapper added is the
## outermost. The approval decides before any wrapper runs, on the tool as it is, and the next run takes no input: it
## runs on the input the approval saw. A wrapper runs on every call: keep it free of state of its own.
def wrap_tools(registry: Extensions.Registry, wrapper: Extensions.Wrapper) -> Extensions.Registry
  registry.with(wrappers: registry.wrappers.push(wrapper))
end

## Text after the system prompt of each new session.
def add_prompt(registry: Extensions.Registry, text: String) -> Extensions.Registry
  registry.with(prompts: registry.prompts.push(text))
end

## A handler of the `Message` or `Fold` event of every session (`Event`).
def on(registry: Extensions.Registry, event: Extensions.Event) -> Extensions.Registry
  registry.with(events: registry.events.push(event))
end

## A service that runs while the server holds its lock: started in order before it listens, stopped in the reverse
## order after it stops listening. Its `start` and `stop` run in one task of its own, so what `start` opens stays open
## until `stop`; a start that fails, crashes or takes over `service_ms` (30 s) stops the server's start.
def add_service(registry: Extensions.Registry, service: Extensions.Service) -> Extensions.Registry
  registry.with(services: registry.services.push(service))
end

## `path` of a call resolved inside the session folder, through its links; an error outside it, or for a file a deny
## rule of `read_file` hides.
def resolve(call: Extensions.Call, path: String) -> Result[String] = call.resolve.call(path)

## A call of a tool in the folder `root`, for the tests of an extension: its paths resolve in `root`, with no deny rule.
def call(root: String, input: JSON.Value) -> Extensions.Call = Extensions.call(root, input)

## Runs the server with `registry` until a signal or `finn server stop` ends it; a failed start, or an extension tool
## whose name is taken, stops the process with status 2.
def serve(registry: Extensions.Registry) -> Void
  Log.install()
  case start(registry)
    ok(server) ->
      Logger.info("#{Log.STARTED} 127.0.0.1:#{server.port}")
      if not Config.applied(server.sessions.options).asking
        Logger.info("approvals are off: tools run without asking (finn serve --approvals turns them on)")
      end

      IO.flush()
      stop_on_signals(server)
      Server.shutdown(server, Server.stop_requested(server))
      Logger.info("Finn Agent core stopped")
      IO.flush()
    error(e) ->
      Logger.warning(e.message)
      System.exit(2)
  end
end

private

## How long the task of the signals waits for one before it waits again.
SIGNAL_POLL_MS = 3_600_000

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
    error(e) -> Logger.warning("no signal handling: #{e.message}")
  end
end

def start(registry: Extensions.Registry) -> Result[Server.Server]
  clashes = Extensions.clashes(registry, Tools.all().map { |tool| tool.name })
  return error(clashes.join("\n")) if not clashes.empty?

  read = ->(name) { System.env(name) }
  options = try Config.from_env(read)
  for warning in options.warnings
    Logger.warning(warning)
  end

  # The core's own extensions: the skills, and the MCP servers, which start now.
  own = (
    Extensions.Served(registry: registry)
    |> Builtins.commands(read)
    |> Builtins.skills()
    |> Builtins.approvals(options.approvals, options.asking, options.live)
  )

  mounted = try Builtins.mcp(own, read, options.state_dir, options.trusted)
  all = mounted.served
  catalog = Catalog.start(
    Catalog.Options(url: options.models_url, cache: "#{options.state_dir}/#{Catalog.CACHE_FILE}"),
  )

  extended = options.with(
    reloads: [mounted.reload],
    mcp: some(mounted.control),
    stops: [mounted.stop],
    tools: options.tools + Extensions.spec_tools(registry),
    registry: some(all),
    catalog: some(catalog),
  )

  Server.start(extended)
end
