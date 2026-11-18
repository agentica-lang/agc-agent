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
  ## Reads the MCP servers of the config again: when they are not the ones that run, those are stopped and the new ones
  ## start (a call that runs on a stopped server fails). What it did, for the report; empty when nothing changed.
  reload: Fn[Result[String]]
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

  ok(Mounted(served: Extensions.add_late_tools(served, tools), reload: reload))
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
# A reload waits for the servers that still list their tools, then stops them.
MCP_RELOAD_MS = 120_000

# The MCP servers that run, in the actor that a reload changes.
struct Running
  board: Optional[McpTools.Board]
  servers: List[Mcp.Server]
end

enum Held
  Tools(Channel[List[Spec.Tool]])
  Replace(List[Mcp.Server], Channel[Result[String]])
end

def reloaded(address: Address[Held], read: Fn[String, Result[String]], state_dir: String) -> Result[String]
  fresh = try McpTools.servers(read, state_dir)
  again: Result[Result[String]] = Actor.call(address, MCP_RELOAD_MS) do |reply| Held.Replace(fresh, reply) end
  ok(try try again)
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
    Held.Replace(fresh, reply) if fresh == state.servers ->
      Actor.reply(reply, ok(""))
      Actor.continue(state)
    Held.Replace(fresh, reply) ->
      for board in option_list(state.board)
        McpTools.stop(McpTools.wait(board))
      end

      Actor.reply(reply, ok("#{fresh.size} MCP server(s) started again"))
      Actor.continue(Running(board: some(started(fresh)), servers: fresh))
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
