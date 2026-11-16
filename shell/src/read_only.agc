## Whether a parsed command only reads. Each simple command is checked by its name, its options and its arguments.

import Parse from "parse"

enum Verdict
  ## It only reads, inside the session folder.
  Safe
  ## It cannot be told: a command not known, an option or a path it does not check. Ask.
  Unknown(String)
  ## It writes a file or runs a program.
  Writes(String)
end

def read_only?(script: Parse.Script, root: String) -> Verdict
  for pipeline in script.pipelines
    return Verdict.Unknown("a command in the background") if pipeline.join == some(Parse.Join.Background)

    for command in pipeline.commands
      verdict = command_verdict(command, root)
      return verdict if verdict != Verdict.Safe
    end
  end

  Verdict.Safe
end

private

NULL = "/dev/null"
SAFE = [
  "ls", "cat", "head", "tail", "wc", "grep", "rg", "find", "sed", "awk", "sort", "uniq", "cut", "tr", "diff", "file",
  "stat", "pwd", "echo", "which", "git", "cd",
]

## Programs that run what they are given: never safe, whatever follows.
RUNNERS = ["xargs", "env", "sh", "bash", "zsh", "eval", "exec", "sudo", "time", "nohup", "timeout", "nice", "command"]
GIT_SAFE = ["status", "log", "diff", "show", "branch", "rev-parse"]
## Commands whose options cannot write or run anything, so a glob that expands to `-x` names is harmless.
GLOB_ANYWHERE = ["ls", "cat", "head", "tail", "wc", "stat", "echo", "grep", "cut", "tr"]
FIND_WRITES = ["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls"]
SED_FLAGS = "nEsuz"
SED_WRITES = "wWerR"
AWK_WRITES = [">", "|", "system", "getline", "@", "close", "fflush"]
GIT_WRITES = ["--output", "--ext-diff", "--textconv", "--exec", "--paginate"]
GIT_BRANCH_OPTIONS = ["-a", "-r", "-v", "-vv", "--all", "--remotes", "--list", "--show-current", "--verbose"]

def command_verdict(command: Parse.Command, root: String) -> Verdict
  for redirect in command.redirects
    verdict = redirect_verdict(redirect, root)
    return verdict if verdict != Verdict.Safe
  end

  name = command.words[0]
  args = Parse.argv(command).drop(1)
  return Verdict.Writes("#{name.text} runs other programs") if RUNNERS.include?(name.text)
  return Verdict.Unknown("#{name.text} is not a known read-only command") if name.glob or not SAFE.include?(name.text)

  for word in command.words.drop(1)
    verdict = glob_verdict(name.text, word)
    return verdict if verdict != Verdict.Safe
  end

  return git(args, root) if name.text == "git"

  skipped = pattern_at(name.text, args)
  for i in 0...args.size
    if i != skipped and not inside?(args[i], root)
      return Verdict.Unknown("#{args[i].inspect} may name a path outside the session folder")
    end
  end

  options(name.text, args)
end

# The index of the script of sed or awk, or the pattern of grep or rg, which is no path; -1 for the others, or when
# an option (`-e`, `-f`) moves the pattern.
def pattern_at(name: String, args: List[String]) -> Int
  return -1 if not ["sed", "awk", "grep", "rg"].include?(name)

  moved = args.any? do |word|
    word.start_with?("--file") or word.start_with?("--regexp") or short?(word, "e") or short?(word, "f")
  end

  return -1 if moved and name != "awk"

  for i in 0...args.size
    after_f = name == "awk" and i > 0 and args[i - 1] == "-F"
    return i if not args[i].start_with?("-") and not after_f
  end

  -1
end

def redirect_verdict(redirect: Parse.Redirect, root: String) -> Verdict
  case redirect
    Parse.Redirect.ErrToOut -> Verdict.Safe
    Parse.Redirect.Out(_, path, _) if path == NULL -> Verdict.Safe
    Parse.Redirect.Out(_, path, _) -> Verdict.Writes("it writes #{path}")
    Parse.Redirect.In(path) if inside?(path, root) -> Verdict.Safe
    Parse.Redirect.In(path) -> Verdict.Unknown("it reads #{path}")
  end
end

# A glob may expand to any name of the folder, `-delete` too, unless it starts with plain text other than `-`; `.*`
# may give `..`.
def glob_verdict(name: String, word: Parse.Word) -> Verdict
  return Verdict.Safe if not word.glob
  return Verdict.Unknown("the glob #{word.text} may reach a parent folder") if dot_glob?(word.text)
  return Verdict.Safe if GLOB_ANYWHERE.include?(name)
  return Verdict.Safe if not "*?[-".include?(word.text.slice(0, 1))

  Verdict.Unknown("the glob #{word.text} may expand to an option of #{name}")
end

def dot_glob?(text: String) -> Bool
  text.split("/").any? { |part| part.start_with?(".") and "*?[".split("").any? { |c| part.include?(c) } }
end

# A path inside `root`: relative and without `..`, or absolute below `root`; `/dev/null`; an option word with no `/`.
def inside?(word: String, root: String) -> Bool
  return true if word == NULL
  return false if (word.split("/").any? { |part| part == ".." or part.end_with?("=..") })
  return false if word.include?("/..") or word.start_with?("..")
  return false if word.start_with?("~")

  return word == root or word.start_with?("#{root}/") if word.start_with?("/")

  not (word.start_with?("-") and word.include?("/"))
end

def options(name: String, args: List[String]) -> Verdict
  case name
    "cd" if args.size != 1 or args[0].start_with?("-") -> Verdict.Unknown("cd without one folder")
    "find" if (args.any? { |word| FIND_WRITES.include?(word) }) -> Verdict.Writes("find runs or deletes")
    "sed" -> sed(args)
    "awk" -> awk(args)
    "sort" if (args.any? { |word| word.start_with?("--output") or word.start_with?("--compress") or short?(word, "o") }) ->
      Verdict.Writes("sort -o writes a file")
    "uniq" if ((args.select { |word| not word.start_with?("-") }).size > 1) ->
      Verdict.Writes("uniq writes its second file")
    "rg" if (args.any? { |word| word.start_with?("--pre") or word == "--search-zip" or short?(word, "z") }) ->
      Verdict.Writes("rg runs a preprocessor")
    "file" if (args.any? { |word| word == "--compile" or short?(word, "C") }) -> Verdict.Writes("file -C writes")
    _ -> Verdict.Safe
  end
end

# A short option word (`-ro`) with the letter `letter`.
def short?(word: String, letter: String) -> Bool
  word.start_with?("-") and not word.start_with?("--") and word.include?(letter)
end

# `sed -n SCRIPT FILE...`: options only of `SED_FLAGS` with `n` among them (no `-i`, `-e`, `-f`), and a script with
# none of the commands that write, run or read a file.
def sed(args: List[String]) -> Verdict
  options = args.select { |word| word.start_with?("-") }
  others = args.select { |word| not word.start_with?("-") }
  return Verdict.Unknown("sed without -n") if (not options.any? { |word| word.include?("n") })
  if (not options.all? { |word| word.length > 1 and only?(word.slice(1, word.length - 1), SED_FLAGS) })
    return Verdict.Unknown("a sed option other than -n, -E, -s, -u, -z")
  end

  return Verdict.Unknown("sed without a script") if others.empty?
  return Verdict.Writes("the sed script may write, run or read a file") if writes?(others[0], SED_WRITES.split(""))

  Verdict.Safe
end

# `awk [-F SEP] SCRIPT FILE...`: a script with no output redirection, pipe, `system` or `getline`.
def awk(args: List[String]) -> Verdict
  rest = args
  if not rest.empty? and rest[0] == "-F"
    rest = rest.drop(2)
  elsif not rest.empty? and rest[0].start_with?("-F")
    rest = rest.drop(1)
  end

  return Verdict.Unknown("an awk option other than -F") if rest.empty? or rest[0].start_with?("-")
  return Verdict.Writes("the awk script may write or run") if writes?(rest[0], AWK_WRITES)

  Verdict.Safe
end

def writes?(script: String, parts: List[String]) -> Bool = parts.any? { |part| script.include?(part) }

def only?(text: String, allowed: String) -> Bool = text.split("").all? { |c| allowed.include?(c) }

# A safe subcommand right after `git` (so no `-c` or `-C` before it), and no option that writes a file or runs a
# program; `--no-index` reads any file.
def git(args: List[String], root: String) -> Verdict
  return Verdict.Unknown("git without a known read-only subcommand first") if args.empty?
  return Verdict.Unknown("git #{args[0]} is not a known read-only subcommand") if not GIT_SAFE.include?(args[0])

  rest = args.drop(1)
  for word in rest
    if (GIT_WRITES.any? { |option| word == option or word.start_with?("#{option}=") })
      return Verdict.Writes("git #{word} writes or runs")
    end

    return Verdict.Unknown("git --no-index reads any file") if word.start_with?("--no-index")
    if word.start_with?("/") and not word.start_with?("#{root}/")
      return Verdict.Unknown("#{word.inspect} is outside the session folder")
    end

    return Verdict.Unknown("#{word.inspect} may name a path outside") if word.start_with?("-") and word.include?("/")
  end

  if (args[0] == "branch" and not rest.all? { |word| GIT_BRANCH_OPTIONS.include?(word) })
    return Verdict.Writes("git branch with a name or option may change branches")
  end

  Verdict.Safe
end
