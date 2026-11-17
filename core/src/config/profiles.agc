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

struct Profile
  name: String
  description: String = ""
  allow: Optional[List[String]] = none
  deny: Optional[List[String]] = none
  prompt: String = ""
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

## The built-in profiles, then those of `user_dir`, then those of the project at `root` when it is `trusted`; a bad
## file is an error that names it.
def load(user_dir: String, root: String, trusted: Bool) -> Result[List[Profile]]
  found = builtins()
  folders = [user_dir].select { |dir| not dir.empty? }
  if trusted
    folders = folders.push("#{root}/#{PROJECT_FOLDER}")
  end

  for dir in folders
    for profile in try in_folder(dir)
      found = found.select { |p| p.name != profile.name }.push(profile)
    end
  end

  ok(found)
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

## The profile of that name.
def find(profiles: List[Profile], name: String) -> Result[Profile]
  case (profiles.find { |p| p.name == name })
    ok(found) -> ok(found)
    error(_) -> error("unknown profile #{name}: one of #{profiles.map { |p| p.name }.join(", ")}")
  end
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
  lines = text.split("\n").map { |line| without_cr(line) }
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

def in_folder(dir: String) -> Result[List[Profile]]
  out: List[Profile] = []
  return ok(out) if not File.stat(dir).ok?

  files = (try Dir.list(dir)).select { |f| f.end_with?(".md") }.sort
  for file in files
    name = file.slice(0, file.length - 3)
    path = "#{dir}/#{file}"
    return error("#{path}: a profile name is lowercase letters, digits, - and _") if not named?(name)

    out = out.push(try parse(path, name, try File.read_text(path)))
  end

  ok(out)
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
