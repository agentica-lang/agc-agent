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
import McpTools from "../ext/mcp"
import Skills from "../ext/skills"
import Spec from "../tools/spec"
import Logger from "std/logger"

## The server with its MCP servers, and how to read them again.
struct Mounted
  served: Extensions.Served
  ## Reads the MCP servers of the config again: when they are not the ones that run, all of them are stopped (a call
  ## that runs on a stopped server fails) and the new list starts. What it did, for the report; empty when nothing
  ## changed.
  reload: Fn[Result[String]]
  ## Stops the servers and the actor that holds them, for the end of a test: a server stops with its process.
  stop: Fn[Void]
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

## Starts the MCP servers of the config in the background (the end of the process stops them); their tools come as
## they list them.
def mcp(served: Extensions.Served, read: Fn[String, Result[String]], state_dir: String) -> Result[Mounted]
  servers = try McpTools.servers(read, state_dir)
  init = -> { Running(board: some(started(servers)), servers: servers) }
  holder = Actor.start(Actor.Behaviour(init: init, handle: &handled))
  address = holder.address
  tools = -> {
    listed: Result[List[Spec.Tool]] = Actor.call(address, MCP_CALL_MS) do |reply| Held.Tools(reply) end
    none_yet: List[Spec.Tool] = []
    listed.unwrap_or(none_yet)
  }

  reload = -> { reloaded(address, read, state_dir) }

  stop = -> { finished(holder, address) }
  ok(Mounted(served: Extensions.add_late_tools(served, tools), reload: reload, stop: stop))
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

# The MCP servers that run, in the actor that a reload changes.
struct Running
  board: Optional[McpTools.Board]
  servers: List[Mcp.Server]
  # The tasks that stop the servers of the boards a reload replaced, so the swap itself does not wait for them.
  stopping: List[Task[Void]] = []
end

enum Held
  Tools(Channel[List[Spec.Tool]])
  Replace(List[Mcp.Server], Channel[Result[String]])
  Finish(Channel[Bool])
end

def finished(holder: Actor.Ref[Running, Held], address: Address[Held]) -> Void
  done: Result[Bool] = Actor.call(address, MCP_FINISH_MS) do |reply| Held.Finish(reply) end
  _ = done
  _ = Actor.stop(holder, MCP_CALL_MS)
end

def reloaded(address: Address[Held], read: Fn[String, Result[String]], state_dir: String) -> Result[String]
  fresh = try McpTools.servers(read, state_dir)
  again: Result[Result[String]] = Actor.call(address, MCP_CALL_MS) do |reply| Held.Replace(fresh, reply) end
  ok(try try again)
end

def stopped(board: McpTools.Board) -> Void
  McpTools.stop(McpTools.wait(board))
end

def started(servers: List[Mcp.Server]) -> McpTools.Board
  McpTools.background(servers, ->(warning: String) { Logger.warning(warning) })
end

def handled(state: Running, msg: Held) -> Actor.Step[Running]
  case msg
    Held.Tools(reply) ->
      no_tools: List[Spec.Tool] = []
      Actor.reply(reply, state.board.map { |board| McpTools.tools(board) }.unwrap_or(no_tools))
      Actor.continue(state)
    Held.Finish(reply) ->
      for task in state.stopping
        Task.await(task)
      end

      for board in option_list(state.board)
        stopped(board)
      end

      Actor.reply(reply, true)
      Actor.continue(state.with(board: none, stopping: []))
    Held.Replace(fresh, reply) if fresh == state.servers ->
      Actor.reply(reply, ok(""))
      Actor.continue(state)
    Held.Replace(fresh, reply) ->
      stopping = state.stopping
      for board in option_list(state.board)
        stopping = stopping.push(Task.spawn(&stopped, board))
      end

      Actor.reply(reply, ok("restarting #{fresh.size} MCP server(s)"))
      Actor.continue(Running(board: some(started(fresh)), servers: fresh, stopping: stopping))
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
