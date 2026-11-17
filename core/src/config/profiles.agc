## Profiles: named sets of the tools that a session's model sees, with text for its system prompt. A profile is a file
## `NAME.md` with front matter, in the user's folder (`$XDG_CONFIG_HOME/finn/profiles/`, else
## `~/.config/finn/profiles/`) and in `.finn/profiles/` of a trusted project; a later one replaces a profile of the same
## name. Two are built in: `build` (every tool) and `plan` (reads, searches and the todo list).
##
## ```markdown
## ---
## description: Reads and plans, changes nothing
## tools_allow: [read_file, grep, glob, todo_write]
## ---
## Plan the change. Do not edit files.
## ```
##
## `tools_allow` or `tools_deny` (not both) holds tool names, where `*` matches any text (`mcp__github__*`); with
## neither, every tool. The body goes after the system prompt. A profile only hides tools: the approval rules still
## decide on the calls of the tools it shows.

import Approval from "../approval/approval"

DEFAULT = "build"
PROJECT_FOLDER = ".finn/profiles"
PLAN_TOOLS = ["read_file", "glob", "grep", "todo_write", "activate_skill"]
PLAN_PROMPT = "You are planning: read, search and keep a todo list, but change no file and run no command."
NAME_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789-_"
KEYS = ["description", "tools_allow", "tools_deny"]
BUILT_IN = "built-in"
USER = "user"
PROJECT = "project"
BOM = 0xFEFF

struct Profile
  name: String
  description: String = ""
  allow: Optional[List[String]] = none
  deny: Optional[List[String]] = none
  prompt: String = ""
  ## Where it comes from: `BUILT_IN`, `USER` or `PROJECT`.
  source: String = BUILT_IN
end

## A warning of a load, about the profile `name`, or about a file that is not one when `name` is empty.
struct Warning
  name: String = ""
  text: String
end

## The profiles of a session's folders. A file that does not load is in `broken` (its name to the error), so only a
## choice of that name fails; `untrusted` names the profiles of a project that is not trusted, which are not read.
struct Loaded
  profiles: List[Profile]
  broken: Map[String, String] = {}
  warnings: List[Warning] = []
  untrusted: List[String] = []
end

def builtins() -> List[Profile]
  [
    Profile(name: DEFAULT, description: "every tool"),
    Profile(
      name: "plan",
      description: "reads and plans, changes nothing",
      allow: some(PLAN_TOOLS),
      prompt: PLAN_PROMPT,
    ),
  ]
end

## The built-in profiles, then those of `user_dir`, then those of the project at `root` (none when empty) when it is
## `trusted`: a later one replaces a profile of the same name, a broken one too. A file whose name is not a profile
## name is skipped with a warning.
def load(user_dir: String, root: String, trusted: Bool) -> Loaded
  loaded = Loaded(profiles: builtins())
  if not user_dir.empty?
    loaded = in_folder(loaded, user_dir, USER)
  end

  return loaded if root.empty?

  project = "#{root}/#{PROJECT_FOLDER}"
  return in_folder(loaded, project, PROJECT) if trusted

  loaded.with(untrusted: md_files(project).map { |file| file.slice(0, file.length - 3) }.select { |n| named?(n) })
end

## `$XDG_CONFIG_HOME/finn/profiles`, else `~/.config/finn/profiles`; empty without a home folder.
def user_folder(read: Fn[String, Result[String]]) -> String
  base = read.call("XDG_CONFIG_HOME").unwrap_or("")
  if base.empty?
    home = read.call("HOME").unwrap_or("")
    return "" if home.empty?

    base = "#{home}/.config"
  end

  "#{base}/finn/profiles"
end

## The profile of that name: an error when its file does not load, or when only an untrusted project has it.
def find(loaded: Loaded, name: String) -> Result[Profile]
  return error(loaded.broken[name]) if loaded.broken.has_key?(name)

  case (loaded.profiles.find { |p| p.name == name })
    ok(found) -> return ok(found)
    error(_) -> nil
  end

  if loaded.untrusted.include?(name)
    return error("profile #{name} is in #{PROJECT_FOLDER} of a folder that is not trusted (FINN_TRUSTED_DIRS)")
  end

  error("unknown profile #{name}: one of #{loaded.profiles.map { |p| p.name }.join(", ")}")
end

## What a client hears about `profile`: the warnings of its file, and the names of its lists that no tool of `known`
## has.
def warnings_of(loaded: Loaded, profile: Profile, known: List[String]) -> List[String]
  own = loaded.warnings.select { |w| w.name == profile.name }.map { |w| w.text }
  own + unknown(profile, known).map { |tool| "profile #{profile.name}: no tool is named #{tool}" }
end

## Whether the model sees `tool` under the profile.
def exposes?(profile: Profile, tool: String) -> Bool
  for allow in option_list(profile.allow)
    return allow.any? { |pattern| Approval.match?(tool, pattern) }
  end

  for deny in option_list(profile.deny)
    return not deny.any? { |pattern| Approval.match?(tool, pattern) }
  end

  true
end

## The names of the profile that no tool of `known` has: neither a glob nor an MCP tool, which come later.
def unknown(profile: Profile, known: List[String]) -> List[String]
  names = profile.allow.unwrap_or([]) + profile.deny.unwrap_or([])
  names.select do |name|
    not name.include?("*") and not name.include?("?") and not name.start_with?("mcp__") and not known.include?(name)
  end
end

## The system prompt with the profile's text after it.
def system(base: String, profile: Profile) -> String
  return base if profile.prompt.empty?

  "#{base}\n\n#{profile.prompt}"
end

## A profile from its file: front matter between `---` lines, then the text for the system prompt.
def parse(path: String, name: String, text: String) -> Result[Profile]
  lines = without_bom(text).split("\n").map { |line| without_cr(line) }
  return error("#{path}: the front matter starts with a --- line") if lines.empty? or lines[0].strip != "---"

  end_at = 0
  for at in 1...lines.size
    if lines[at].strip == "---"
      end_at = at
      break
    end
  end

  return error("#{path}: the front matter ends with a --- line") if end_at == 0

  profile = Profile(name: name, prompt: lines.drop(end_at + 1).join("\n").strip)
  key = ""
  for raw in lines.drop(1).take(end_at - 1)
    line = without_comment(raw)
    next if line.strip.empty?

    if line.strip.start_with?("- ")
      if not ["tools_allow", "tools_deny"].include?(key)
        return error("#{path}: a list item outside tools_allow or tools_deny")
      end

      profile = try with_names(path, profile, key, [unquoted(line.strip.slice(2, line.strip.length - 2))], true)
      next
    end

    parts = line.split(":")
    key = parts[0].strip
    value = parts.drop(1).join(":").strip
    return error("#{path}: unknown key #{key}: one of #{KEYS.join(", ")}") if not KEYS.include?(key)

    if key == "description"
      profile = profile.with(description: unquoted(value))
    else
      profile = try with_names(path, profile, key, try names_of(path, key, value), false)
    end
  end

  return error("#{path}: tools_allow and tools_deny cannot both be set") if profile.allow.some? and profile.deny.some?

  ok(profile)
end

private

def in_folder(before: Loaded, dir: String, source: String) -> Loaded
  loaded = before
  for file in md_files(dir)
    name = file.slice(0, file.length - 3)
    path = "#{dir}/#{file}"
    kind = case File.stat(path)
      ok(info) -> info.kind
      error(_) -> ""
    end

    if not named?(name) or kind != "file"
      skipped = Warning(text: "#{path}: skipped, not a profile (a file NAME.md, NAME of a-z, 0-9, - and _)")
      loaded = loaded.with(warnings: loaded.warnings.push(skipped))
      next
    end

    loaded = with_file(loaded, path, name, source)
  end

  loaded
end

# `loaded` with the profile of one file, or with its error in `broken`; either replaces a profile of that name.
def with_file(loaded: Loaded, path: String, name: String, source: String) -> Loaded
  warnings = loaded.warnings
  for replaced in (loaded.profiles.select { |p| p.name == name and source == PROJECT })
    warnings = warnings.push(Warning(name: name, text: "#{path} replaces the #{replaced.source} profile #{name}"))
  end

  others = loaded.profiles.select { |p| p.name != name }
  read = case File.read_text(path)
    ok(text) -> parse(path, name, text)
    error(e) -> error("#{path}: #{e.message}")
  end

  case read
    ok(profile) ->
      if profile.allow == some([])
        warnings = warnings.push(Warning(name: name, text: "#{path}: tools_allow is empty, so the model sees no tool"))
      end

      broken = loaded.broken.select { |key, _| key != name }
      loaded.with(profiles: others.push(profile.with(source: source)), broken: broken, warnings: warnings)
    error(e) -> loaded.with(profiles: others, broken: loaded.broken.put(name, e.message), warnings: warnings)
  end
end

def md_files(dir: String) -> List[String]
  nothing: List[String] = []
  Dir.list(dir).unwrap_or(nothing).select { |f| f.end_with?(".md") }.sort
end

def without_bom(text: String) -> String
  return text.slice(1, text.length - 1) if text.start_with?(String.from_code(BOM))

  text
end

# `[a, b]`, or nothing when a block list (`- a` lines) follows.
def names_of(path: String, key: String, value: String) -> Result[List[String]]
  return ok([]) if value.empty?
  if not value.start_with?("[") or not value.end_with?("]")
    return error("#{path}: #{key} is a list: [a, b], or - lines")
  end

  inner = value.slice(1, value.length - 2)
  ok(inner.split(",").map { |name| unquoted(name.strip) }.select { |name| not name.empty? })
end

# The names added to the list of `key`; `more` adds to it, else they start it.
def with_names(path: String, profile: Profile, key: String, names: List[String], more: Bool) -> Result[Profile]
  for name in names
    return error("#{path}: #{key} has an empty name") if name.empty?
  end

  if key == "tools_allow"
    before = more_of(profile.allow, more)
    return ok(profile.with(allow: some(before + names)))
  end

  ok(profile.with(deny: some(more_of(profile.deny, more) + names)))
end

def named?(name: String) -> Bool
  not name.empty? and not name.start_with?("-") and name.split("").all? { |c| NAME_CHARS.include?(c) }
end

def more_of(list: Optional[List[String]], more: Bool) -> List[String]
  return [] if not more

  list.unwrap_or([])
end

def without_comment(line: String) -> String
  case line.index_of(" #")
    some(i) -> line.slice(0, i)
    none -> line
  end
end

def unquoted(text: String) -> String
  return text.slice(1, text.length - 2) if text.length >= 2 and text.start_with?("\"") and text.end_with?("\"")
  return text.slice(1, text.length - 2) if text.length >= 2 and text.start_with?("'") and text.end_with?("'")

  text
end

def without_cr(line: String) -> String
  return line.slice(0, line.length - 1) if line.end_with?("\r")

  line
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
