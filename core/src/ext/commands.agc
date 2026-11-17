## Slash commands: a file `NAME.md` in the user's folder (`$XDG_CONFIG_HOME/finn/commands/`, else
## `~/.config/finn/commands/`) or in `.finn/commands/` of a trusted project (which wins) is a prompt that `/NAME` at the
## start of a message stands for. `$ARGUMENTS` in it becomes the text after the name; without it, that text goes after
## the prompt. An optional front matter gives a `description`. The names of the clients' own commands stay theirs.

import Skills from "skills"

PROJECT_FOLDER = ".finn/commands"
ARGUMENTS = "$ARGUMENTS"
MAX_BYTES = 65_536
NAME_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789-_"
## The commands of the clients, which a file cannot take.
CLIENT_COMMANDS = [
  "new", "resume", "tree", "fork", "clone", "model", "thinking", "profile", "compact", "login", "logout", "stop",
  "cost", "help", "quit",
]
USER = "user"
PROJECT = "project"

struct Command
  name: String
  description: String = ""
  body: String
  source: String
end

## The commands of a session's folders. A file that does not load is in `broken` (its name to the error), so only that
## name fails; `warnings` names the files skipped and the commands that replace another (by name, or empty).
struct Loaded
  commands: List[Command] = []
  broken: Map[String, String] = {}
  warnings: List[Note] = []
end

struct Note
  name: String = ""
  text: String
end

## `$XDG_CONFIG_HOME/finn/commands`, else `~/.config/finn/commands`; empty without a home folder.
def user_folder(read: Fn[String, Result[String]]) -> String
  base = read.call("XDG_CONFIG_HOME").unwrap_or("")
  if base.empty?
    home = read.call("HOME").unwrap_or("")
    return "" if home.empty?

    base = "#{home}/.config"
  end

  "#{base}/finn/commands"
end

## The commands of `user_dir` (none when empty), then those of the project at `root` when it is `trusted`.
def load(user_dir: String, root: String, trusted: Bool) -> Loaded
  loaded = Loaded()
  if not user_dir.empty?
    loaded = in_folder(loaded, user_dir, USER)
  end

  return loaded if not trusted or root.empty?

  in_folder(loaded, "#{root}/#{PROJECT_FOLDER}", PROJECT)
end

## The warnings about `name`, and those of no name.
def warnings_of(loaded: Loaded, name: String) -> List[String]
  loaded.warnings.select { |w| w.name == name or w.name.empty? }.map { |w| w.text }
end

## `text` with a `/NAME` at its start put as the command's prompt; as it is when no command has that name.
def expanded(loaded: Loaded, text: String) -> String
  return text if not text.start_with?("/")

  head = text.split("\n")[0].split(" ")[0]
  name = head.slice(1, head.length - 1)
  case (loaded.commands.find { |c| c.name == name })
    ok(command) ->
      rest = text.slice(head.length, text.length - head.length).strip
      return command.body.replace(ARGUMENTS, rest) if command.body.include?(ARGUMENTS)
      return command.body if rest.empty?

      "#{command.body}\n\n#{rest}"
    error(_) -> text
  end
end

## The warnings of the commands that take the name of a skill of `skills`: the command wins.
def clashes(loaded: Loaded, skills: List[String]) -> List[Note]
  taken = loaded.commands.select { |c| skills.include?(c.name) }
  taken.map { |c| Note(name: c.name, text: "/#{c.name} is a command and a skill: the command wins") }
end

## A command from its file: an optional front matter with `description`, then the prompt.
def parse(path: String, name: String, text: String, source: String) -> Result[Command]
  return error("#{path}: over #{MAX_BYTES} bytes") if text.bytesize > MAX_BYTES

  body = text.strip
  description = ""
  if text.replace(String.from_code(0xFEFF), "").strip.start_with?("---")
    case Skills.parse(text)
      ok(front) ->
        for key in front.fields.keys
          return error("#{path}: unknown key #{key}: only description") if key != "description"
        end

        body = front.body
        description = front.fields.get("description").unwrap_or("")
      error(e) -> return error("#{path}: #{e.message}")
    end
  end

  return error("#{path}: the command has no text") if body.empty?

  ok(Command(name: name, description: description, body: body, source: source))
end

private

def in_folder(before: Loaded, dir: String, source: String) -> Loaded
  loaded = before
  nothing: List[String] = []
  files = Dir.list(dir).unwrap_or(nothing).select { |f| f.end_with?(".md") }.sort
  for file in files
    name = file.slice(0, file.length - 3)
    path = "#{dir}/#{file}"
    kind = case File.stat(path)
      ok(info) -> info.kind
      error(_) -> ""
    end

    if not named?(name) or kind != "file"
      skipped = Note(text: "#{path}: skipped, not a command (a file NAME.md, NAME of a-z, 0-9, - and _)")
      loaded = loaded.with(warnings: loaded.warnings.push(skipped))
      next
    end

    if CLIENT_COMMANDS.include?(name)
      taken = Note(text: "#{path}: skipped, /#{name} is a command of the clients")
      loaded = loaded.with(warnings: loaded.warnings.push(taken))
      next
    end

    loaded = with_file(loaded, path, name, source)
  end

  loaded
end

# `loaded` with the command of one file, or with its error in `broken`; either replaces a command of that name.
def with_file(loaded: Loaded, path: String, name: String, source: String) -> Loaded
  warnings = loaded.warnings
  for replaced in (loaded.commands.select { |c| c.name == name })
    warnings = warnings.push(Note(name: name, text: "#{path} replaces the #{replaced.source} command /#{name}"))
  end

  others = loaded.commands.select { |c| c.name != name }
  read = case File.read_text(path)
    ok(text) -> parse(path, name, text, source)
    error(e) -> error("#{path}: #{e.message}")
  end

  case read
    ok(command) ->
      broken = loaded.broken.select { |key, _| key != name }
      loaded.with(commands: others.push(command), broken: broken, warnings: warnings)
    error(e) -> loaded.with(commands: others, broken: loaded.broken.put(name, e.message), warnings: warnings)
  end
end

def named?(name: String) -> Bool
  not name.empty? and not name.start_with?("-") and name.split("").all? { |c| NAME_CHARS.include?(c) }
end
