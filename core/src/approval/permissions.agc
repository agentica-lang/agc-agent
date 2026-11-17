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
## files run without asking. None of them reaches into `.git/` or allows a call a deny rule matches. A prefix allows
## only a plain command (`Approval.plain?`): one program and its words. They last as long as the server runs: a restart
## forgets them. Known limit: an option that writes is not seen, but for git's `--output`.

import Approval from "approval"

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
## tool, a command that is not plain (`Approval.plain?`) or starts with an assignment (`LANG=C ls`), one of `RUNNERS`,
## or one of `TWO_WORDS` whose second word is missing or an option (`git -c a=b log`), which an answer allows only as
## the same call.
def prefix(tool: String, target: String) -> Optional[List[String]]
  return none if tool != "bash" or not Approval.plain?(target)

  words = words_of(target)
  return none if words.empty? or RUNNERS.include?(words[0]) or words[0].include?("=")
  return some(words.take(1)) if not TWO_WORDS.include?(words[0])
  return none if words.size < 2 or words[1].start_with?("-")

  some(words.take(2))
end

## Whether the session's answers or mode allow the call, under the deny rules of `rules`.
def allows?(allows: Allows, rules: Approval.Rules, tool: String, target: String) -> Bool
  return false if Approval.protected?(tool, target) or Approval.denied?(rules, tool, target)
  return true if allows.exact.include?(key(tool, target))
  return true if allows.tools.include?(tool)
  return true if allows.accept_edits and EDITS.include?(tool)

  tool == "bash" and prefixed?(allows.prefixes, target)
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

# A plain command that starts with an allowed prefix; git's `--output` writes.
def prefixed?(prefixes: List[List[String]], target: String) -> Bool
  words = words_of(target)
  output = words.take(1) == ["git"] and words.any? { |w| w.start_with?("--output") }
  Approval.plain?(target) and not output and prefixes.any? { |p| words.take(p.size) == p }
end

def words_of(command: String) -> List[String] = command.replace("\t", " ").split(" ").select { |w| w != "" }
