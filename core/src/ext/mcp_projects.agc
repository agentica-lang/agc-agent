## The MCP servers of the project files (`.finn/mcp.json`). They belong to the sessions of a folder: the first session
## there starts them, the sessions there share them, and the end of the last one stops them. A keeper starts and stops
## the boards one job after the other, so two instances of a server never overlap.

import Actor from "std/actor"
import Mcp from "pkg/mcp/mcp"
import McpTools from "./mcp"
import Spec from "../tools/spec"

## The projects that run.
struct Projects
  actor: Actor.Ref[Held, Msg]
  keeper: Actor.Ref[Kept, Job]
end

## What a folder adds to its sessions: the tools its servers listed so far, and the names of its servers, which take the
## place of the user's servers of the same name.
struct Scope
  tools: List[Spec.Tool]
  names: List[String]
end

## Starts with no project.
def start(warn: Fn[String, Void]) -> Projects
  keeper = Actor.start(Actor.Behaviour(init: -> { Kept(warn: warn) }, handle: &kept))
  actor = Actor.start(Actor.Behaviour(init: -> { Held(keeper: keeper.address) }, handle: &held))
  _ = Actor.cast(keeper.address, Job.Owner(actor.address))
  Projects(actor: actor, keeper: keeper)
end

## The session `session` opened in the folder `root`, whose project file gave `servers`. The first session of a folder
## starts them; a later one takes the servers that run.
def opened(projects: Projects, root: String, session: String, servers: List[Mcp.Server]) -> Void
  _ = Actor.cast(projects.actor.address, Msg.Opened(root, session, servers))
end

## The session `session` ended; the end of the last one of its folder stops the servers of the folder.
def ended(projects: Projects, session: String) -> Void
  _ = Actor.cast(projects.actor.address, Msg.Ended(session))
end

## What the folder `root` adds to its sessions.
def scope(projects: Projects, root: String) -> Scope
  none_yet = Scope(tools: [], names: [])
  answer: Result[Scope] = Actor.call(projects.actor.address, CALL_MS) do |reply| Msg.Scope(root, reply) end
  answer.unwrap_or(none_yet)
end

## Reads the project file of each folder with sessions again (`read` gives its servers): the servers of a folder whose
## file changed stop and the new ones start. A folder whose file does not read keeps its servers. What it did, for the
## report; empty when nothing changed.
def reload(projects: Projects, read: Fn[String, Result[List[Mcp.Server]]]) -> Result[String]
  roots: Result[List[String]] = Actor.call(projects.actor.address, CALL_MS) do |reply| Msg.Roots(reply) end
  fresh: Map[String, List[Mcp.Server]] = {}
  broken: List[String] = []
  for root in try roots
    case read.call(root)
      ok(servers) -> fresh = fresh.put(root, servers)
      error(e) -> broken = broken.push(e.message)
    end
  end

  restarted: Result[Int] = Actor.call(projects.actor.address, CALL_MS) do |reply| Msg.Replace(fresh, reply) end
  count = try restarted
  said = ""
  if count > 0
    said = "restarting #{count} project MCP server(s)"
  end

  return error(([said] + broken).select { |part| not part.empty? }.join("; ")) if not broken.empty?

  ok(said)
end

## Stops every project, for the end of the server.
def stop(projects: Projects) -> Void
  done: Result[Bool] = Actor.call(projects.keeper.address, FINISH_MS) do |reply| Job.Finish(reply) end
  _ = done
  _ = Actor.stop(projects.actor, CALL_MS)
  _ = Actor.stop(projects.keeper, CALL_MS)
end

private

CALL_MS = 5000
FINISH_MS = 120_000

# One folder: its sessions, the servers its file gave, and the board of the servers once the keeper started it.
struct Project
  sessions: List[String]
  servers: List[Mcp.Server]
  board: Optional[McpTools.Board] = none
end

struct Held
  keeper: Address[Job]
  projects: Map[String, Project] = {}
end

enum Msg
  Opened(String, String, List[Mcp.Server])
  Ended(String)
  Scope(String, Channel[Scope])
  Roots(Channel[List[String]])
  Replace(Map[String, List[Mcp.Server]], Channel[Int])
  Ready(String, List[Mcp.Server], McpTools.Board)
end

# What the keeper started: the board of each folder, the one it stops next.
struct Kept
  warn: Fn[String, Void]
  owner: Optional[Address[Msg]] = none
  boards: Map[String, McpTools.Board] = {}
end

enum Job
  Owner(Address[Msg])
  Set(String, List[Mcp.Server])
  Finish(Channel[Bool])
end

def held(state: Held, msg: Msg) -> Actor.Step[Held]
  case msg
    Msg.Opened(root, session, servers) -> Actor.continue(state.with(projects: add(state, root, session, servers)))
    Msg.Ended(session) -> Actor.continue(state.with(projects: remove(state, session)))
    Msg.Scope(root, reply) ->
      Actor.reply(reply, scope_of(state.projects.get(root)))
      Actor.continue(state)
    Msg.Roots(reply) ->
      Actor.reply(reply, state.projects.keys.sort)
      Actor.continue(state)
    Msg.Replace(fresh, reply) ->
      projects = state.projects
      restarted = 0
      for root in fresh.keys.sort
        for project in option_list(projects.get(root))
          if fresh[root] != project.servers
            projects = projects.put(root, project.with(servers: fresh[root], board: none))
            _ = Actor.cast(state.keeper, Job.Set(root, fresh[root]))
            restarted = restarted + fresh[root].size
          end
        end
      end

      Actor.reply(reply, restarted)
      Actor.continue(state.with(projects: projects))
    Msg.Ready(root, servers, board) ->
      case state.projects.get(root)
        some(project) if project.servers == servers ->
          Actor.continue(state.with(projects: state.projects.put(root, project.with(board: some(board)))))
        _ -> Actor.continue(state)
      end
  end
end

def add(state: Held, root: String, session: String, servers: List[Mcp.Server]) -> Map[String, Project]
  case state.projects.get(root)
    some(project) ->
      return state.projects if project.sessions.include?(session)

      state.projects.put(root, project.with(sessions: project.sessions.push(session)))
    none ->
      if not servers.empty?
        _ = Actor.cast(state.keeper, Job.Set(root, servers))
      end

      state.projects.put(root, Project(sessions: [session], servers: servers))
  end
end

def remove(state: Held, session: String) -> Map[String, Project]
  projects = state.projects
  for root in projects.keys
    project = projects[root]
    next if not project.sessions.include?(session)

    left = project.sessions.select { |id| id != session }
    if left.empty?
      projects = projects.delete(root)
      if not project.servers.empty?
        _ = Actor.cast(state.keeper, Job.Set(root, []))
      end
    else
      projects = projects.put(root, project.with(sessions: left))
    end
  end

  projects
end

def scope_of(found: Optional[Project]) -> Scope
  case found
    some(project) ->
      tools = project.board.map { |board| McpTools.tools(board) }.unwrap_or([])
      Scope(tools: tools, names: project.servers.map { |server| server.name })
    none -> Scope(tools: [], names: [])
  end
end

def kept(state: Kept, msg: Job) -> Actor.Step[Kept]
  case msg
    Job.Owner(owner) -> Actor.continue(state.with(owner: some(owner)))
    Job.Set(root, servers) ->
      for board in option_list(state.boards.get(root))
        stopped(board)
      end

      boards = state.boards.delete(root)
      if not servers.empty?
        board = McpTools.background(servers, state.warn)
        boards = boards.put(root, board)
        for owner in option_list(state.owner)
          _ = Actor.cast(owner, Msg.Ready(root, servers, board))
        end
      end

      Actor.continue(state.with(boards: boards))
    Job.Finish(reply) ->
      for root in state.boards.keys
        stopped(state.boards[root])
      end

      Actor.reply(reply, true)
      Actor.continue(state.with(boards: {}))
  end
end

def stopped(board: McpTools.Board) -> Void
  McpTools.stop(McpTools.wait(board))
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
