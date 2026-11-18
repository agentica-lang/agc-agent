## Agent Skills (agentskills.io): folders with a `SKILL.md` under `.finn/skills`, `.agents/skills` and `.claude/skills`
## of the session folder (only when it is trusted) and of the home folder. The system prompt lists each skill's name and
## description; the model loads one with `activate_skill`, the user with `/name` in a message. A loaded skill is its
## body in a `<skill_content>` block. The session keeps the names of the skills it loaded (its marks), so a skill loads
## once, and a compaction that folds one puts its content after the summary. The skill `finn` is built in, with the
## lowest precedence: its resources are the pages of Finn's own documentation, read in place (`docs`, never copied).

import LLM from "pkg/llm/llm"
import Regex from "std/regex"
import Spec from "../tools/spec"

TOOL = "activate_skill"
ROOTS = [".finn/skills", ".agents/skills", ".claude/skills"]
SKIPPED = [".git", "node_modules"]
MAX_DEPTH = 4
MAX_DIRS = 2000
MAX_RESOURCES = 50
MAX_SKILL_BYTES = 1_048_576
MAX_NAME = 64
MAX_DESCRIPTION = 1024
MAX_SKILLS = 100
BUNDLED = "finn"
BUNDLED_DESCRIPTION = (
  "Finn's own documentation: extensions and tools, skills, MCP servers, providers, config, sessions, the server and " +
  "the command line. Use when the task is to extend, configure or explain Finn itself."
)
OPEN = "<skill_content name=\""
CLOSE = "</skill_content>"
NAME = /\A[a-z0-9-]+\z/
CATALOG_NAME = /<name>([a-z0-9-]+)<\/name>/

struct Skill
  name: String
  description: String
  ## The real path of its SKILL.md; empty for the built-in skill, whose body is made from its folder.
  location: String
  ## Its real path.
  dir: String
  ## False when its frontmatter says `disable-model-invocation: true`: only the user loads it.
  for_model: Bool
end

## What discovery found, by name, and what it has to say about the files it skipped or shadowed.
struct Found
  skills: List[Skill]
  warnings: List[String]
end

struct Frontmatter
  fields: Map[String, String]
  body: String
end

## A user message with the content of the skills it names put before it, and their names.
struct Expanded
  text: String
  names: List[String]
end

## The skills of the session folder `root` (when `trusted`) and of `home` (none when empty), sorted by name, at most
## `MAX_SKILLS`; then the built-in `finn` when `docs` is a folder with pages of Finn's and there is room for it (the
## user's and the project's skills count first). A project skill shadows a user skill of the same name, and either the
## built-in one; in one scope the first root wins. A skills root may be a link, which is resolved once; a link inside
## it is not followed.
def discover(root: String, home: String, trusted: Bool, docs: String = "") -> Found
  found = Found(skills: [], warnings: [])
  if trusted
    found = scope(found, root)
  end

  if home != ""
    found = scope(found, home)
  end

  sorted = found.skills.sort_by { |skill| skill.name }
  found = found.with(skills: sorted)
  if sorted.size > MAX_SKILLS
    found = warned(
      found.with(skills: sorted.take(MAX_SKILLS)),
      "#{sorted.size} skills: only the first #{MAX_SKILLS} are used",
    )
  end

  found = bundled(found, docs)
  found.with(skills: found.skills.sort_by { |skill| skill.name })
end

## The catalog for the system prompt: the skills the model may load, sorted; empty when there is none.
def catalog(skills: List[Skill]) -> String
  shown = skills.select { |skill| skill.for_model }
  return "" if shown.empty?

  entries = shown.map do |skill|
    (
      "  <skill>\n    <name>#{skill.name}</name>\n    <description>#{escaped(skill.description)}</description>\n  </skill>"
    )
  end

  (
    "# Skills\n\nThe following skills provide specialized instructions for specific tasks. When a task matches a " +
    "skill's description, call the #{TOOL} tool with the skill's name to load its full instructions.\n\n" +
    "<available_skills>\n#{entries.join("\n")}\n</available_skills>\n"
  )
end

## The skills of a session whose system prompt is `system`, as saved: the model's are only those its catalog lists, so
## the tool and the folders `read_file` reads cannot drift from what the model was told.
def restrict(skills: List[Skill], system: String) -> List[Skill]
  listed = Regex.find_all(system, CATALOG_NAME).map { |m| m.groups[1].text }
  skills.select { |skill| not skill.for_model or listed.include?(skill.name) }
end

## The tools of the skills: `activate_skill`, its name an enum of the skills the model may load; none when there is
## none. It answers with the skill's content and marks it, or a short note when the session's marks have it already.
def tools(skills: List[Skill]) -> List[Spec.TurnTool]
  for tool in option_list(tool(skills))
    run = ->(input: JSON.Value, marks: List[String]) { activated(skills, input, marks) }
    return [Spec.TurnTool(tool: tool, run: run)]
  end

  []
end

## The user's `/name` of a skill in `text` puts its content before it, unless `marks` has it already.
def on_message(text: String, skills: List[Skill], marks: List[String]) -> Expanded
  blocks: List[String] = []
  names: List[String] = []
  for word in (text.split(" ").flat_map { |part| part.split("\n") })
    next if not word.start_with?("/")

    name = word.slice(1, word.length - 1)
    next if names.include?(name) or marks.include?(name)

    for skill in (skills.select { |s| s.name == name })
      loaded_skill = content(skill)
      if loaded_skill.ok?
        blocks = blocks.push(loaded_skill.unwrap!)
        names = names.push(name)
      end
    end
  end

  return Expanded(text: text, names: []) if blocks.empty?

  Expanded(text: "#{blocks.join("\n\n")}\n\n#{text}", names: names)
end

## What a compaction puts after its summary: the content of the skills of `marks`, but those that a message the fold
## `kept` loads: the result of an `activate_skill` call of the skill, or a user message that starts with skill content.
def on_fold(skills: List[Skill]) -> Fn[List[String], List[LLM.Message], String]
  ->(marks: List[String], kept: List[LLM.Message]) { folded_skills(skills, marks, kept) }
end

## The frontmatter of a SKILL.md and its body. Lenient: top-level `key: value` lines, where a value may hold colons,
## be quoted, or be a `|` or `>` block; nested values are skipped. A file without frontmatter, or a top-level line that
## is not `key: value`, is an error.
def parse(text: String) -> Result[Frontmatter]
  bom = String.from_code(65279)
  source = text
  if source.start_with?(bom)
    source = source.slice(1, source.length - 1)
  end

  lines = source.split("\n").map { |line| trim_cr(line) }
  return error("no frontmatter: the file must start with ---") if lines.empty? or lines[0].strip != "---"

  close = (1...lines.size).find { |i| lines[i].strip == "---" }
  return error("the frontmatter has no closing ---") if not close.ok?

  fields: Map[String, String] = {}
  i = 1
  last = close.unwrap!
  while i < last
    line = lines[i]
    i = i + 1
    next if line.strip == "" or line.strip.start_with?("#") or line.start_with?(" ") or line.start_with?("\t")

    colon = line.index_of(":")
    return error("line #{i} is not key: value: #{line}") if colon.none?

    key = line.slice(0, colon.unwrap!).strip
    value = line.slice(colon.unwrap! + 1, line.length - colon.unwrap! - 1).strip
    if value.start_with?("|") or value.start_with?(">")
      block: List[String] = []
      while i < last and (lines[i].strip == "" or lines[i].start_with?(" ") or lines[i].start_with?("\t"))
        block = block.push(lines[i].strip)
        i = i + 1
      end

      value = folded(block, value.start_with?(">"))
    end

    fields = fields.put(key, unquoted(value))
  end

  body = lines.drop(last + 1).join("\n").strip
  ok(Frontmatter(fields: fields, body: body))
end

private

struct ActivateArgs
  name: String
end

struct Answer
  text: String
  mark: Optional[String]
end

struct Walk
  found: Found
  dirs: Int
end

def tool(skills: List[Skill]) -> Optional[Spec.Tool]
  names = skills.select { |skill| skill.for_model }.map { |skill| JSON.from(skill.name) }
  return none if names.empty?

  name = JSON.object({"type": JSON.from("string"), "enum": JSON.array(names)})
  schema = JSON.object({
    "type": JSON.from("object"),
    "properties": JSON.object({"name": name}),
    "required": JSON.array([JSON.from("name")]),
  })

  some(
    Spec.Tool(
      name: TOOL,
      description: "Load the full instructions of a skill of the catalog, with the list of its files.",
      input_schema: schema,
      asks: false,
      run: ->(_ctx: Spec.Context, _input: JSON.Value) { error("activate_skill runs in the agent") },
      target: &target,
    ),
  )
end

def target(_ctx: Spec.Context, input: JSON.Value) -> Result[String]
  args = try Spec.args(input, ActivateArgs.codec)
  ok(args.name)
end

def activated(skills: List[Skill], input: JSON.Value, marks: List[String]) -> Spec.TurnOutput
  case activate(skills, input, marks)
    ok(answer) -> Spec.TurnOutput(output: Spec.output(ok(answer.text)), mark: answer.mark)
    error(e) -> Spec.TurnOutput(output: Spec.output(error(e.message)), mark: none)
  end
end

def activate(skills: List[Skill], input: JSON.Value, marks: List[String]) -> Result[Answer]
  args = try Spec.args(input, ActivateArgs.codec)
  skill = try named(skills.select { |s| s.for_model }, args.name)
  if marks.include?(skill.name)
    return ok(Answer(text: "The skill #{skill.name} is already loaded in this session.", mark: none))
  end

  ok(Answer(text: try content(skill), mark: some(skill.name)))
end

def folded_skills(skills: List[Skill], marks: List[String], kept: List[LLM.Message]) -> String
  blocks: List[String] = []
  for name in marks
    next if loaded_in(kept, name)

    for skill in (skills.select { |s| s.name == name })
      loaded_skill = content(skill)
      if loaded_skill.ok?
        blocks = blocks.push(loaded_skill.unwrap!)
      end
    end
  end

  return "" if blocks.empty?

  "\n\nThe skills loaded in this session:\n\n#{blocks.join("\n\n")}"
end

# A quote of the marker elsewhere (a file that `read_file` read) does not count.
def loaded_in(kept: List[LLM.Message], name: String) -> Bool
  head = "#{OPEN}#{name}\">"
  calls = kept.flat_map { |message| message.content.flat_map { |block| activation_id(block, name) } }
  for message in kept
    for block in message.content
      case block
        LLM.Block.ToolResult(output) if calls.include?(output.tool_use_id) ->
          return true if output.content.start_with?(head)
        LLM.Block.Text(part) if message.role == LLM.Role.User and part.text.start_with?(OPEN) ->
          return true if part.text.include?(head)
        _ -> nil
      end
    end
  end

  false
end

def activation_id(block: LLM.Block, name: String) -> List[String]
  case block
    LLM.Block.ToolUse(call) if call.name == TOOL ->
      case Spec.args(call.input, ActivateArgs.codec)
        ok(args) if args.name == name -> [call.id]
        _ -> []
      end

    _ -> []
  end
end

def escaped(text: String) -> String = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def scope(found: Found, base: String) -> Found
  scoped = found
  names = found.skills.map { |skill| skill.name }
  for root in ROOTS
    real = Path.real("#{base}/#{root}")
    next if not real.ok? or not directory?(real.unwrap!)

    dir = real.unwrap!

    walk = walked(Walk(found: Found(skills: [], warnings: []), dirs: 0), dir, 0)
    for skill in walk.found.skills
      if (scoped.skills.any? { |s| s.name == skill.name })
        kind = "a skill of the same name"
        if names.include?(skill.name)
          kind = "the project's skill"
        end

        scoped = warned(scoped, "#{skill.location}: #{skill.name} is shadowed by #{kind}")
      else
        scoped = scoped.with(skills: scoped.skills.push(skill))
      end
    end

    scoped = scoped.with(warnings: scoped.warnings + walk.found.warnings)
  end

  scoped
end

def walked(walk: Walk, dir: String, depth: Int) -> Walk
  return walk if depth > MAX_DEPTH or walk.dirs >= MAX_DIRS

  current = walk.with(dirs: walk.dirs + 1)
  return current.with(found: read_skill(current.found, dir)) if depth > 0 and File.stat("#{dir}/SKILL.md").ok?

  for name in names_in(dir)
    next if SKIPPED.include?(name) or name.start_with?(".")

    child = "#{dir}/#{name}"
    if directory?(child)
      current = walked(current, child, depth + 1)
    end
  end

  current
end

def read_skill(found: Found, dir: String) -> Found
  location = "#{dir}/SKILL.md"
  text = read(location)
  return warned(found, "#{location}: skipped, #{text.message}") if not text.ok?

  case parse(text.unwrap!)
    ok(front) ->
      description = front.fields.get("description").unwrap_or("").strip
      return warned(found, "#{location}: skipped, it has no description") if description == ""

      folder = dir.split("/").last
      name = front.fields.get("name").unwrap_or(folder).strip
      if name == ""
        name = folder
      end

      if name.length > MAX_NAME or not Regex.match?(name, NAME)
        return warned(found, "#{location}: skipped, the name must be a-z, 0-9 and -, at most #{MAX_NAME} characters")
      end

      noted = found
      if name != folder
        noted = warned(noted, "#{location}: the name #{name} is not the folder's #{folder}")
      end

      if description.length > MAX_DESCRIPTION
        description = description.slice(0, MAX_DESCRIPTION)
        noted = warned(noted, "#{location}: the description is cut at #{MAX_DESCRIPTION} characters")
      end

      for_model = front.fields.get("disable-model-invocation").unwrap_or("false").strip != "true"
      skill = Skill(name: name, description: description, location: location, dir: dir, for_model: for_model)
      noted.with(skills: noted.skills.push(skill))
    error(e) -> warned(found, "#{location}: skipped, #{e.message}")
  end
end

def bundled(found: Found, docs: String) -> Found
  return found if docs == "" or found.skills.size >= MAX_SKILLS
  return found if (found.skills.any? { |skill| skill.name == BUNDLED })

  real = Path.real(docs)
  return found if not real.ok? or not directory?(real.unwrap!)

  dir = real.unwrap!
  return found if pages(dir).empty?

  skill = Skill(name: BUNDLED, description: BUNDLED_DESCRIPTION, location: "", dir: dir, for_model: true)
  found.with(skills: found.skills.push(skill))
end

# The pages of the built-in skill: the Markdown files of `dir` itself, sorted, but those that start with `_` (the home
# page) and any that is not a regular file (a link may lead out of the folder, and `read_file` would follow it).
def pages(dir: String) -> List[String]
  names_in(dir).select { |name| name.end_with?(".md") and not name.start_with?("_") and regular?("#{dir}/#{name}") }
end

def regular?(path: String) -> Bool
  case File.lstat(path)
    ok(info) -> info.kind == "file"
    error(_) -> false
  end
end

# The body of the built-in skill: one line a page, from the descriptions in the pages' frontmatter.
def bundled_body(dir: String) -> String
  lines = pages(dir).map { |name| "- #{name}: #{page_description(dir, name)}" }
  (
    "Finn's documentation is the Markdown pages of the folder below, of the version that runs. Pick the page that " +
    "fits the task, read it with read_file (the skill directory and the page name make the path), and follow its " +
    "links: they name pages of the same folder.\n\n#{lines.join("\n")}"
  )
end

def page_description(dir: String, name: String) -> String
  text = read("#{dir}/#{name}")
  return "" if not text.ok?

  case parse(text.unwrap!)
    ok(front) -> front.fields.get("description").unwrap_or("").strip
    error(_) -> ""
  end
end

def content(skill: Skill) -> Result[String]
  body = bundled_body(skill.dir)
  resources: List[String] = []
  if skill.location != ""
    front = try parse(try read(skill.location))
    body = front.body
    resources = files(skill.dir, "", 0, [])
  end

  listed = ""
  if not resources.empty?
    shown = resources.take(MAX_RESOURCES).map { |path| "  <file>#{path}</file>" }.join("\n")
    if resources.size > MAX_RESOURCES
      shown = "#{shown}\n  (more files not listed)"
    end

    listed = "\n\n<skill_resources>\n#{shown}\n</skill_resources>"
  end

  ok(
    "#{OPEN}#{skill.name}\">\n#{body}\n\nSkill directory: #{skill.dir}\n" +
    "Relative paths in this skill are relative to the skill directory.#{listed}\n#{CLOSE}",
  )
end

# The files under `dir` but SKILL.md, as relative paths, at most one past the listing's cap.
def files(dir: String, prefix: String, depth: Int, found: List[String]) -> List[String]
  return found if depth > 3 or found.size > MAX_RESOURCES

  out = found
  for name in names_in(dir)
    next if SKIPPED.include?(name) or name.start_with?(".")
    next if depth == 0 and name == "SKILL.md"

    path = "#{dir}/#{name}"
    relative = "#{prefix}#{name}"
    if directory?(path)
      out = files(path, "#{relative}/", depth + 1, out)
    elsif out.size <= MAX_RESOURCES
      out = out.push(relative)
    end
  end

  out
end

def named(skills: List[Skill], name: String) -> Result[Skill]
  case (skills.find { |skill| skill.name == name })
    ok(skill) -> ok(skill)
    error(_) -> error("unknown skill: #{name}")
  end
end

def read(path: String) -> Result[String]
  info = try File.stat(path)
  return error("larger than #{MAX_SKILL_BYTES} bytes") if info.size_bytes > MAX_SKILL_BYTES

  File.read_text(path)
end

def names_in(dir: String) -> List[String]
  none_found: List[String] = []
  Dir.list(dir).unwrap_or(none_found).sort
end

# A link is not a directory here: a scan does not follow it.
def directory?(path: String) -> Bool
  case File.lstat(path)
    ok(info) -> info.kind == "directory"
    error(_) -> false
  end
end

def warned(found: Found, warning: String) -> Found = found.with(warnings: found.warnings.push(warning))

def trim_cr(line: String) -> String
  return line.slice(0, line.length - 1) if line.end_with?("\r")

  line
end

def folded(lines: List[String], fold: Bool) -> String
  return lines.join(" ").strip if fold

  lines.join("\n").strip
end

def unquoted(value: String) -> String
  if value.length >= 2 and value.start_with?("\"") and value.end_with?("\"")
    inner = value.slice(1, value.length - 2)
    return inner.replace("\\\"", "\"").replace("\\n", "\n").replace("\\\\", "\\")
  end

  if value.length >= 2 and value.start_with?("'") and value.end_with?("'")
    return value.slice(1, value.length - 2).replace("''", "'")
  end

  value
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
