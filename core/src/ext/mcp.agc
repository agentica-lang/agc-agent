## The tools of the MCP servers that `FINN_MCP_CONFIG` names: a JSON file of the common shape
## `{"mcpServers": {"NAME": {"command": "...", "args": [...], "env": {...}}}}`, where a server on streamable HTTP is
## `{"url": "https://...", "headers": {"Authorization": "Bearer ${TOKEN}"}}`: `${NAME}` in a header value is the
## variable of the agent's environment, so a key stays out of the file; it is never shown.
##
## A tool is `mcp__SERVER__TOOL` and asks before each call, unless a rule allows it (`mcp__fs__read(*)`); its target is
## the JSON input. A server starts with the short environment of the bash tool plus its `env`, which is passed on as it
## is (a key it needs goes there), and writes its stderr to `STATE_DIR/mcp/NAME.log`. A server whose tools cannot be
## listed is left out, and a tool whose name another one already has, with a warning.

import Actor from "std/actor"
import Regex from "std/regex"
import Mcp from "pkg/mcp/mcp"
import Sandbox from "../tools/sandbox"
import Shell from "../tools/shell"
import Spec from "../tools/spec"

CONFIG_ENV = "FINN_MCP_CONFIG"
NAME = /\A[A-Za-z0-9_-]{1,64}\z/
ENV_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/
HEADER_NAME = /\A[A-Za-z0-9!#$%&'*+.^_`|~-]{1,128}\z/
LOOPBACK_V4 = /\A127(\.[0-9]{1,3}){3}\z/
## The headers that the transport sets.
OWN_HEADERS = [
  "accept", "connection", "content-length", "content-type", "host", "last-event-id", "mcp-protocol-version",
  "mcp-session-id", "transfer-encoding",
]

## The running clients, their tools, and what was left out.
struct Started
  clients: List[Mcp.Client]
  tools: List[Spec.Tool]
  warnings: List[String]
end

## Servers that list their tools in the background: `tools` gives those listed so far, so a slow server (`npx` on its
## first run) does not hold up the start.
struct Board
  actor: Actor.Ref[Listed, Msg]
  tasks: List[Task[Void]]
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

## Starts each server and lists its tools in a task of its own; `warn` gets each warning as it comes. The tools are
## always in the order of the servers, so of two with the same name the one of the first server stays, whichever
## answers first.
def background(servers: List[Mcp.Server], warn: Fn[String, Void], options: Mcp.Options = Mcp.Options()) -> Board
  init = -> { Listed(started: Started(clients: [], tools: [], warnings: []), warn: warn) }
  actor = Actor.start(Actor.Behaviour(init: init, handle: &handle))
  address = actor.address
  tasks = (0...servers.size).to_a.map { |i| Task.spawn { list(address, i, servers[i], options) } }
  Board(actor: actor, tasks: tasks)
end

## The tools listed so far.
def tools(board: Board) -> List[Spec.Tool] = state(board).tools

## Waits until every server listed its tools or was left out, and ends the board; the clients keep running.
def wait(board: Board) -> Started
  for task in board.tasks
    Task.await(task)
  end

  started = state(board)
  _ = Actor.stop(board.actor, 5000)
  started
end

## Starts each server and lists the tools of all of them at once.
def start(servers: List[Mcp.Server], options: Mcp.Options = Mcp.Options()) -> Started
  wait(background(servers, &ignore, options))
end

def stop(started: Started) -> Void
  for client in started.clients
    Mcp.stop(client)
  end
end

private

struct Listed
  started: Started
  warn: Fn[String, Void]
  listings: List[Listing] = []
end

struct Listing
  order: Int
  server: Mcp.Server
  client: Mcp.Client
  listed: Result[List[Mcp.Tool]]
end

enum Msg
  Add(Listing)
  Get(Channel[Started])
end

def handle(state: Listed, msg: Msg) -> Actor.Step[Listed]
  case msg
    Msg.Add(listing) ->
      listings = state.listings.push(listing).sort_by { |l| l.order }
      started = Started(clients: [], tools: [], warnings: [])
      for each in listings
        started = added(started, each.server, each.client, each.listed)
      end

      name = listing.server.name
      own = started.warnings.select { |w| w.start_with?("mcp #{name}:") or w.start_with?("mcp #{name} ") }
      for warning in own
        state.warn.call(warning)
      end

      Actor.continue(state.with(started: started, listings: listings))
    Msg.Get(reply) ->
      _ = Actor.reply(reply, state.started)
      Actor.continue(state)
  end
end

def list(address: Address[Msg], order: Int, server: Mcp.Server, options: Mcp.Options) -> Void
  client = Mcp.start(server, options)
  listed = Mcp.tools(client)
  if not listed.ok?
    Mcp.stop(client)
  end

  listing = Listing(order: order, server: server, client: client, listed: listed)
  _ = Actor.cast(address, Msg.Add(listing))
end

def state(board: Board) -> Started
  answer: Result[Started] = Actor.call(board.actor.address, 5000) do |reply| Msg.Get(reply) end
  answer.unwrap_or(Started(clients: [], tools: [], warnings: []))
end

def ignore(_text: String) -> Void
  return
end

# The logs can hold what the tools read: the folder is only the user's, as the state folder is.
def private_dir(path: String) -> Result[Void]
  return ok() if File.stat(path).ok?

  try Dir.mkdir(Sandbox.parent(path))
  Dir.mkdir_private(path)
end

def added(started: Started, server: Mcp.Server, client: Mcp.Client, listed: Result[List[Mcp.Tool]]) -> Started
  if not listed.ok?
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
  command = JSON.string(JSON.get(json, "command").unwrap_or(JSON.from(""))).unwrap_or("")
  url = JSON.string(JSON.get(json, "url").unwrap_or(JSON.from(""))).unwrap_or("")
  return error("#{CONFIG_ENV}: server #{name} has both a command and a url") if not command.empty? and not url.empty?
  return remote(name, url, json, read) if not url.empty?
  return error("#{CONFIG_ENV}: server #{name} has no command or url") if command.empty?

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

def remote(name: String, url: String, json: JSON.Value, read: Fn[String, Result[String]]) -> Result[Mcp.Server]
  if not url.start_with?("http://") and not url.start_with?("https://")
    return error("#{CONFIG_ENV}: the url of #{name} is not http:// or https://")
  end

  authority = url.split("://")[1].split("/")[0].split("?")[0].split("#")[0]
  return error("#{CONFIG_ENV}: the url of #{name} has a user (put a key in headers)") if authority.include?("@")

  headers: Map[String, String] = {}
  case JSON.node(JSON.get(json, "headers").unwrap_or(JSON.object({})))
    JSON.Node.Object(given) ->
      for key in given.keys.sort
        if not Regex.match?(key, HEADER_NAME) or OWN_HEADERS.include?(key.downcase)
          return error("#{CONFIG_ENV}: headers of #{name} has a bad or reserved name: #{key.inspect}")
        end

        value = try expand(try JSON.string(given[key]), "#{CONFIG_ENV}: header #{key} of #{name}", read)
        headers = headers.put(key, value)
      end

    _ -> return error("#{CONFIG_ENV}: headers of #{name} is not an object")
  end

  if not headers.empty? and url.start_with?("http://") and not loopback?(authority)
    return error(
      "#{CONFIG_ENV}: #{name} sends headers in clear text: its url is http:// to another host than this one",
    )
  end

  ok(Mcp.Server(name: name, url: url, headers: headers))
end

def loopback?(authority: String) -> Bool
  host = authority.downcase
  if host.start_with?("[")
    host = host.split("]")[0] + "]"
  else
    host = host.split(":")[0]
  end

  host == "localhost" or host == "[::1]" or Regex.match?(host, LOOPBACK_V4)
end

# `${NAME}` becomes the variable of that name, which must be set. The value never goes into an error.
def expand(text: String, place: String, read: Fn[String, Result[String]]) -> Result[String]
  out = ""
  rest = text
  while true
    start = rest.index_of("${")
    break if start.none?

    tail = rest.slice(start.unwrap! + 2, rest.length - start.unwrap! - 2)
    close = tail.index_of("}")
    return error("#{place}: a \"${\" without its \"}\"") if close.none?

    var = tail.slice(0, close.unwrap!)
    return error("#{place}: a bad variable name: #{var.inspect}") if not Regex.match?(var, ENV_NAME)

    value = read.call(var).unwrap_or("")
    return error("#{place} needs the variable #{var}, which is not set") if value.empty?

    out = "#{out}#{rest.slice(0, start.unwrap!)}#{value}"
    rest = tail.slice(close.unwrap! + 1, tail.length - close.unwrap! - 1)
  end

  out = "#{out}#{rest}"
  return error("#{place} has a control character") if (out.bytes.to_a.any? { |b| (b < 32 and b != 9) or b == 127 })

  ok(out)
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
