## The core's own extensions, on the registry as any other: the skills (the catalog in a new session's system prompt,
## `activate_skill`, `/name` in a message and the skills a fold keeps) and the tools of the MCP servers.

import Extensions from "../config/registry"
import McpTools from "../ext/mcp"
import Skills from "../ext/skills"

def skills(registry: Extensions.Registry) -> Extensions.Registry
  Extensions.add_builtin(registry, Extensions.Builtin(system: &catalogued, open: &opened))
end

## Starts the MCP servers of the config in the background (the end of the process stops them); their tools come as
## they list them.
def mcp(
  registry: Extensions.Registry,
  read: Fn[String, Result[String]],
  state_dir: String,
) -> Result[Extensions.Registry]
  board = McpTools.background(try McpTools.servers(read, state_dir), ->(warning: String) { IO.warn(warning) })
  ok(Extensions.add_late_tools(registry, -> { McpTools.tools(board) }))
end

private

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
