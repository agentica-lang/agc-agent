## The tools of the MCP servers that `FINN_MCP_CONFIG` names: a JSON file of the common shape
## `{"mcpServers": {"NAME": {"command": "...", "args": [...], "env": {...}}}}`.
##
## A tool is `mcp__SERVER__TOOL` and asks before each call, unless a rule allows it (`mcp__fs__read(*)`); its target is
## the JSON input. A server inherits the environment of the server, with its `env` added, and writes its stderr to
## `STATE_DIR/mcp/NAME.log`. A server whose tools cannot be listed at the start is left out, with a warning.

import Regex from "std/regex"
import Mcp from "pkg/mcp/mcp"
import Sandbox from "sandbox"
import Spec from "spec"

CONFIG_ENV = "FINN_MCP_CONFIG"
NAME = /\A[A-Za-z0-9_-]{1,64}\z/

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
    if not Regex.match?(name, NAME)
      return error("#{CONFIG_ENV}: a server name is letters, digits, _ and -: #{name.inspect}")
    end

    out = out.push(try server(name, map[name], "#{state_dir}/mcp/#{name}.log"))
  end

  ok(out)
end

## Starts each server and lists its tools.
def start(servers: List[Mcp.Server], options: Mcp.Options = Mcp.Options()) -> Started
  started = Started(clients: [], tools: [], warnings: [])
  for server in servers
    client = Mcp.start(server, options)
    case Mcp.tools(client)
      ok(tools) ->
        named = tools.select { |t| Regex.match?(full_name(server, t), NAME) }
        skipped = tools.size - named.size
        if skipped > 0
          started = started.with(
            warnings: started.warnings.push("mcp #{server.name}: #{skipped} tools with names too long or odd"),
          )
        end

        started = started.with(
          clients: started.clients.push(client),
          tools: started.tools + named.map { |t| spec(server, client, t) },
        )
      error(e) ->
        Mcp.stop(client)
        started = started.with(warnings: started.warnings.push("mcp #{server.name} left out: #{e.message}"))
    end
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

def server(name: String, json: JSON.Value, log: String) -> Result[Mcp.Server]
  command = JSON.string(try JSON.get(json, "command")).unwrap_or("")
  return error("#{CONFIG_ENV}: server #{name} has no command") if command.empty?

  args: List[String] = []
  given: List[JSON.Value] = JSON.list(JSON.get(json, "args").unwrap_or(JSON.array([]))).unwrap_or([])
  for arg in given
    args = args.push(try JSON.string(arg))
  end

  env: Map[String, String] = {}
  case JSON.node(JSON.get(json, "env").unwrap_or(JSON.object({})))
    JSON.Node.Object(vars) ->
      for key in vars.keys
        env = env.put(key, try JSON.string(vars[key]))
      end

    _ -> return error("#{CONFIG_ENV}: env of #{name} is not an object")
  end

  ok(Mcp.Server(name: name, command: command, args: args, env: env, log: log))
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
