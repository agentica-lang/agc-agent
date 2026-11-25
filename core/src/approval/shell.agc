## What a `bash` command asks for, found as OpenCode's shell tool finds it (v1.19.5,
## packages/opencode/src/tool/shell.ts, MIT, see THIRD_PARTY_NOTICES): each command of the line (tree-sitter-bash, the
## `bash` package) by its text, and the folders outside the session folder that a command of `FILES` names
## (`external_directory`, `FOLDER/*`). A path with `$` or a backtick is not followed. `cd` changes nothing for the
## commands after it: paths are read from the session folder.

import Bash from "pkg/bash/bash"
import Sandbox from "../tools/sandbox"

EXTERNAL = "external_directory"
READ = "read_file"
# The programs whose files are checked as `read_file` targets too (a `.env` file asks), `cp` since its copy is read.
# Best effort: a glob, `$`, `--opt=FILE`, a link or a folder read whole is not seen.
READS = ["cat", "head", "tail", "grep", "wc", "diff", "cp"]
DIGITS = "0123456789"
# The options that give `grep` its pattern, and `cp` its target folder.
PATTERN_GIVEN = ["--regexp", "--file"]
TARGET_GIVEN = ["-t", "--target-directory"]

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

## The `external_directory` glob of a file tool's target: the folder of a file, or the folder itself, when the target
## (as the tool shows it: relative to `root` inside it, absolute outside) is outside `root`.
def external(root: String, target: String) -> Optional[String]
  return none if not target.start_with?("/") or Sandbox.inside?(root, target)

  folder = target
  if not directory?(target)
    folder = Sandbox.parent(target)
  end

  some(glob_of(folder))
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

      if READS.include?(name)
        for path in read_args(name, tokens).flat_map { |arg| resolved(root, arg) }
          read = Resource(tool: READ, pattern: read_target(root, path), literal: true)
          found = found.with(asked: pushed(found.asked, read))
        end
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
PREFIXES = ["echo", "ls", "pwd", "sleep", "which", "df"]
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
  return exact if c.words.any? { |w| not PLAIN.include?(w.kind) or w.text.include?("$") or w.text.include?("`") }

  Resource(tool: "bash", pattern: "#{name} *")
end

# The `FOLDER/*` globs of the paths outside `root` that the arguments of `name` give.
def outside(root: String, name: String, tokens: List[String]) -> List[String]
  folders: List[String] = []
  for path in paths(root, name, tokens)
    if not Sandbox.inside?(root, path)
      folder = path
      if not CWD.include?(name) and not directory?(path)
        folder = Sandbox.parent(path)
      end

      folders = folders.push(glob_of(folder))
    end
  end

  folders
end

# The files that a command of `READS` reads: its words but options and numbers (`head -n 5`); nor the first one of
# `grep`, its pattern, unless an option gives the pattern or `--` ends the options; nor the last one of `cp`, which it
# writes, unless `-t` names that folder. A word too many only asks once more.
def read_args(name: String, tokens: List[String]) -> List[String]
  options = tokens.drop(1).select { |w| w.start_with?("-") }
  given = options.any? { |o| given?(o) }
  words = tokens.drop(1).select { |w| not w.start_with?("-") and not w.split("").all? { |c| DIGITS.include?(c) } }
  return words.drop(1) if name == "grep" and not given and not options.include?("--")
  if name == "cp" and not options.any? { |o| TARGET_GIVEN.any? { |p| o.start_with?(p) } }
    return words.take(words.size - 1)
  end

  words
end

# Whether a `grep` option gives the pattern: `-e`, `-f` or their long names, alone or in a group of short options.
def given?(option: String) -> Bool
  return PATTERN_GIVEN.any? { |p| option.start_with?(p) } if option.start_with?("--")

  option.include?("e") or option.include?("f")
end

# The target of `read_file` for a path: relative to `root` inside it.
def read_target(root: String, path: String) -> String
  return Sandbox.relative(root, path) if Sandbox.inside?(root, path)

  path
end

# The paths that the arguments of `name` give, options left out.
def paths(root: String, name: String, tokens: List[String]) -> List[String]
  args = tokens.drop(1).select { |a| not a.start_with?("-") and not (name == "chmod" and a.start_with?("+")) }
  found: List[String] = []
  for arg in args
    found = found + resolved(root, arg)
  end

  found
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
