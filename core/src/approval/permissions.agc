## Where the approval rules come from, and what a session allowed while it runs.
##
## Rules: the user's config file (`FINN_CONFIG`, else `$XDG_CONFIG_HOME/finn/config.json`, else
## `~/.config/finn/config.json`), `{"approvals": true, "allow": [...], "deny": [...]}` in the syntax of `Approval`,
## whose `approvals` turns the asking on (`FINN_APPROVALS` wins over it); and the project file `.finn/config.json` of
## the session folder, whose deny rules always count and whose allow rules count only in a folder of
## `FINN_TRUSTED_DIRS` (`:` between folders), since anyone who writes the project can write them. Its `approvals` is
## not read: a project cannot change the mode. The deny rules count with the asking off too.
##
## A session allows more by its answers: the same call (`allow_session`), the same command prefix for `bash`
## (`allow_prefix`: `git log`, `npm test`), or the whole tool (`allow_tool`); and in the accept-edits mode the edits of
## files run without asking. None of them reaches into `.git/`, and a `bash` command that the deny rules match or
## cannot clear (`bash_denial`) is never allowed through them. While a deny rule of `read_file` exists, only the same
## call is allowed again for `bash`: any command may read the file. They last as long as the server runs: a restart
## forgets them. Known limit: an option that writes is not seen, but for git's `--output`.
##
## The deny rules are checked statically, as far as the parser sees a command, so they do not confine `bash`: a program
## made as it runs (`ln -s /bin/rm r && ./r`), an interpreter running a file, a reader of a whole folder (`grep -r x .`),
## `cd secrets && cat key`, a link to a hidden file, a tool whose config runs programs (`git -c`, make or npm scripts)
## and options in another order than a narrow rule's are not seen. Use a sandbox.

import Shell from "pkg/shell/shell"
import Approval from "approval"
import Sandbox from "../tools/sandbox"

CONFIG_ENV = "FINN_CONFIG"
PROJECT_FILE = ".finn/config.json"
## The tools whose calls the accept-edits mode runs.
EDITS = ["write_file", "edit_file", "apply_patch"]
## Programs that run the command in their arguments, and interpreters: an answer allows only the same call.
RUNNERS = [
  "env", "xargs", "sh", "bash", "zsh", "dash", "ksh", "fish", "python", "python3", "node", "ruby", "perl", "sudo",
  "doas", "nice", "nohup", "timeout", "command", "time", "stdbuf", "chrt", "ionice", "setsid", "flock", "watch",
  "script",
]
## Programs that run the words after them as a command: a deny rule of `bash` that matches there matches a program.
LAUNCHERS = [
  "env", "xargs", "sh", "bash", "zsh", "dash", "ksh", "fish", "python", "python3", "node", "ruby", "perl", "sudo",
  "doas", "nice", "nohup", "timeout", "command", "time", "stdbuf", "chrt", "ionice", "setsid", "flock", "watch",
  "script", "eval", "exec", "builtin",
]
## Shells whose `-c` takes a script, checked as a command of its own.
SHELLS = ["sh", "bash", "zsh", "dash", "ksh", "fish"]
## The options of `find` whose next word is a program.
FIND_RUNS = ["-exec", "-execdir", "-ok", "-okdir"]
## The longest `bash` command checked against the deny rules: a longer one cannot be cleared.
MAX_CHECKED = 16_384
## Programs whose second word picks what they do: their prefix is two words.
TWO_WORDS = [
  "git", "npm", "pnpm", "yarn", "bun", "npx", "cargo", "go", "make", "docker", "kubectl", "pip", "poetry", "uv", "mix",
  "gh", "dotnet", "bundle", "rails",
]

struct Allows
  ## `tool\ntarget` of each call allowed again.
  exact: List[String] = []
  ## The words that start the `bash` commands allowed.
  prefixes: List[List[String]] = []
  tools: List[String] = []
  accept_edits: Bool = false
end

struct User
  rules: Approval.Rules
  asking: Bool
end

## What the deny rules say of a `bash` command (`bash_denial`).
enum Denial
  ## No deny rule matches it.
  Clear
  ## It cannot be cleared: it does not parse, is over MAX_CHECKED bytes, has a word that is not plain (a quote, a `$`,
  ## a glob) while a deny rule of `bash` or `read_file` exists, or a `bash` rule matches words that are not a program
  ## it runs (`git commit -m rm`, `echo rm`). It asks when the asking is on and is refused when it is off.
  Uncleared
  ## A `bash` rule matches a program it runs (the first word, by its name too: `/bin/rm`, or one after a program of
  ## LAUNCHERS, a shell's `-c` script, `eval` or `find -exec`), or a word names a file or the folder that a
  ## `read_file` rule hides (as given, after a `=`, its last name, or resolved against the session folder `root`).
  ## It is refused.
  Matched
end

## The user's config file: `FINN_CONFIG`, else the default file when it is there.
def config_path(read: Fn[String, Result[String]]) -> Optional[String]
  case read.call(CONFIG_ENV)
    ok(given) if not given.empty? -> return some(given)
    _ -> nil
  end

  case default_config(read)
    some(found) if File.stat(found).ok? -> some(found)
    _ -> none
  end
end

## The rules of the user's config file, none when the default file is not there; and whether calls that no rule
## allows ask: `switch` when given (`FINN_APPROVALS`), else the file's `approvals`, else not.
def user_rules(read: Fn[String, Result[String]], switch: Optional[Bool]) -> Result[User]
  file = try user_file(read)
  rules = try parsed_rules(file.path, file.file)
  ok(User(rules: rules, asking: switch.unwrap_or(file.file.approvals.unwrap_or(false))))
end

## `rules` with those of the project file of `root`: its deny rules, and its allow rules when `root` is `trusted`. A
## broken file in a folder that is not trusted is ignored with a warning, so a repository cannot stop its sessions.
def with_project(rules: Approval.Rules, root: String, trusted: Bool) -> Result[Approval.Rules]
  path = "#{root}/#{PROJECT_FILE}"
  return ok(rules) if not File.stat(path).ok?

  read = rules_of(path)
  case read
    error(e) if not trusted ->
      IO.warn("#{e.message}; its rules are ignored")
      return ok(rules)
    _ -> nil
  end

  project = try read
  allow = rules.allow
  if trusted
    allow = allow + project.allow
  end

  ok(Approval.Rules(allow: allow, deny: rules.deny + project.deny))
end

## The words a prefix answer would allow for a `bash` command: its first word, or two for `TWO_WORDS`; none for another
## tool, a command that is not one simple command, one of `RUNNERS`, or one of `TWO_WORDS` whose second word is
## missing or an option (`git -c a=b log`), which an answer allows only as the same call.
def prefix(tool: String, target: String) -> Optional[List[String]]
  return none if tool != "bash"

  script = Shell.parse(target).unwrap_or(Shell.Script(pipelines: []))
  return none if script.pipelines.size != 1 or script.pipelines[0].commands.size != 1

  words = Shell.argv(script.pipelines[0].commands[0])
  return none if words.empty? or RUNNERS.include?(words[0])
  return some(words.take(1)) if not TWO_WORDS.include?(words[0])
  return none if words.size < 2 or words[1].start_with?("-")

  some(words.take(2))
end

## Whether the session's answers or mode allow the call (in the session folder `root`), under the deny rules of
## `rules`.
def allows?(allows: Allows, rules: Approval.Rules, tool: String, target: String, root: String) -> Bool
  return false if Approval.protected?(tool, target)
  return false if tool == "bash" and bash_denial(rules, root, target) != Denial.Clear
  return true if allows.exact.include?(key(tool, target))
  return false if (tool == "bash" and rules.deny.any? { |rule| rule.tool == "read_file" })
  return true if allows.tools.include?(tool)
  return true if allows.accept_edits and EDITS.include?(tool)

  tool == "bash" and not allows.prefixes.empty? and prefixed?(allows.prefixes, target, root, Approval.guarded?(rules))
end

## What the deny rules say of the `bash` command `target` run in `root`.
def bash_denial(rules: Approval.Rules, root: String, target: String) -> Denial
  bash = Approval.bash_denies(rules)
  started = bash.select { |c| not c.start.empty? }
  checks = Checks(rules: rules, root: root, bash: bash, started: started, reads: Approval.read_rules?(rules))
  return Denial.Clear if checks.bash.empty? and not checks.reads
  return Denial.Uncleared if target.bytesize > MAX_CHECKED

  script_denial(checks, target)
end

## What an answer adds; `allow_prefix` without a prefix allows the same call.
def answered(allows: Allows, decision: String, tool: String, target: String) -> Allows
  case decision
    "allow_session" -> allows.with(exact: allows.exact.push(key(tool, target)))
    "allow_tool" -> allows.with(tools: allows.tools.push(tool))
    "allow_prefix" ->
      case prefix(tool, target)
        some(words) -> allows.with(prefixes: allows.prefixes.push(words))
        none -> allows.with(exact: allows.exact.push(key(tool, target)))
      end

    _ -> allows
  end
end

private

# The deny rules a check needs, read once.
struct Checks
  rules: Approval.Rules
  root: String
  bash: List[Approval.Compiled]
  ## Those of `bash` that do not start with `*`: one that does matches a tail only when it matches the whole command.
  started: List[Approval.Compiled]
  reads: Bool
end

# Optional, so a file without rules (only `providers`) reads.
struct RulesFile
  approvals: Optional[Bool] = none
  allow: Optional[List[String]] = none
  deny: Optional[List[String]] = none
end

struct UserFile
  path: String
  file: RulesFile
end

def key(tool: String, target: String) -> String = "#{tool}\n#{target}"

# None without a home folder.
def default_config(read: Fn[String, Result[String]]) -> Optional[String]
  case read.call("XDG_CONFIG_HOME")
    ok(base) if not base.empty? -> some("#{base}/finn/config.json")
    _ ->
      case read.call("HOME")
        ok(home) if not home.empty? -> some("#{home}/.config/finn/config.json")
        _ -> none
      end
  end
end

def user_file(read: Fn[String, Result[String]]) -> Result[UserFile]
  case config_path(read)
    some(found) -> ok(UserFile(path: found, file: try file_of(found)))
    none -> ok(UserFile(path: "", file: RulesFile()))
  end
end

def rules_of(path: String) -> Result[Approval.Rules] = parsed_rules(path, try file_of(path))

def file_of(path: String) -> Result[RulesFile]
  text = try File.read_text(path)
  case JSON.decode(text, RulesFile)
    ok(found) -> ok(found)
    error(e) -> error("#{path}: #{e.message}")
  end
end

def parsed_rules(path: String, parsed: RulesFile) -> Result[Approval.Rules]
  case Approval.parse_rules(parsed.allow.unwrap_or([]), parsed.deny.unwrap_or([]))
    ok(rules) -> ok(rules)
    error(e) -> error("#{path}: #{e.message}")
  end
end

# Every command starts with an allowed prefix or only reads; nothing writes through a redirection or runs in the
# background.
def prefixed?(prefixes: List[List[String]], target: String, root: String, guarded: Bool) -> Bool
  case Shell.parse(target)
    ok(script) ->
      script.pipelines.all? do |pipeline|
        (
          pipeline.join != some(Shell.Join.Background) and
          pipeline.commands.all? { |c| command_allowed?(prefixes, c, root, guarded) }
        )
      end

    error(_) -> false
  end
end

# Without `guarded`, a command that only reads inside `root` needs no prefix.
def command_allowed?(prefixes: List[List[String]], command: Shell.Command, root: String, guarded: Bool) -> Bool
  alone = Shell.Script(pipelines: [Shell.Pipeline(commands: [command])])
  inside = ->(path: String) { Sandbox.resolve(root, path).ok? }
  return true if not guarded and Shell.read_only?(alone, inside) == Shell.Verdict.Safe

  writes = command.redirects.any? do |r|
    case r
      Shell.Redirect.Out(_, path, _) -> path != "/dev/null"
      _ -> false
    end
  end

  words = Shell.argv(command)
  output = words.take(1) == ["git"] and words.any? { |w| w.start_with?("--output") }
  not writes and not output and prefixes.any? { |p| words.take(p.size) == p }
end

def script_denial(checks: Checks, text: String) -> Denial
  case Shell.parse(text)
    ok(script) ->
      commands = script.pipelines.flat_map { |p| p.commands }
      worst(commands.map { |c| command_denial(checks, c) })
    error(_) -> Denial.Uncleared
  end
end

def worst(found: List[Denial]) -> Denial
  return Denial.Matched if found.include?(Denial.Matched)
  return Denial.Uncleared if found.include?(Denial.Uncleared)

  Denial.Clear
end

# A shell's `-c` script and the words of `eval` are a command of their own; the other words are checked here.
def command_denial(checks: Checks, command: Shell.Command) -> Denial
  words = Shell.argv(command)
  program = name_of(words.take(1).join(""))
  inner: List[Denial] = []
  checked = words
  at = words.index("-c")
  if SHELLS.include?(program) and at.some? and at.unwrap! + 1 < words.size
    inner = [script_denial(checks, words[at.unwrap! + 1])]
    checked = words.take(at.unwrap! + 1) + words.drop(at.unwrap! + 2)
  elsif program == "eval"
    inner = [script_denial(checks, words.drop(1).join(" "))]
    checked = words.take(1)
  end

  paths = redirect_paths(command)
  unplain = (checked + paths).any? { |word| word.empty? or word.include?(" ") or not Approval.plain?(word) }
  found = inner + [tails_denial(checks, checked), names_denial(checks, checked + paths)]
  if unplain
    found = found.push(Denial.Uncleared)
  end

  worst(found)
end

def redirect_paths(command: Shell.Command) -> List[String]
  paths = command.redirects.map do |r|
    case r
      Shell.Redirect.Out(_, path, _) -> path
      Shell.Redirect.In(path) -> path
      _ -> ""
    end
  end

  paths.select { |path| not path.empty? }
end

# A tail of the words, its first word also by its name, and also with one more argument (as `xargs` adds), matches a
# deny rule of `bash`: at a program it runs, or elsewhere.
def tails_denial(checks: Checks, words: List[String]) -> Denial
  return Denial.Clear if checks.bash.empty?

  # A tail is joined whole only when its first words start like a rule, so a long command is checked in linear time.
  reach = checks.bash.map { |c| c.start.length }.max.unwrap_or(0) + 1
  found = Denial.Clear
  for from in 0...words.size
    denies = checks.started
    if from == 0
      denies = checks.bash
    end

    ahead = (from...[from + reach, words.size].min.unwrap!).to_a.map { |i| words[i] }
    starts = [ahead, [name_of(ahead[0])] + ahead.drop(1)].map { |head| head.join(" ") }
    next if (not starts.any? { |head| Approval.compiled_start?(denies, head) })
    # Once a match elsewhere was found, only one at a program changes the answer.
    next if found == Denial.Uncleared and not runs?(words, from)

    tail = words.drop(from)
    texts = [tail.join(" "), ([name_of(tail[0])] + tail.drop(1)).join(" ")]
    hit = texts.any? { |t| Approval.compiled_denied?(denies, t) or Approval.compiled_denied?(denies, "#{t} x") }

    next if not hit
    return Denial.Matched if runs?(words, from)

    found = Denial.Uncleared
  end

  found
end

# Whether the word at `from` is a program the command runs.
def runs?(words: List[String], from: Int) -> Bool
  program = name_of(words[0])
  from == 0 or LAUNCHERS.include?(program) or (program == "find" and FIND_RUNS.include?(words[from - 1]))
end

def name_of(word: String) -> String = word.split("/").last

def names_denial(checks: Checks, words: List[String]) -> Denial
  return Denial.Clear if not checks.reads

  hidden = words.any? do |word|
    value = word.split("=").last
    names = [word, value, value.replace("./", ""), name_of(value)] + located(checks.root, value)
    names.any? do |name|
      not name.empty? and (Approval.read_denied?(checks.rules, name) or Approval.folder_denied?(checks.rules, name))
    end
  end

  if hidden
    Denial.Matched
  else
    Denial.Clear
  end
end

# The path relative to `root` that `path` names, with `.` and `..` taken away without reading the disk; none outside.
def located(root: String, path: String) -> List[String]
  full = path
  if not path.start_with?("/")
    full = "#{root}/#{path}"
  end

  parts: List[String] = []
  for part in full.split("/")
    if part == ".."
      parts = parts.take([parts.size - 1, 0].max.unwrap!)
    elsif part != "" and part != "."
      parts = parts.push(part)
    end
  end

  absolute = "/#{parts.join("/")}"
  return [] if not Sandbox.inside?(root, absolute) or absolute == root

  [Sandbox.relative(root, absolute)]
end
