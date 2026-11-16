## The tools of the MCP servers that `FINN_MCP_CONFIG` names: a JSON file of the common shape
## `{"mcpServers": {"NAME": {"command": "...", "args": [...], "env": {...}}}}`.
##
## A tool is `mcp__SERVER__TOOL` and asks before each call, unless a rule allows it (`mcp__fs__read(*)`); its target is
## the JSON input. A server starts with the short environment of the bash tool plus its `env`, which is passed on as it
## is (a key it needs goes there), and writes its stderr to `STATE_DIR/mcp/NAME.log`. A server whose tools cannot be
## listed at the start is left out, and a tool whose name another one already has, with a warning.

import Regex from "std/regex"
import Mcp from "pkg/mcp/mcp"
import Sandbox from "sandbox"
import Shell from "shell"
import Spec from "spec"

CONFIG_ENV = "FINN_MCP_CONFIG"
NAME = /\A[A-Za-z0-9_-]{1,64}\z/
ENV_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

## The running clients, their tools, and what was left out.
struct Started
  clients: List[Mcp.Client]
  tools: List[Spec.Tool]
  warnings: List[String]
end

## The servers of the config file that `read` names; none without it.
def servers(read: Fn[String, Result[String]], state_dir: String) -> Result[List[Mcp.Server]]
  path = read.call(CONFIG_ENV).unwrap_or("")
  return ok([]) if path.empty?

  config = try JSON.parse(try File.read_text(path))
  entries = JSON.get(config, "mcpServers").unwrap_or(JSON.object({}))
  fields = case JSON.node(entries)
    JSON.Node.Object(map) -> ok(map)
    _ -> error("#{CONFIG_ENV}: mcpServers is not an object")
  end

  map = try fields
  if not map.empty?
    try private_dir(state_dir)
    try private_dir("#{state_dir}/mcp")
  end

  out: List[Mcp.Server] = []
  for name in map.keys.sort
    if not Regex.match?(name, NAME) or name.include?("__")
      return error("#{CONFIG_ENV}: a server name is letters, digits, _ and - without \"__\": #{name.inspect}")
    end

    out = out.push(try server(name, map[name], "#{state_dir}/mcp/#{name}.log", read))
  end

  ok(out)
end

## Starts each server and lists the tools of all of them at once.
def start(servers: List[Mcp.Server], options: Mcp.Options = Mcp.Options()) -> Started
  clients = servers.map { |server| Mcp.start(server, options) }
  listings = clients.map { |client| Task.spawn { Mcp.tools(client) } }
  started = Started(clients: [], tools: [], warnings: [])
  for i in 0...servers.size
    started = added(started, servers[i], clients[i], Task.await(listings[i]))
  end

  started
end

def stop(started: Started) -> Void
  for client in started.clients
    Mcp.stop(client)
  end
end

private

# The logs can hold what the tools read: the folder is only the user's, as the state folder is.
def private_dir(path: String) -> Result[Void]
  return ok() if File.stat(path).ok?

  try Dir.mkdir(Sandbox.parent(path))
  Dir.mkdir_private(path)
end

def added(started: Started, server: Mcp.Server, client: Mcp.Client, listed: Result[List[Mcp.Tool]]) -> Started
  if not listed.ok?
    Mcp.stop(client)
    return started.with(warnings: started.warnings.push("mcp #{server.name} left out: #{listed.message}"))
  end

  tools = listed.unwrap!

  out = started.with(clients: started.clients.push(client))
  for tool in tools
    name = full_name(server, tool)
    if not Regex.match?(name, NAME)
      out = out.with(
        warnings: out.warnings.push("mcp #{server.name}: tool name too long or odd: #{tool.name.inspect}"),
      )
    elsif (out.tools.any? { |t| t.name == name })
      out = out.with(warnings: out.warnings.push("mcp #{server.name}: #{name} is there already; this one is left out"))
    else
      out = out.with(tools: out.tools.push(spec(server, client, tool)))
    end
  end

  out
end

# `env -i` with the variables bash keeps and the server's `env`: the keys of the agent's own environment stay out.
def server(name: String, json: JSON.Value, log: String, read: Fn[String, Result[String]]) -> Result[Mcp.Server]
  command = JSON.string(try JSON.get(json, "command")).unwrap_or("")
  return error("#{CONFIG_ENV}: server #{name} has no command") if command.empty?

  args: List[String] = []
  given: List[JSON.Value] = JSON.list(JSON.get(json, "args").unwrap_or(JSON.array([]))).unwrap_or([])
  for arg in given
    args = args.push(try JSON.string(arg))
  end

  return error("#{CONFIG_ENV}: the command of #{name} has a \"=\"") if command.include?("=")

  env: List[String] = []
  case JSON.node(JSON.get(json, "env").unwrap_or(JSON.object({})))
    JSON.Node.Object(vars) ->
      for key in vars.keys.sort
        return error("#{CONFIG_ENV}: env of #{name} has a bad name: #{key.inspect}") if not Regex.match?(key, ENV_NAME)

        env = env.push("#{key}=#{try JSON.string(vars[key])}")
      end

    _ -> return error("#{CONFIG_ENV}: env of #{name} is not an object")
  end

  words = ["-i"] + Shell.environment(read) + env + [command] + args
  ok(Mcp.Server(name: name, command: "/usr/bin/env", args: words, log: log))
end

def full_name(server: Mcp.Server, tool: Mcp.Tool) -> String = "mcp__#{server.name}__#{tool.name}"

def spec(server: Mcp.Server, client: Mcp.Client, tool: Mcp.Tool) -> Spec.Tool
  Spec.Tool(
    name: full_name(server, tool),
    description: tool.description,
    input_schema: tool.input_schema,
    asks: true,
    run: ->(_ctx, input) { run(client, tool.name, input) },
    target: ->(_ctx, input) { ok(JSON.encode(input)) },
  )
end

def run(client: Mcp.Client, name: String, input: JSON.Value) -> Result[String]
  output = try Mcp.call(client, name, input)
  return error(output.text) if output.is_error

  ok(output.text)
end
