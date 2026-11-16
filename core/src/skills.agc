## Agent Skills (agentskills.io): folders with a `SKILL.md` under `.finn/skills`, `.agents/skills` and `.claude/skills`
## of the session folder (only when it is trusted) and of the home folder. The system prompt lists each skill's name and
## description; the model loads one with `activate_skill`, the user with `/name` in a message. A loaded skill is its
## body in a `<skill_content>` block, which compaction keeps.

import Spec from "spec"

TOOL = "activate_skill"
ROOTS = [".finn/skills", ".agents/skills", ".claude/skills"]
SKIPPED = [".git", "node_modules"]
MAX_DEPTH = 4
MAX_DIRS = 2000
MAX_RESOURCES = 50
MAX_SKILL_BYTES = 1_048_576
OPEN = "<skill_content name=\""
CLOSE = "</skill_content>"

struct Skill
  name: String
  description: String
  ## The absolute path of its SKILL.md.
  location: String
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

## The skills of the session folder `root` (when `trusted`) and of `home` (none when empty), sorted by name. A project
## skill shadows a user skill of the same name; in one scope the first root wins.
def discover(root: String, home: String, trusted: Bool) -> Found
  found = Found(skills: [], warnings: [])
  if trusted
    found = scope(found, root)
  end

  if home != ""
    found = scope(found, home)
  end

  found.with(skills: found.skills.sort_by { |skill| skill.name })
end

## The catalog for the system prompt: the skills the model may load, sorted; empty when there is none.
def catalog(skills: List[Skill]) -> String
  shown = skills.select { |skill| skill.for_model }
  return "" if shown.empty?

  entries = shown.map do |skill|
    "  <skill>\n    <name>#{skill.name}</name>\n    <description>#{skill.description}</description>\n  </skill>"
  end

  (
    "# Skills\n\nThe following skills provide specialized instructions for specific tasks. When a task matches a " +
    "skill's description, call the #{TOOL} tool with the skill's name to load its full instructions.\n\n" +
    "<available_skills>\n#{entries.join("\n")}\n</available_skills>\n"
  )
end

## The tools of the skills: `activate_skill`, its name an enum of the skills the model may load; none when there is
## none. It answers with the skill's content, or a short note when the history has it already.
def tools(skills: List[Skill]) -> List[Spec.TurnTool]
  for tool in option_list(tool(skills))
    run = ->(input: JSON.Value, texts: List[String]) { Spec.output(activate(skills, input, loaded(texts))) }
    return [Spec.TurnTool(tool: tool, run: run)]
  end

  []
end

## The user's `/name` of a skill in `text` puts its content before it, unless the history's `texts` have it already.
def on_message(text: String, skills: List[Skill], texts: List[String]) -> String = expand(text, skills, loaded(texts))

## The skill blocks of the folded `texts` that compaction keeps, once each, but those the `others` still hold.
def kept(texts: List[String], others: List[String]) -> List[String]
  present = loaded(others)
  out: List[String] = []
  names: List[String] = []
  for block in (texts.flat_map { |text| blocks(text) })
    name = block_name(block)
    next if present.include?(name) or names.include?(name)

    out = out.push(block)
    names = names.push(name)
  end

  out
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

## The answer of `activate_skill`: the skill's content, or a short note when `seen` already holds it.
def activate(skills: List[Skill], input: JSON.Value, seen: List[String]) -> Result[String]
  args = try Spec.args(input, ActivateArgs.codec)
  skill = try named(skills.select { |s| s.for_model }, args.name)
  return ok("The skill #{skill.name} is already loaded in this session.") if seen.include?(skill.name)

  content(skill)
end

## `text` with the content of each `/name` it mentions put before it, but for the skills `seen` already holds.
def expand(text: String, skills: List[Skill], seen: List[String]) -> String
  blocks: List[String] = []
  names: List[String] = []
  for word in (text.split(" ").flat_map { |part| part.split("\n") })
    next if not word.start_with?("/")

    name = word.slice(1, word.length - 1)
    next if names.include?(name) or seen.include?(name)

    for skill in (skills.select { |s| s.name == name })
      loaded_skill = content(skill)
      if loaded_skill.ok?
        blocks = blocks.push(loaded_skill.unwrap!)
        names = names.push(name)
      end
    end
  end

  return text if blocks.empty?

  "#{blocks.join("\n\n")}\n\n#{text}"
end

## The names of the skills whose content is in `texts`.
def loaded(texts: List[String]) -> List[String]
  names: List[String] = []
  for block in (texts.flat_map { |text| blocks(text) })
    name = block_name(block)
    if not names.include?(name)
      names = names.push(name)
    end
  end

  names
end

## The skill blocks of `text`, in order.
def blocks(text: String) -> List[String]
  out: List[String] = []
  rest = text
  while true
    start = rest.index_of(OPEN)
    break if start.none?

    tail = rest.slice(start.unwrap!, rest.length - start.unwrap!)
    stop = tail.index_of(CLOSE)
    break if stop.none?

    out = out.push(tail.slice(0, stop.unwrap! + CLOSE.length))
    rest = tail.slice(stop.unwrap! + CLOSE.length, tail.length - stop.unwrap! - CLOSE.length)
  end

  out
end

## A user message as the user wrote it: without the skill blocks that `expand` put before it.
def typed(text: String) -> String
  rest = text
  while rest.start_with?(OPEN)
    stop = rest.index_of(CLOSE)
    break if stop.none?

    rest = rest.slice(stop.unwrap! + CLOSE.length, rest.length - stop.unwrap! - CLOSE.length)
    while rest.start_with?("\n")
      rest = rest.slice(1, rest.length - 1)
    end
  end

  rest
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

struct Walk
  found: Found
  dirs: Int
end

def scope(found: Found, base: String) -> Found
  scoped = found
  names = found.skills.map { |skill| skill.name }
  for root in ROOTS
    dir = "#{base}/#{root}"
    next if not directory?(dir)

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

      noted = found
      if name != folder
        noted = warned(noted, "#{location}: the name #{name} is not the folder's #{folder}")
      end

      if name.length > 64
        noted = warned(noted, "#{location}: the name is longer than 64 characters")
      end

      for_model = front.fields.get("disable-model-invocation").unwrap_or("false").strip != "true"
      skill = Skill(name: name, description: description, location: location, dir: dir, for_model: for_model)
      noted.with(skills: noted.skills.push(skill))
    error(e) -> warned(found, "#{location}: skipped, #{e.message}")
  end
end

def content(skill: Skill) -> Result[String]
  front = try parse(try read(skill.location))
  resources = files(skill.dir, "", 0, [])
  listed = ""
  if not resources.empty?
    shown = resources.take(MAX_RESOURCES).map { |path| "  <file>#{path}</file>" }.join("\n")
    if resources.size > MAX_RESOURCES
      shown = "#{shown}\n  (more files not listed)"
    end

    listed = "\n\n<skill_resources>\n#{shown}\n</skill_resources>"
  end

  ok(
    "#{OPEN}#{skill.name}\">\n#{front.body}\n\nSkill directory: #{skill.dir}\n" +
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

def directory?(path: String) -> Bool
  case File.stat(path)
    ok(info) -> info.kind == "directory"
    error(_) -> false
  end
end

def warned(found: Found, warning: String) -> Found = found.with(warnings: found.warnings.push(warning))

def block_name(block: String) -> String
  rest = block.slice(OPEN.length, block.length - OPEN.length)
  rest.slice(0, rest.index_of("\"").unwrap_or(0))
end

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
