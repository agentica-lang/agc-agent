## The tools of the MCP servers of the user's file (`FINN_MCP_CONFIG`, else `mcp.json` of the user's config folder) and
## of the project file `.finn/mcp.json` of a trusted session folder: a JSON file of the common shape
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
import Protocol from "pkg/protocol/protocol"
import Sandbox from "../tools/sandbox"
import Shell from "../tools/shell"
import Spec from "../tools/spec"

CONFIG_ENV = "FINN_MCP_CONFIG"
PROJECT_FILE = ".finn/mcp.json"
NAME = /\A[A-Za-z0-9_-]{1,64}\z/
ENV_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/
HEADER_NAME = /\A[A-Za-z0-9!#$%&'*+.^_`|~-]{1,128}\z/
# 127.0.0.0/8: each octet 0 to 255.
LOOPBACK_V4 = /\A127(\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}\z/
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
  servers: List[Mcp.Server]
  options: Mcp.Options
end

## What a board knows of one server: `connecting` until it listed its tools, then `connected` or `failed` with the
## reason.
struct Status
  server: Mcp.Server
  state: String
  error: String = ""
  tools: List[Mcp.Tool] = []
end

## The servers of a project file and what it left out.
struct Found
  servers: List[Mcp.Server]
  warnings: List[String]
end

## The servers of the user's file: the one `FINN_MCP_CONFIG` names, else `mcp.json` of the user's config folder. An
## empty `FINN_MCP_CONFIG` means no servers; a file it names that is not there is an error, and the default file that is
## not there is not (one that does not read is).
def servers(read: Fn[String, Result[String]], state_dir: String) -> Result[List[Mcp.Server]]
  logs = Logs(folder: "#{state_dir}/mcp", prefix: "")
  case read.call(CONFIG_ENV)
    ok(path) if path.empty? -> return ok([])
    ok(path) -> return user_servers(try File.read_text(path), CONFIG_ENV, read, logs)
    error(_) -> nil
  end

  path = user_file(read)
  return ok([]) if path.empty?

  case File.read_text(path)
    ok(text) -> user_servers(text, path, read, logs)
    error(e) if e.kind == "io.not_found" -> ok([])
    error(e) -> error("#{path}: #{e.message}")
  end
end

## Whether `FINN_MCP_CONFIG` is set: its file must be there and read, or the server does not start.
def configured?(read: Fn[String, Result[String]]) -> Bool = read.call(CONFIG_ENV).ok?

## The project file of the folder `root`, empty when it has none.
def project_file(root: String) -> String
  path = "#{root}/#{PROJECT_FILE}"
  return "" if not File.stat(path).ok?

  path
end

## What the project file of the folder `root` gives: its servers, and a warning for each one it leaves out (a server that
## does not read, one with a `${NAME}` in a header, one named like a server of the user, which is in `taken`). A file
## that does not read is an error. The servers start in the folder, and their logs are `project-HASH-NAME.log`, the hash
## of the folder.
def project(root: String, read: Fn[String, Result[String]], state_dir: String, taken: List[String]) -> Result[Found]
  path = project_file(root)
  return ok(Found(servers: [], warnings: [])) if path.empty?

  hash = OpenSSL.Digest.sha256_hexdigest(root.bytes).slice(0, 8)
  found = try parsed(
    try File.read_text(path),
    path,
    read,
    Logs(folder: "#{state_dir}/mcp", prefix: "project-#{hash}-"),
    root,
    false,
  )

  kept = found.servers.select { |server| not taken.include?(server.name) }
  clashes = found.servers.select { |server| taken.include?(server.name) }
  notes = clashes.map { |server|
    (
      "#{path}: #{server.name} is left out, the user's file has a server of that name; rename it (the user's rules for mcp__#{server.name}__ would apply to it)"
    )
  }

  ok(Found(servers: kept, warnings: found.warnings + notes))
end

## `$XDG_CONFIG_HOME/finn/mcp.json`, else `~/.config/finn/mcp.json`; empty without a home folder.
def user_file(read: Fn[String, Result[String]]) -> String
  base = read.call("XDG_CONFIG_HOME").unwrap_or("")
  if base.empty?
    home = read.call("HOME").unwrap_or("")
    return "" if home.empty?

    base = "#{home}/.config"
  end

  "#{base}/finn/mcp.json"
end

## Starts each server and lists its tools in a task of its own; `warn` gets each warning as it comes. The tools are
## always in the order of the servers, so of two with the same name the one of the first server stays, whichever
## answers first.
def background(servers: List[Mcp.Server], warn: Fn[String, Void], options: Mcp.Options = Mcp.Options()) -> Board
  init = -> { Listed(started: Started(clients: [], tools: [], warnings: []), warn: warn) }
  actor = Actor.start(Actor.Behaviour(init: init, handle: &handle))
  address = actor.address
  tasks = (0...servers.size).to_a.map { |i| Task.spawn { list(address, i, servers[i], options) } }
  Board(actor: actor, tasks: tasks, servers: servers, options: options)
end

## The state of each server of the board, in the order of the file; an error when the board does not answer or ended.
def status(board: Board) -> Result[List[Status]]
  answer: Result[List[Listing]] = Actor.call(board.actor.address, 5000) do |reply| Msg.Listings(reply) end
  return error("the MCP servers are busy, try again", kind: Protocol.KIND_MCP_STARTING) if not answer.ok?

  listed = answer.unwrap!
  ok(
    (0...board.servers.size).to_a.map do |i|
      case (listed.find { |l| l.order == i })
        ok(found) -> status_of(board.servers[i], found.listed)
        error(_) -> Status(server: board.servers[i], state: "connecting")
      end
    end,
  )
end

## Starts the server `name` again: its client stops, and a new one starts and lists the tools (the answer waits for
## it). One start of a server at a time: a server that is still on its first start, or on a reconnect, and a board
## that ends, refuse it (`mcp.starting`); a name the board has not is `mcp.not_found`. The board's actor does the
## start, so `wait` waits for it and a client it makes is never left behind.
def reconnect(board: Board, name: String) -> Result[Status]
  at = (0...board.servers.size).to_a.find { |i| board.servers[i].name == name }
  return error("no MCP server named #{name}", kind: Protocol.KIND_MCP_NOT_FOUND) if not at.ok?

  index = at.unwrap!
  address = board.actor.address
  answer: Result[Result[Task[Listing]]] = Actor.call(address, 5000) do |reply|
    Msg.Reconnect(index, address, board.servers[index], board.options, reply)
  end

  return error("the MCP servers are restarting, try again", kind: Protocol.KIND_MCP_STARTING) if not answer.ok?

  started = Task.await(try try answer)
  case started.listed
    error(e) if e.kind == Protocol.KIND_MCP_STARTING -> error(e.message, kind: e.kind)
    _ -> ok(status_of(board.servers[index], started.listed))
  end
end

## The name of the program of a stdio server (what `env -i VAR=... PROGRAM` starts), or the url without its path and
## query for a server on HTTP: what a person is told of where it runs, never its environment or headers.
def target(server: Mcp.Server) -> String
  if not server.url.empty?
    start = server.url.index_of("://").unwrap_or(0) + 3
    rest = server.url.slice(start, server.url.length - start)
    return server.url.slice(0, start) + rest.split("/")[0].split("?")[0].split("#")[0]
  end

  words = server.args.drop_while { |word| word == "-i" or word.include?("=") }
  return server.command if words.empty?

  words[0]
end

## The tools listed so far.
def tools(board: Board) -> List[Spec.Tool] = state(board).tools

## Waits until every server listed its tools or was left out (and every reconnect ended), and ends the board; the
## clients keep running. A reconnect asked after that is refused.
def wait(board: Board) -> Started
  for task in board.tasks
    Task.await(task)
  end

  while true
    answer: Result[List[Task[Listing]]] = Actor.call(board.actor.address, 5000) do |reply| Msg.Pending(reply) end
    break if not answer.ok? or answer.unwrap!.empty?

    for task in answer.unwrap!
      Task.await(task)
    end
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

# Where the servers of a file write their stderr: `FOLDER/PREFIXNAME.log`.
struct Logs
  folder: String
  prefix: String
end

struct Listed
  started: Started
  warn: Fn[String, Void]
  listings: List[Listing] = []
  ## The starts that reconnects began and `wait` has not taken, the servers (by order) that one runs for, and whether
  ## `wait` found nothing more to wait for: no reconnect starts after that.
  tracked: List[Task[Listing]] = []
  reconnecting: List[Int] = []
  closed: Bool = false
end

struct Listing
  order: Int
  server: Mcp.Server
  client: Mcp.Client
  listed: Result[List[Mcp.Tool]]
end

enum Msg
  Add(Listing)
  Reconnect(Int, Address[Msg], Mcp.Server, Mcp.Options, Channel[Result[Task[Listing]]])
  Pending(Channel[List[Task[Listing]]])
  Get(Channel[Started])
  Listings(Channel[List[Listing]])
end

def handle(state: Listed, msg: Msg) -> Actor.Step[Listed]
  case msg
    Msg.Add(listing) ->
      for before in (state.listings.select { |l| l.order == listing.order and l.listed.ok? })
        Mcp.stop(before.client)
      end

      listings = state.listings.select { |l| l.order != listing.order }.push(listing).sort_by { |l| l.order }
      started = merged(listings)

      name = listing.server.name
      own = started.warnings.select { |w| w.start_with?("mcp #{name}:") or w.start_with?("mcp #{name} ") }
      for warning in own
        state.warn.call(warning)
      end

      Actor.continue(
        state.with(
          started: started,
          listings: listings,
          reconnecting: state.reconnecting.select { |order| order != listing.order },
        ),
      )
    Msg.Reconnect(order, address, server, options, reply) ->
      found = state.listings.find { |l| l.order == order }
      if state.closed
        _ = Actor.reply(reply, error("the MCP servers are stopping", kind: Protocol.KIND_MCP_STARTING))
        return Actor.continue(state)
      end

      if state.reconnecting.include?(order) or not found.ok?
        _ = Actor.reply(reply, error("the MCP server #{server.name} is starting", kind: Protocol.KIND_MCP_STARTING))
        return Actor.continue(state)
      end

      old: Optional[Mcp.Client] = none
      if found.unwrap!.listed.ok?
        old = some(found.unwrap!.client)
      end

      task = Task.spawn { restart(address, order, server, options, old) }
      _ = Actor.reply(reply, ok(task))
      listings = state.listings.select { |l| l.order != order }
      Actor.continue(
        state.with(
          started: merged(listings),
          listings: listings,
          tracked: state.tracked.push(task),
          reconnecting: state.reconnecting.push(order),
        ),
      )
    Msg.Pending(reply) ->
      _ = Actor.reply(reply, state.tracked)
      Actor.continue(state.with(tracked: [], closed: state.tracked.empty?))
    Msg.Get(reply) ->
      _ = Actor.reply(reply, state.started)
      Actor.continue(state)
    Msg.Listings(reply) ->
      _ = Actor.reply(reply, state.listings)
      Actor.continue(state)
  end
end

def merged(listings: List[Listing]) -> Started
  started = Started(clients: [], tools: [], warnings: [])
  for each in listings
    started = added(started, each.server, each.client, each.listed)
  end

  started
end

def status_of(server: Mcp.Server, listed: Result[List[Mcp.Tool]]) -> Status
  case listed
    ok(tools) -> Status(server: server, state: "connected", tools: tools)
    error(e) -> Status(server: server, state: "failed", error: e.message)
  end
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end

def list(address: Address[Msg], order: Int, server: Mcp.Server, options: Mcp.Options) -> Void
  _ = started_server(address, order, server, options)
end

# Starts the server, lists its tools and hands the result to the board; the result too, for who waits for it.
def started_server(address: Address[Msg], order: Int, server: Mcp.Server, options: Mcp.Options) -> Listing
  client = Mcp.start(server, options)
  listed = Mcp.tools(client)
  if not listed.ok?
    Mcp.stop(client)
  end

  listing = Listing(order: order, server: server, client: client, listed: listed)
  if not Actor.cast(address, Msg.Add(listing)).ok?
    if listed.ok?
      Mcp.stop(client)
    end

    return Listing(
      order: order,
      server: server,
      client: client,
      listed: error("the MCP servers are restarting", kind: Protocol.KIND_MCP_STARTING),
    )
  end

  listing
end

# The old client of a server stops, then the new one starts.
def restart(
  address: Address[Msg],
  order: Int,
  server: Mcp.Server,
  options: Mcp.Options,
  old: Optional[Mcp.Client],
) -> Listing
  for client in option_list(old)
    Mcp.stop(client)
  end

  started_server(address, order, server, options)
end

def state(board: Board) -> Started
  answer: Result[Started] = Actor.call(board.actor.address, 5000) do |reply| Msg.Get(reply) end
  answer.unwrap_or(Started(clients: [], tools: [], warnings: []))
end

def ignore(_text: String) -> Void
  return
end

def user_servers(text: String, label: String, read: Fn[String, Result[String]], logs: Logs) -> Result[List[Mcp.Server]]
  found = try parsed(text, label, read, logs, ".", true)
  ok(found.servers)
end

# The servers of the file `text`; `label` starts each error. A strict file (the user's) fails at the first server that
# does not read; the project's leaves it out with a warning.
def parsed(
  text: String,
  label: String,
  read: Fn[String, Result[String]],
  logs: Logs,
  cwd: String,
  strict: Bool,
) -> Result[Found]
  config = try JSON.parse(text)
  entries = JSON.get(config, "mcpServers").unwrap_or(JSON.object({}))
  fields = case JSON.node(entries)
    JSON.Node.Object(map) -> ok(map)
    _ -> error("#{label}: mcpServers is not an object")
  end

  map = try fields
  if not map.empty?
    try private_dir(Sandbox.parent(logs.folder))
    try private_dir(logs.folder)
  end

  out = Found(servers: [], warnings: [])
  for name in map.keys.sort
    made = named(name, map[name], logs, read, label, cwd, strict)
    case made
      ok(server) -> out = out.with(servers: out.servers.push(server))
      error(e) if strict -> return error(e.message)
      error(e) -> out = out.with(warnings: out.warnings.push(e.message))
    end
  end

  ok(out)
end

def named(
  name: String,
  json: JSON.Value,
  logs: Logs,
  read: Fn[String, Result[String]],
  label: String,
  cwd: String,
  strict: Bool,
) -> Result[Mcp.Server]
  if not Regex.match?(name, NAME) or name.include?("__")
    return error("#{label}: a server name is letters, digits, _ and - without \"__\": #{name.inspect}")
  end

  server(name, json, "#{logs.folder}/#{logs.prefix}#{name}.log", read, label, cwd, strict)
end

# The logs can hold what the tools read: the folder is only the user's, as the state folder is. Two readers of
# a project
# file may make it at once: the one that lost finds it there.
def private_dir(path: String) -> Result[Void]
  return ok() if File.stat(path).ok?

  _ = Dir.mkdir(Sandbox.parent(path))
  made = Dir.mkdir_private(path)
  return ok() if File.stat(path).ok?

  made
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
def server(
  name: String,
  json: JSON.Value,
  log: String,
  read: Fn[String, Result[String]],
  label: String,
  cwd: String,
  strict: Bool,
) -> Result[Mcp.Server]
  command = JSON.string(JSON.get(json, "command").unwrap_or(JSON.from(""))).unwrap_or("")
  url = JSON.string(JSON.get(json, "url").unwrap_or(JSON.from(""))).unwrap_or("")
  return error("#{label}: server #{name} has both a command and a url") if not command.empty? and not url.empty?
  return remote(name, url, json, read, label, strict) if not url.empty?
  return error("#{label}: server #{name} has no command or url") if command.empty?

  args: List[String] = []
  given: List[JSON.Value] = JSON.list(JSON.get(json, "args").unwrap_or(JSON.array([]))).unwrap_or([])
  for arg in given
    args = args.push(try JSON.string(arg))
  end

  return error("#{label}: the command of #{name} has a \"=\"") if command.include?("=")

  env: List[String] = []
  case JSON.node(JSON.get(json, "env").unwrap_or(JSON.object({})))
    JSON.Node.Object(vars) ->
      for key in vars.keys.sort
        return error("#{label}: env of #{name} has a bad name: #{key.inspect}") if not Regex.match?(key, ENV_NAME)

        env = env.push("#{key}=#{try JSON.string(vars[key])}")
      end

    _ -> return error("#{label}: env of #{name} is not an object")
  end

  words = ["-i"] + Shell.environment(read) + env + [command] + args
  ok(Mcp.Server(name: name, command: "/usr/bin/env", args: words, log: log, cwd: cwd))
end

def remote(
  name: String,
  url: String,
  json: JSON.Value,
  read: Fn[String, Result[String]],
  label: String,
  strict: Bool,
) -> Result[Mcp.Server]
  if not url.start_with?("http://") and not url.start_with?("https://")
    return error("#{label}: the url of #{name} is not http:// or https://")
  end

  authority = url.split("://")[1].split("/")[0].split("?")[0].split("#")[0]
  return error("#{label}: the url of #{name} has a user (put a key in headers)") if authority.include?("@")

  headers: Map[String, String] = {}
  case JSON.node(JSON.get(json, "headers").unwrap_or(JSON.object({})))
    JSON.Node.Object(given) ->
      for key in given.keys.sort
        if not Regex.match?(key, HEADER_NAME) or OWN_HEADERS.include?(key.downcase)
          return error("#{label}: headers of #{name} has a bad or reserved name: #{key.inspect}")
        end

        raw = try JSON.string(given[key])
        if not strict and raw.include?("${")
          return error(
            "#{label}: #{name} is left out: the header #{key} reads #{variable_of(raw)} of the environment, which a project file cannot (put the key in the user's file)",
          )
        end

        value = try expand(raw, "#{label}: header #{key} of #{name}", read)
        headers = headers.put(key, value)
      end

    _ -> return error("#{label}: headers of #{name} is not an object")
  end

  if not headers.empty? and url.start_with?("http://") and not loopback?(authority)
    return error("#{label}: #{name} sends headers in clear text: its url is http:// to another host than this one")
  end

  ok(Mcp.Server(name: name, url: url, headers: headers))
end

# `${NAME}` of a header value, to name the variable; its value is never read.
def variable_of(text: String) -> String
  start = text.index_of("${").unwrap_or(0)
  tail = text.slice(start, text.length - start)
  close = tail.index_of("}")
  return "a variable" if close.none?

  tail.slice(0, close.unwrap! + 1)
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
