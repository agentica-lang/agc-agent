## What a `bash` command asks for, found as OpenCode's shell tool finds it (v1.19.5, packages/opencode/src/tool/shell.ts,
## MIT, see THIRD_PARTY_NOTICES): each command of the line (tree-sitter-bash, the `bash` package) by its text, and the
## folders outside the session folder that a command of `FILES` names (`external_directory`, `FOLDER/*`). A path with
## `$` or a backtick is not followed. `cd` changes nothing for the commands after it: paths are read from the session
## folder.

import Bash from "pkg/bash/bash"
import Arity from "arity"
import Sandbox from "../tools/sandbox"

EXTERNAL = "external_directory"

struct Resource
  tool: String
  pattern: String
end

struct Scan
  ## False when tree-sitter-bash could not read the line or misread it (`Bash.Parsed`): commands may be missing.
  clear: Bool
  asked: List[Resource]
  ## What an "always" answer allows: for each command its first words (`Arity`) and ` *`, or its whole text when it
  ## runs another program (`RUNNERS`) or when those words hold an option (`git -c x=y log`).
  always: List[Resource]
end

def scan(root: String, command: String) -> Scan
  parsed = Bash.parse(command)
  return Scan(clear: false, asked: [], always: []) if not parsed.ok?

  found = Scan(clear: not parsed.unwrap!.error and not parsed.unwrap!.unclear, asked: [], always: [])
  for c in parsed.unwrap!.commands
    tokens = c.words.select { |w| TOKENS.include?(w.kind) }.map { |w| w.text }
    name = tokens.take(1).join("")
    if FILES.include?(name)
      for folder in outside(root, name, tokens)
        found = added(found, Resource(tool: EXTERNAL, pattern: folder))
      end
    end

    if not CWD.include?(name)
      text = c.text.strip
      found = found.with(asked: pushed(found.asked, Resource(tool: "bash", pattern: text)))
      found = found.with(always: pushed(found.always, Resource(tool: "bash", pattern: always(text, tokens))))
    end
  end

  found
end

private

TOKENS = ["command_name", "word", "string", "raw_string", "concatenation"]
CWD = ["cd", "chdir", "popd", "pushd"]
FILES = ["cd", "chdir", "popd", "pushd", "rm", "cp", "mv", "mkdir", "touch", "chmod", "chown", "cat"]
RUNNERS = [
  "env", "xargs", "sh", "bash", "zsh", "dash", "ksh", "fish", "python", "python3", "node", "ruby", "perl", "sudo",
  "doas", "nice", "nohup", "timeout", "command", "time", "stdbuf", "chrt", "ionice", "setsid", "flock", "watch",
  "script", "exec", "eval", "builtin",
]

def added(found: Scan, r: Resource) -> Scan
  found.with(asked: pushed(found.asked, r), always: pushed(found.always, r))
end

def pushed(list: List[Resource], r: Resource) -> List[Resource]
  return list if list.include?(r)

  list.push(r)
end

def always(text: String, tokens: List[String]) -> String
  return text if tokens.empty? or RUNNERS.include?(tokens[0])

  words = Arity.prefix(tokens)
  output = tokens[0] == "git" and tokens.any? { |t| t.start_with?("--output") }
  return text if (output or words.any? { |w| w.start_with?("-") })

  "#{words.join(" ")} *"
end

# The `FOLDER/*` globs of the paths outside `root` that the arguments of `name` give.
def outside(root: String, name: String, tokens: List[String]) -> List[String]
  args = tokens.drop(1).select { |a| not a.start_with?("-") and not (name == "chmod" and a.start_with?("+")) }
  folders: List[String] = []
  for arg in args
    for path in resolved(root, arg)
      if not Sandbox.inside?(root, path)
        folder = path
        if not CWD.include?(name) and not directory?(path)
          folder = Sandbox.parent(path)
        end

        folders = folders.push(glob_of(folder))
      end
    end
  end

  folders
end

def directory?(path: String) -> Bool
  case File.stat(path)
    ok(info) -> info.kind == "directory"
    error(_) -> false
  end
end

# The absolute path an argument names, up to its first glob character; none when it is dynamic (`$`, a backtick).
def resolved(root: String, arg: String) -> List[String]
  text = home(unquoted(arg))
  cut = text.split("").find_index { |c| ["*", "?", "["].include?(c) }.unwrap_or(text.length)
  file = text.slice(0, cut)
  return [] if file == "" or file.include?("$") or file.include?("`")

  absolute = file
  if not file.start_with?("/")
    absolute = "#{root}/#{file}"
  end

  case Path.resolve(absolute)
    ok(path) if path.length > 1 and path.end_with?("/") -> [path.slice(0, path.length - 1)]
    ok(path) -> [path]
    error(_) -> []
  end
end

def unquoted(text: String) -> String
  return text if text.length < 2

  first = text.slice(0, 1)
  return text.slice(1, text.length - 2) if (first == "\"" or first == "'") and text.end_with?(first)

  text
end

def home(text: String) -> String
  return text if text != "~" and not text.start_with?("~/")

  case System.env("HOME")
    ok(dir) -> "#{dir}#{text.slice(1, text.length - 1)}"
    error(_) -> text
  end
end

def glob_of(folder: String) -> String
  return "/*" if folder == "/"

  "#{folder}/*"
end
