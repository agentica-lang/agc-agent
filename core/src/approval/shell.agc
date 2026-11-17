## What a `bash` command asks for, found as OpenCode's shell tool finds it (v1.19.5,
## packages/opencode/src/tool/shell.ts, MIT, see THIRD_PARTY_NOTICES): each command of the line (tree-sitter-bash, the
## `bash` package) by its text, and the folders outside the session folder that a command of `FILES` names
## (`external_directory`, `FOLDER/*`). A path with `$` or a backtick is not followed. `cd` changes nothing for the
## commands after it: paths are read from the session folder.

import Bash from "pkg/bash/bash"
import Sandbox from "../tools/sandbox"

EXTERNAL = "external_directory"

struct Resource
  tool: String
  pattern: String
  ## The pattern is the exact text, not a glob (`Approval.Rule.literal`). An asked command that is literal is allowed
  ## by an exact "always" answer only, not by a prefix (`echo evil >> f` by `echo *`).
  literal: Bool = false
end

struct Scan
  ## False when tree-sitter-bash could not read the line or misread it (`Bash.Parsed`): commands may be missing.
  clear: Bool
  asked: List[Resource]
  ## What an "always" answer allows: for each command of a program of `PREFIXES` its name and ` *` (`ls *`), else its
  ## whole text. The whole text too when the command does not start with its name (`FOO=1 rm x`), when the line has
  ## a redirection anywhere (`echo hi > f`, `{ echo hi; } > f`), or when a word is not a plain word or a string or
  ## holds `$` or a backtick (`ls $(pwd)`).
  always: List[Resource]
end

def scan(root: String, command: String) -> Scan
  parsed = Bash.parse(command)
  return Scan(clear: false, asked: [], always: []) if not parsed.ok?

  found = Scan(clear: not parsed.unwrap!.error and not parsed.unwrap!.unclear, asked: [], always: [])
  redirected = command.include?(">") or command.include?("<")
  for c in parsed.unwrap!.commands
    tokens = c.words.select { |w| TOKENS.include?(w.kind) }.map { |w| w.text }
    name = tokens.take(1).join("")
    if FILES.include?(name)
      for folder in outside(root, name, tokens)
        found = added(found, Resource(tool: EXTERNAL, pattern: folder))
      end
    end

    if not CWD.include?(name)
      kept = always(c, redirected)
      asked = Resource(tool: "bash", pattern: c.text.strip, literal: kept.literal)
      found = found.with(asked: pushed(found.asked, asked), always: pushed(found.always, kept))
    end
  end

  found
end

private

TOKENS = ["command_name", "word", "string", "raw_string", "concatenation"]
CWD = ["cd", "chdir", "popd", "pushd"]
FILES = [
  "cd", "chdir", "popd", "pushd", "rm", "cp", "mv", "mkdir", "touch", "chmod", "chown", "cat", "head", "tail", "grep",
  "wc", "diff", "du",
]
# The programs that no argument makes run another program or write a file.
PREFIXES = ["cat", "echo", "grep", "ls", "pwd", "sleep", "tail", "head", "wc", "which", "diff", "du", "df"]
PLAIN = ["command_name", "word", "string", "raw_string"]

def added(found: Scan, r: Resource) -> Scan
  found.with(asked: pushed(found.asked, r), always: pushed(found.always, r))
end

def pushed(list: List[Resource], r: Resource) -> List[Resource]
  return list if list.include?(r)

  list.push(r)
end

def always(c: Bash.Command, redirected: Bool) -> Resource
  text = c.text.strip
  exact = Resource(tool: "bash", pattern: text, literal: true)
  name = c.words.take(1).map { |w| w.text }.join("")
  return exact if not PREFIXES.include?(name) or (text != name and not text.start_with?("#{name} "))
  return exact if redirected
  return exact if (c.words.any? { |w| not PLAIN.include?(w.kind) or w.text.include?("$") or w.text.include?("`") })

  Resource(tool: "bash", pattern: "#{name} *")
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
