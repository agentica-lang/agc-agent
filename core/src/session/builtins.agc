## The core's own extensions, on the registry: the skills (the catalog in a new session's system prompt,
## `activate_skill`, `/name` in a message and the skills a fold keeps), the tools of the MCP servers and the approval.

import Approval from "../approval/approval"
import Extension from "../approval/extension"
import Extensions from "../config/registry"
import McpTools from "../ext/mcp"
import Skills from "../ext/skills"
import Spec from "../tools/spec"

def skills(served: Extensions.Served) -> Extensions.Served
  Extensions.add_builtin(served, Extensions.Builtin(system: &catalogued, open: &opened))
end

## Starts the MCP servers of the config in the background (the end of the process stops them); their tools come as
## they list them.
def mcp(served: Extensions.Served, read: Fn[String, Result[String]], state_dir: String) -> Result[Extensions.Served]
  board = McpTools.background(try McpTools.servers(read, state_dir), ->(warning: String) { IO.warn(warning) })
  ok(Extensions.add_late_tools(served, -> { McpTools.tools(board) }))
end

## The approval of every session: the server's `rules` with those of the session folder's project file; `asking` makes
## a call that no rule allows wait for an answer. None turns it off, and every call runs.
def approvals(served: Extensions.Served, rules: Optional[Approval.Rules], asking: Bool) -> Extensions.Served
  for all in option_list(rules)
    return served.with(approver: some(->(place: Extensions.Place) { approver_in(all, place, asking) }))
  end

  served
end

private

def approver_in(rules: Approval.Rules, place: Extensions.Place, asking: Bool) -> Result[Extensions.Approver]
  ok(approver(try Extension.open(rules, place.root, place.trusted, asking)))
end

def approver(a: Extension.Approvals) -> Extensions.Approver
  Extensions.Approver(
    verdict: verdict_of(a),
    allows: ->(tool: String, target: String) { Extension.allows?(a, tool, target) },
    prefix: &Extension.prefix,
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

def found(place: Extensions.Place) -> Skills.Found = Skills.discover(place.root, place.home, place.trusted)

def noted(expanded: Skills.Expanded) -> Extensions.Noted = Extensions.Noted(text: expanded.text, names: expanded.names)
