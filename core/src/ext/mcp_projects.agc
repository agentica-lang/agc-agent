## The MCP servers of the project files (`.finn/mcp.json`). They belong to the sessions of a folder: the first session
## there starts them, the sessions there share them, and the end of the last one stops them. A keeper starts and stops
## the boards one job after the other, so two instances of a server never overlap.

import Actor from "std/actor"
import Mcp from "pkg/mcp/mcp"
import Protocol from "pkg/protocol/protocol"
import McpTools from "./mcp"
import Spec from "../tools/spec"

## The projects that run.
struct Projects
  actor: Actor.Ref[Held, Msg]
  keeper: Actor.Ref[Kept, Job]
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

## The tools that the project servers of the folder `root` listed so far. A folder that no session event named yet (the
## events do not wait for the observer) is read now with `load`, outside the actor, and taken in when its file has
## servers, so its sessions are not left without their tools. Such a folder has no session: the next `session_ended` or
## reload stops its servers, unless a `session_started` named it by then.
def tools(projects: Projects, root: String, load: Fn[String, List[Mcp.Server]]) -> List[Spec.Tool]
  known: Result[Optional[List[Spec.Tool]]] = Actor.call(projects.actor.address, CALL_MS) do |reply|
    Msg.Tools(root, reply)
  end

  for found in option_list(try_some(known))
    return found
  end

  servers = load.call(root)
  return [] if servers.empty?

  adopted: Result[List[Spec.Tool]] = Actor.call(projects.actor.address, CALL_MS) do |reply|
    Msg.Adopt(root, servers, reply)
  end

  adopted.unwrap_or([])
end

## The state of the project servers of the folder `root`, none for a folder with no project servers.
def status(projects: Projects, root: String) -> Result[List[McpTools.Status]]
  answer: Result[Result[List[McpTools.Status]]] = Actor.call(projects.actor.address, CALL_MS) do |reply|
    Msg.Status(root, reply)
  end

  return error("the MCP servers are busy, try again", kind: Protocol.KIND_MCP_STARTING) if not answer.ok?

  answer.unwrap!
end

## The board of the project servers of `root` once it started, for a reconnect.
def board(projects: Projects, root: String) -> Optional[McpTools.Board]
  answer: Result[Optional[McpTools.Board]] = Actor.call(projects.actor.address, CALL_MS) do |reply|
    Msg.Board(root, reply)
  end

  try_some(answer)
end

## Reads the project file of each folder with sessions again (`read` gives its servers): the servers of a folder whose
## file changed stop and the new ones start. A folder whose file does not read keeps its servers. What it did, for the
## report (how many servers stopped and started); empty when nothing changed.
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

  changed: Result[List[Int]] = Actor.call(projects.actor.address, CALL_MS) do |reply| Msg.Replace(fresh, reply) end
  counts = try changed
  said = ""
  if counts[0] + counts[1] > 0
    said = "project MCP servers: #{counts[0]} stopped, #{counts[1]} started"
  end

  return error(([said] + broken).select { |part| not part.empty? }.join("; ")) if not broken.empty?

  ok(said)
end

## Stops every project, for the end of the server.
def stop(projects: Projects) -> Void
  _ = Actor.stop(projects.actor, CALL_MS)
  done: Result[Bool] = Actor.call(projects.keeper.address, FINISH_MS) do |reply| Job.Finish(reply) end
  _ = done
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
  Tools(String, Channel[Optional[List[Spec.Tool]]])
  Adopt(String, List[Mcp.Server], Channel[List[Spec.Tool]])
  Roots(Channel[List[String]])
  Status(String, Channel[Result[List[McpTools.Status]]])
  Board(String, Channel[Optional[McpTools.Board]])
  Replace(Map[String, List[Mcp.Server]], Channel[List[Int]])
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
    Msg.Ended(session) ->
      kept = remove(state, session)
      Actor.continue(state.with(projects: reaped(state.with(projects: kept))))
    Msg.Tools(root, reply) ->
      Actor.reply(reply, state.projects.get(root).map { |project| tools_of(project) })
      Actor.continue(state)
    Msg.Adopt(root, servers, reply) ->
      projects = state.projects
      if not projects.has_key?(root)
        projects = adopted(state, root, servers)
      end

      Actor.reply(reply, tools_of(projects[root]))
      Actor.continue(state.with(projects: projects))
    Msg.Status(root, reply) ->
      Actor.reply(reply, status_of(state.projects.get(root)))
      Actor.continue(state)
    Msg.Board(root, reply) ->
      Actor.reply(reply, state.projects.get(root).map { |project| project.board }.unwrap_or(none))
      Actor.continue(state)
    Msg.Roots(reply) ->
      Actor.reply(reply, state.projects.keys.sort)
      Actor.continue(state)
    Msg.Replace(fresh, reply) ->
      projects = reaped(state)
      stopped = 0
      started = 0
      for root in fresh.keys.sort
        for project in option_list(projects.get(root))
          if fresh[root] != project.servers
            projects = projects.put(root, project.with(servers: fresh[root], board: none))
            _ = Actor.cast(state.keeper, Job.Set(root, fresh[root]))
            stopped = stopped + project.servers.size
            started = started + fresh[root].size
          end
        end
      end

      Actor.reply(reply, [stopped, started])
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

# A folder with no session noted: its servers start, and no session id will end them.
def adopted(state: Held, root: String, servers: List[Mcp.Server]) -> Map[String, Project]
  _ = Actor.cast(state.keeper, Job.Set(root, servers))
  state.projects.put(root, Project(sessions: [], servers: servers))
end

# The folders adopted without a session are dropped, and their servers stop.
def reaped(state: Held) -> Map[String, Project]
  projects = state.projects
  for root in projects.keys
    next if not projects[root].sessions.empty?

    projects = projects.delete(root)
    _ = Actor.cast(state.keeper, Job.Set(root, []))
  end

  projects
end

def status_of(found: Optional[Project]) -> Result[List[McpTools.Status]]
  case found
    some(project) ->
      case project.board
        some(board) -> McpTools.status(board)
        none -> ok(project.servers.map { |server| McpTools.Status(server: server, state: "connecting") })
      end

    none -> ok([])
  end
end

def tools_of(project: Project) -> List[Spec.Tool] = project.board.map { |board| McpTools.tools(board) }.unwrap_or([])

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

def try_some[T](value: Result[Optional[T]]) -> Optional[T]
  case value
    ok(found) -> found
    error(_) -> none
  end
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
