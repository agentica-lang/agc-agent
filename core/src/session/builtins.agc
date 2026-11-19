## The core's own extensions, on the registry: the skills (the catalog in a new session's system prompt,
## `activate_skill`, `/name` in a message and the skills a fold keeps), the tools of the MCP servers and the approval.

import LLM from "pkg/llm/llm"
import Approval from "../approval/approval"
import Commands from "../ext/commands"
import Config from "../config/config"
import Extension from "../approval/extension"
import Extensions from "../config/registry"
import Actor from "std/actor"
import Mcp from "pkg/mcp/mcp"
import Protocol from "pkg/protocol/protocol"
import McpTools from "../ext/mcp"
import Projects from "../ext/mcp_projects"
import Skills from "../ext/skills"
import Spec from "../tools/spec"
import Logger from "std/logger"
import Sandbox from "../tools/sandbox"

## The server with its MCP servers, and how to read them again.
struct Mounted
  served: Extensions.Served
  ## Reads the MCP servers of the config again: when they are not the ones that run, all of them are stopped (a call
  ## that runs on a stopped server fails) and the new list starts. What it did, for the report; empty when nothing
  ## changed.
  reload: Fn[Result[String]]
  ## Stops the servers and the actor that holds them, for the end of a test: a server stops with its process.
  stop: Fn[Void]
  ## What `GET /v1/mcp` and the reconnect read and do.
  control: Config.McpControl
end

## The slash commands of the user's folder (from `read`) and of a trusted session folder: a message that starts with
## `/NAME` becomes the command's prompt, read again at each such message. Before the skills, so a command wins over a
## skill of its name.
def commands(served: Extensions.Served, read: Fn[String, Result[String]]) -> Extensions.Served
  user_dir = Commands.user_folder(read)
  open = ->(place: Extensions.Place, _system: String) { commands_opened(place, user_dir) }
  Extensions.add_builtin(
    served,
    Extensions.Builtin(system: ->(_place: Extensions.Place, system: String) { system }, open: open),
  )
end

def skills(served: Extensions.Served) -> Extensions.Served
  Extensions.add_builtin(served, Extensions.Builtin(system: &catalogued, open: &opened))
end

## Starts the MCP servers of the user's file in the background (the end of the process stops them); their tools come as
## they list them. The servers of the `.finn/mcp.json` of a session folder in `trusted` start with its first session
## and stop with its last; one named like a server of the user's file is left out, with a warning. A default user file
## that does not read is a warning, and no server of it starts; the file `FINN_MCP_CONFIG` names must read.
def mcp(
  served: Extensions.Served,
  read: Fn[String, Result[String]],
  state_dir: String,
  trusted: List[String] = [],
) -> Result[Mounted]
  servers = try user_servers(read, state_dir)
  holder = start_holder(servers)
  address = holder.address
  projects = Projects.start(->(warning: String) { Logger.warning(warning) })
  named = -> {
    listed: Result[List[String]] = Actor.call(address, MCP_CALL_MS) do |reply| Held.Names(reply) end
    no_names: List[String] = []
    listed.unwrap_or(no_names)
  }

  project_servers = ->(root: String) { project_servers_of(trusted, read, state_dir, root, named.call()) }
  listed_servers = ->(root: String) { servers_of(project_servers.call(root)) }

  tools = ->(root: String) {
    listed: Result[List[Spec.Tool]] = Actor.call(address, MCP_CALL_MS) do |reply| Held.Tools(reply) end
    none_yet: List[Spec.Tool] = []
    listed.unwrap_or(none_yet) + Projects.tools(projects, root, listed_servers)
  }

  reload = -> { reloaded(address, read, state_dir, projects, ->(root: String) { reread(project_servers.call(root)) }) }

  stop = -> {
    Projects.stop(projects)
    finished(holder, address)
  }

  lifecycle = Extensions.Event.Seen(
    ["session_started", "session_ended"],
    ->(seen: Extensions.Seen) { project_event(projects, listed_servers, seen) },
  )

  own = Extensions.add_builtin(
    served.with(registry: served.registry.with(events: served.registry.events.push(lifecycle))),
    Extensions.Builtin(
      system: ->(_place: Extensions.Place, system: String) { system },
      open: ->(place: Extensions.Place, _system: String) { project_opened(place, project_servers) },
    ),
  )

  control = Config.McpControl(
    status: ->(root: String) { statuses(address, projects, root) },
    reconnect: ->(root: String, name: String) { reconnected(address, projects, root, name) },
  )

  ok(Mounted(served: Extensions.add_late_tools(own, tools), reload: reload, stop: stop, control: control))
end

## The approval of every session: the server's `rules` with those of the session folder's project file; `asking` makes
## a call that no rule allows wait for an answer. None turns it off, and every call runs.
def approvals(
  served: Extensions.Served,
  rules: Optional[Approval.Rules],
  asking: Bool,
  live: Optional[Config.Live] = none,
) -> Extensions.Served
  for all in option_list(rules)
    # A reload of the config file changes the rules and the asking of the sessions opened after it.
    latest = ->(place: Extensions.Place) {
      for live_rules in option_list(live)
        for found in option_list(Config.current(live_rules))
          return approver_in(found.approvals, place, found.asking)
        end
      end

      approver_in(all, place, asking)
    }

    return served.with(approver: some(latest))
  end

  served
end

private

MCP_CALL_MS = 5000
MCP_FINISH_MS = 120_000

# The MCP servers that run, in the actor that the tools are read from. A reload only tells the swapper, which stops the
# old board and then starts the new one, one swap after the other, so two instances of a server never overlap.
struct Running
  board: Optional[McpTools.Board]
  servers: List[Mcp.Server]
  swapper: Optional[Address[Swap]] = none
end

# The board that the swapper started last, the one it stops next.
struct Swapping
  board: Optional[McpTools.Board] = none
  holder: Address[Held]
end

enum Swap
  Adopt(McpTools.Board)
  To(List[Mcp.Server])
  End(Channel[Bool])
end

enum Held
  Status(Channel[List[McpTools.Status]])
  Board(Channel[Optional[McpTools.Board]])
  Tools(Channel[List[Spec.Tool]])
  Names(Channel[List[String]])
  Replace(List[Mcp.Server], Channel[Result[String]])
  Attach(Address[Swap])
  Ready(List[Mcp.Server], McpTools.Board)
  Finish(Channel[Bool])
end

def start_holder(servers: List[Mcp.Server]) -> Actor.Ref[Running, Held]
  holder = Actor.start(
    Actor.Behaviour(init: -> { Running(board: some(started(servers)), servers: servers) }, handle: &handled),
  )

  swapper = Actor.start(Actor.Behaviour(init: -> { Swapping(holder: holder.address) }, handle: &swapped))

  _ = Actor.cast(holder.address, Held.Attach(swapper.address))
  holder
end

def finished(holder: Actor.Ref[Running, Held], address: Address[Held]) -> Void
  done: Result[Bool] = Actor.call(address, MCP_FINISH_MS) do |reply| Held.Finish(reply) end
  _ = done
  _ = Actor.stop(holder, MCP_CALL_MS)
end

def reloaded(
  address: Address[Held],
  read: Fn[String, Result[String]],
  state_dir: String,
  projects: Projects.Projects,
  project_servers: Fn[String, Result[List[Mcp.Server]]],
) -> Result[String]
  fresh = try McpTools.servers(read, state_dir)
  again: Result[Result[String]] = Actor.call(address, MCP_CALL_MS) do |reply| Held.Replace(fresh, reply) end
  said = try try again
  projected = Projects.reload(projects, project_servers)
  return error(([said] + [projected.message]).select { |part| not part.empty? }.join("; ")) if not projected.ok?

  ok(([said] + [projected.unwrap!]).select { |part| not part.empty? }.join("; "))
end

# The servers of the user's file at the start: a default file that does not read is a warning and no servers, while
# the file `FINN_MCP_CONFIG` names must read.
def user_servers(read: Fn[String, Result[String]], state_dir: String) -> Result[List[Mcp.Server]]
  case McpTools.servers(read, state_dir)
    ok(servers) -> ok(servers)
    error(e) if McpTools.configured?(read) -> error(e.message)
    error(e) ->
      Logger.warning("mcp: #{e.message}")
      ok([])
  end
end

# What the project file of `root` gives: nothing unless the folder is trusted. `taken` are the names of the user's
# servers.
def project_servers_of(
  trusted: List[String],
  read: Fn[String, Result[String]],
  state_dir: String,
  root: String,
  taken: List[String],
) -> Result[McpTools.Found]
  return ok(McpTools.Found(servers: [], warnings: [])) if not Sandbox.trusted?(trusted, root)

  McpTools.project(root, read, state_dir, taken)
end

# The servers of a project file that read; none for a file that does not (a session opened there says why).
def servers_of(found: Result[McpTools.Found]) -> List[Mcp.Server]
  case found
    ok(read) -> read.servers
    error(_) -> []
  end
end

# The servers a reload takes from a project file, with its warnings in the log.
def reread(found: Result[McpTools.Found]) -> Result[List[Mcp.Server]]
  read = try found
  for warning in read.warnings
    Logger.warning("mcp: #{warning}")
  end

  ok(read.servers)
end

# The first session of a folder starts its project servers, the last one's end stops them. The events do not wait for
# this: a lost one is made up by `Projects.tools`, and a lost `session_ended` only delays a stop to the end of
# the server.
def project_event(
  projects: Projects.Projects,
  listed_servers: Fn[String, List[Mcp.Server]],
  seen: Extensions.Seen,
) -> Void
  if seen.name == "session_started"
    Projects.opened(projects, seen.root, seen.session, listed_servers.call(seen.root))
  else
    Projects.ended(projects, seen.session)
  end
end

# What a session in `place` says of its folder's `.finn/mcp.json`: a file that does not count, or does not read, or has
# servers left out.
def project_opened(place: Extensions.Place, project_servers: Fn[String, Result[McpTools.Found]]) -> Extensions.Opened
  Extensions.Opened(
    message: ->(text: String, _marks: List[String]) { Extensions.Noted(text: text, names: []) },
    fold: ->(_marks: List[String], _staying: List[LLM.Message]) { "" },
    warnings: project_warnings(place, project_servers),
  )
end

def project_warnings(place: Extensions.Place, project_servers: Fn[String, Result[McpTools.Found]]) -> List[String]
  file = McpTools.project_file(place.root)
  return [] if file.empty?
  return ["mcp: #{file} is ignored: the folder is not in FINN_TRUSTED_DIRS"] if not place.trusted

  case project_servers.call(place.root)
    ok(found) -> found.warnings.map { |warning| "mcp: #{warning}" }
    error(e) -> ["mcp: #{e.message}"]
  end
end

def stopped(board: McpTools.Board) -> Void
  McpTools.stop(McpTools.wait(board))
end

def started(servers: List[Mcp.Server]) -> McpTools.Board
  McpTools.background(servers, ->(warning: String) { Logger.warning(warning) })
end

def handled(state: Running, msg: Held) -> Actor.Step[Running]
  case msg
    Held.Status(reply) ->
      Actor.reply(reply, status_of(state))
      Actor.continue(state)
    Held.Board(reply) ->
      Actor.reply(reply, state.board)
      Actor.continue(state)
    Held.Tools(reply) ->
      no_tools: List[Spec.Tool] = []
      Actor.reply(reply, state.board.map { |board| McpTools.tools(board) }.unwrap_or(no_tools))
      Actor.continue(state)
    Held.Names(reply) ->
      Actor.reply(reply, state.servers.map { |server| server.name })
      Actor.continue(state)
    Held.Attach(swapper) ->
      for board in option_list(state.board)
        _ = Actor.cast(swapper, Swap.Adopt(board))
      end

      Actor.continue(state.with(swapper: some(swapper)))
    Held.Ready(servers, board) if servers == state.servers -> Actor.continue(state.with(board: some(board)))
    Held.Ready(_, _) -> Actor.continue(state)
    Held.Finish(reply) ->
      for swapper in option_list(state.swapper)
        ended: Result[Bool] = Actor.call(swapper, MCP_FINISH_MS) do |done| Swap.End(done) end
        _ = ended
      end

      Actor.reply(reply, true)
      Actor.continue(state.with(board: none))
    Held.Replace(fresh, reply) if fresh == state.servers ->
      Actor.reply(reply, ok(""))
      Actor.continue(state)
    Held.Replace(fresh, reply) ->
      for swapper in option_list(state.swapper)
        _ = Actor.cast(swapper, Swap.To(fresh))
      end

      Actor.reply(reply, ok("restarting #{fresh.size} MCP server(s)"))
      Actor.continue(state.with(board: none, servers: fresh))
  end
end

# The servers of the user: their states while the board runs, and `connecting` for the ones a reload is starting.
def status_of(state: Running) -> List[McpTools.Status]
  case state.board
    some(board) -> McpTools.status(board)
    none -> state.servers.map { |server| McpTools.Status(server: server, state: "connecting") }
  end
end

# The servers of the user, then the project servers of `root`.
def statuses(address: Address[Held], projects: Projects.Projects, root: String) -> List[Protocol.McpServer]
  mine: Result[List[McpTools.Status]] = Actor.call(address, MCP_CALL_MS) do |reply| Held.Status(reply) end
  none_yet: List[McpTools.Status] = []
  user = mine.unwrap_or(none_yet).map { |found| wire_status(found, "user") }
  user + Projects.status(projects, root).map { |found| wire_status(found, "project") }
end

def transport_of(server: Mcp.Server) -> String
  return "stdio" if server.url.empty?

  "http"
end

def wire_status(found: McpTools.Status, scope: String) -> Protocol.McpServer
  Protocol.McpServer(
    name: found.server.name,
    scope: scope,
    transport: transport_of(found.server),
    target: McpTools.target(found.server),
    state: found.state,
    error: found.error,
    tools: found.tools.map { |tool| Protocol.McpTool(name: tool.name, description: tool.description) },
  )
end

# Starts the server `name` of the user, else of the project servers of `root`, again.
def reconnected(
  address: Address[Held],
  projects: Projects.Projects,
  root: String,
  name: String,
) -> Result[Protocol.McpServer]
  owned: Result[List[String]] = Actor.call(address, MCP_CALL_MS) do |reply| Held.Names(reply) end
  if (try owned).include?(name)
    held: Result[Optional[McpTools.Board]] = Actor.call(address, MCP_CALL_MS) do |reply| Held.Board(reply) end
    for board in option_list(try held)
      return ok(wire_status(try McpTools.reconnect(board, name), "user"))
    end

    return error("the MCP server #{name} is starting", kind: "mcp.starting")
  end

  for board in option_list(Projects.board(projects, root))
    return ok(wire_status(try McpTools.reconnect(board, name), "project"))
  end

  error("no MCP server named #{name}", kind: "mcp.not_found")
end

def swapped(state: Swapping, msg: Swap) -> Actor.Step[Swapping]
  case msg
    Swap.Adopt(board) -> Actor.continue(state.with(board: some(board)))
    Swap.To(servers) ->
      for board in option_list(state.board)
        stopped(board)
      end

      fresh = started(servers)
      _ = Actor.cast(state.holder, Held.Ready(servers, fresh))
      Actor.continue(state.with(board: some(fresh)))
    Swap.End(reply) ->
      for board in option_list(state.board)
        stopped(board)
      end

      Actor.reply(reply, true)
      Actor.done(state.with(board: none))
  end
end

def approver_in(rules: Approval.Rules, place: Extensions.Place, asking: Bool) -> Result[Extensions.Approver]
  ok(approver(try Extension.open(rules, place.root, place.trusted, asking)))
end

def approver(a: Extension.Approvals) -> Extensions.Approver
  Extensions.Approver(
    verdict: verdict_of(a),
    allows: ->(tool: String, target: String) { Extension.allows?(a, tool, target) },
    prefix: ->(tool: String, target: String) { Extension.prefix(a, tool, target) },
    answered: ->(decision: String, tool: String, target: String) {
      approver(Extension.answered(a, decision, tool, target))
    },
    hidden: ->(path: String) { Extension.hidden?(a, path) },
    asking: a.asking,
    accept_edits: Extension.accept_edits?(a),
    with_accept_edits: ->(on: Bool) { approver(Extension.with_accept_edits(a, on)) },
  )
end

# A gate only when a call may ask or be refused.
def verdict_of(a: Extension.Approvals) -> Optional[Fn[Spec.Context, String, JSON.Value, Spec.Verdict]]
  return none if not Extension.gated?(a)

  some(->(ctx: Spec.Context, name: String, input: JSON.Value) { Extension.verdict(a, ctx, name, input) })
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end

def catalogued(place: Extensions.Place, system: String) -> String
  catalog = Skills.catalog(found(place).skills)
  return system if catalog == ""

  "#{system}\n#{catalog}"
end

# The skills a session's system prompt lists, and those the model does not load.
def opened(place: Extensions.Place, system: String) -> Extensions.Opened
  discovered = found(place)
  skills = Skills.restrict(discovered.skills, system)
  Extensions.Opened(
    read_roots: skills.map { |skill| skill.dir },
    tools: Skills.tools(skills),
    message: ->(text: String, marks: List[String]) { noted(Skills.on_message(text, skills, marks)) },
    fold: Skills.on_fold(skills),
    warnings: discovered.warnings.map { |warning| "skills: #{warning}" },
  )
end

def commands_opened(place: Extensions.Place, user_dir: String) -> Extensions.Opened
  loaded = Commands.load(user_dir, place.root, place.trusted)
  notes = loaded.warnings + Commands.clashes(loaded, found(place).skills.map { |s| s.name })
  warnings = notes.map { |n| n.text } + loaded.broken.keys.sort.map { |name| loaded.broken[name] }
  Extensions.Opened(
    message: ->(text: String, _marks: List[String]) { command_message(place, user_dir, text) },
    fold: ->(_marks: List[String], _staying: List[LLM.Message]) { "" },
    warnings: warnings.map { |w| "commands: #{w}" },
  )
end

def command_message(place: Extensions.Place, user_dir: String, text: String) -> Extensions.Noted
  return Extensions.Noted(text: text, names: []) if not text.start_with?("/")

  Extensions.Noted(text: Commands.expanded(Commands.load(user_dir, place.root, place.trusted), text), names: [])
end

def found(place: Extensions.Place) -> Skills.Found = Skills.discover(place.root, place.home, place.trusted, place.docs)

def noted(expanded: Skills.Expanded) -> Extensions.Noted = Extensions.Noted(text: expanded.text, names: expanded.names)
