## Where the approval rules come from, and what a session allowed while it runs.
##
## Where the approval rules come from, in their order (the last that matches wins): `Approval.DEFAULTS`; the user's
## config file (`FINN_CONFIG`, else `$XDG_CONFIG_HOME/finn/config.json`, else `~/.config/finn/config.json`),
## `{"approvals": true, "permission": [...]}` in the syntax of `Approval`, whose `approvals` turns the asking on
## (`FINN_APPROVALS` wins over it); and the project file `.finn/config.json` of the session folder, whose rules count
## in a folder of `FINN_TRUSTED_DIRS` (`:` between folders) and elsewhere only its deny rules, since anyone who writes
## the project can write them. Its `approvals` is not read: a project cannot change the mode. The deny rules count with the asking off too.
##
## A session allows more by its answers: the same call (`allow_session`), what an "always" answer allows for `bash`
## (`allow_prefix`, `Shell.Scan.always`: `git log *`, `npm run dev *`), or the whole tool (`allow_tool`); and in the
## accept-edits mode the edits of files run without asking. None of them reaches into `.git/` or allows a call a rule
## denies. They last as long as the server runs: a restart forgets them.

import Approval from "approval"
import Shell from "shell"
import Spec from "../tools/spec"

CONFIG_ENV = "FINN_CONFIG"
PROJECT_FILE = ".finn/config.json"
## The tools whose calls the accept-edits mode runs.
EDITS = ["write_file", "edit_file", "apply_patch"]

struct Allows
  ## `tool\ntarget` of each call allowed again.
  exact: List[String] = []
  ## The allow rules of "always" answers.
  rules: List[Approval.Rule] = []
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

## `rules` with those of the project file of `root` after them: all of them when `root` is `trusted`, else only its deny
## rules, which cannot weaken the user's (an `ask` after a deny would win). A broken file in a folder that is not trusted
## is ignored with a warning, so a repository cannot stop its sessions.
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

  project = (try read).all.select { |rule| trusted or rule.action == Spec.Verdict.Deny }
  ok(Approval.Rules(all: rules.all + project))
end

## What an "always" answer would allow for a `bash` command in `root`; none for another tool or a command that
## tree-sitter-bash cannot read clearly, which an answer allows only as the same call.
def prefix(root: String, tool: String, target: String) -> Optional[List[Shell.Resource]]
  return none if tool != "bash"

  scan = Shell.scan(root, target)
  return none if not scan.clear or scan.always.empty?

  some(scan.always)
end

## Whether the session's answers or mode allow the call, under the rules: each part of a `bash` command must be allowed
## by a rule or an "always" answer.
def allows?(allows: Allows, rules: Approval.Rules, root: String, tool: String, target: String) -> Bool
  return false if Approval.protected?(tool, target)
  return false if Approval.decide(rules, root, tool, target, false) == Spec.Verdict.Deny
  return true if allows.exact.include?(key(tool, target))
  return true if allows.tools.include?(tool)
  return true if allows.accept_edits and EDITS.include?(tool)
  return false if tool != "bash"

  scan = Shell.scan(root, target)
  answered = Approval.Rules(all: allows.rules)
  allowed = ->(r: Shell.Resource) {
    by_rule = Approval.decide_one(rules, r.tool, r.pattern, r.tool == "bash") == Spec.Verdict.Allow
    by_rule or Approval.evaluate(answered, r.tool, r.pattern) == some(Spec.Verdict.Allow)
  }

  scan.clear and scan.asked.all? { |r| allowed.call(r) }
end

## What an answer adds; `allow_prefix` without a prefix allows the same call.
def answered(allows: Allows, decision: String, root: String, tool: String, target: String) -> Allows
  case decision
    "allow_session" -> allows.with(exact: allows.exact.push(key(tool, target)))
    "allow_tool" -> allows.with(tools: allows.tools.push(tool))
    "allow_prefix" ->
      case prefix(root, tool, target)
        some(found) ->
          added = found.map { |r|
            Approval.Rule(action: Spec.Verdict.Allow, tool: r.tool, pattern: r.pattern, literal: r.literal)
          }

          allows.with(rules: allows.rules + added)
        none -> allows.with(exact: allows.exact.push(key(tool, target)))
      end

    _ -> allows
  end
end

private

# Optional, so a file without rules (only `providers`) reads.
struct RulesFile
  approvals: Optional[Bool] = none
  permission: Optional[List[String]] = none
  # The keys before `permission`, refused so that their rules are not dropped in silence.
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
  if parsed.allow.some? or parsed.deny.some?
    moved = parsed.allow.unwrap_or([]).map { |r| "allow #{r}" } + parsed.deny.unwrap_or([]).map { |r| "deny #{r}" }
    return error("#{path}: \"allow\" and \"deny\" are now \"permission\": #{JSON.encode(moved)}")
  end

  case Approval.parse_rules(parsed.permission.unwrap_or([]))
    ok(rules) -> ok(rules)
    error(e) -> error("#{path}: #{e.message}")
  end
end
