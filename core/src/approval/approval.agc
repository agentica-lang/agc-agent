## What the agent may do without asking. A rule is `tool(pattern)`, where `*` in the pattern matches any text.
##
## For `bash`, a rule matches only a plain command (see `plain?`): any other command asks, whatever the rules say, so a
## deny rule of `bash` does not stop `rm x; true`, which asks. A `*` after a word matches only the end or a space and
## more text, so `git status*` matches `git status --short` and not `git statusx`. A rule is a convenience and not a
## sandbox: see the security model of `Tools`.
##
## A change to a path under `.git/` (`write_file`, `edit_file`, `apply_patch`) always asks, because `.git/config` and the hooks run
## programs (`core.fsmonitor`, aliases) the next time git runs; the name is compared without case and trailing dots.
## Only a deny rule can change that. `edit_file` reads the file, so a deny rule of `read_file` denies it too.

import Regex from "std/regex"
import BashTool from "../tools/shell"
import Patch from "../tools/patch"
import Spec from "../tools/spec"
import Tools from "../tools/tools"

struct Rule
  tool: String
  pattern: String
end

struct Rules
  allow: List[Rule]
  deny: List[Rule]
end

def parse_rule(text: String) -> Result[Rule]
  open = text.index_of("(")
  return error("rule is not tool(pattern): #{text}") if open.none? or not text.end_with?(")")

  start = open.unwrap!
  tool = text.slice(0, start)
  pattern = text.slice(start + 1, text.length - start - 2)
  return error("rule has no tool or no pattern: #{text}") if tool == "" or pattern == ""

  ok(Rule(tool: tool, pattern: pattern))
end

def parse_rules(allow: List[String], deny: List[String]) -> Result[Rules]
  allowed: List[Rule] = []
  for text in allow
    allowed = allowed.push(try parse_rule(text))
  end

  denied: List[Rule] = []
  for text in deny
    denied = denied.push(try parse_rule(text))
  end

  ok(Rules(allow: allowed, deny: denied))
end

## Whether a call runs, waits for an answer or is refused. A call whose input or path is not valid is refused.
def verdict(rules: Rules, ctx: Spec.Context, name: String, input: JSON.Value) -> Spec.Verdict
  return patch_verdict(rules, ctx, input) if name == Patch.NAME

  case Tools.offered_tool(ctx, name)
    ok(tool) -> tool_verdict(rules, ctx, tool, input)
    error(_) -> Spec.Verdict.Deny
  end
end

## A command made only of letters, digits, `_ . / : = , + @ % -`, spaces and tabs: nothing in it is special to bash
## (no quote, `$`, backslash, `~`, `*`, `?`, `!`, `;`, `&`, `|`, `<`, `>`, backtick, line end or non-ASCII character),
## so it runs as the words it shows.
def plain?(command: String) -> Bool = Regex.match?(command, PLAIN)

## `asks` is whether the tool asks when no rule matches. A deny rule wins over an allow rule. With `root` (the session
## folder), a `bash` command that only reads inside it (`Shell.verdict`, its paths resolved by `Sandbox`) runs without
## asking, unless a deny rule of `read_file` or `bash` exists: the command could read what the rule hides.
def decide(rules: Rules, tool: String, target: String, asks: Bool, root: Optional[String] = none) -> Spec.Verdict
  matchable = tool != "bash" or plain?(target)
  hidden = tool == "edit_file" and read_denied?(rules, target)
  denied = hidden or (matchable and rules.deny.any? { |rule| matches?(rule, tool, target) })
  read_only = (
    tool == "bash" and
    not guarded?(rules) and
    root.map { |folder| BashTool.read_only?(folder, target) } == some(true)
  )

  allowed = read_only or (matchable and rules.allow.any? { |rule| matches?(rule, tool, target) })
  if denied
    Spec.Verdict.Deny
  elsif protected?(tool, target)
    Spec.Verdict.Ask
  elsif allowed
    Spec.Verdict.Allow
  elsif asks
    Spec.Verdict.Ask
  else
    Spec.Verdict.Allow
  end
end

## A change under `.git/`, which always asks unless a deny rule refuses it. The target of `apply_patch` is its paths
## joined with ", ": each one is checked.
def protected?(tool: String, target: String) -> Bool
  return false if not WRITES.include?(tool)

  target.split(", ").any? { |path| path.split("/").any? { |name| Regex.match?(name.downcase, GIT) } }
end

## Whether a deny rule of `tool` matches `target`.
def denied?(rules: Rules, tool: String, target: String) -> Bool
  rules.deny.any? { |rule| matches?(rule, tool, target) }
end

## A deny rule of `read_file` or `bash` exists: a command that only reads could read what it hides.
def guarded?(rules: Rules) -> Bool = rules.deny.any? { |rule| rule.tool == "read_file" or rule.tool == "bash" }

## Whether a deny rule of `read_file` covers the path (relative to the session folder): `glob` and `grep` skip it too.
def read_denied?(rules: Rules, path: String) -> Bool = rules.deny.any? { |rule| matches?(rule, "read_file", path) }

def wildcard?(pattern: String, text: String) -> Bool
  parts = pattern.split("*")
  return text == pattern if parts.size == 1

  first = parts.first
  last = parts.last
  return false if text.length < first.length + last.length
  return false if not text.start_with?(first) or not text.end_with?(last)

  rest = text.slice(first.length, text.length - first.length - last.length)
  for middle in parts.drop(1).take(parts.size - 2)
    found = rest.index_of(middle)
    return false if found.none?

    rest = rest.slice(found.unwrap! + middle.length, rest.length - found.unwrap! - middle.length)
  end

  true
end

private

WORD = /\A[A-Za-z0-9_]\z/
PLAIN = /\A[A-Za-z0-9_.\/:=,+@%\- \t]*\z/
GIT = /\A\.git\.*\z/
WRITES = ["write_file", "edit_file", "apply_patch"]

# Each path of `apply_patch` decides as the call that does the same would: an updated file as `edit_file`, an added
# file or the target of a move as `write_file`, each also as `apply_patch`. A deny rule of `edit_file`, `write_file`
# or `apply_patch` on a path (or of `read_file`, as for `edit_file`) denies the patch. A deleted file, or the old path
# of a move, asks unless an `apply_patch` rule allows it. The patch runs without asking only when every path is
# allowed.
def patch_verdict(rules: Rules, ctx: Spec.Context, input: JSON.Value) -> Spec.Verdict
  case Patch.touched(ctx, input)
    ok(found) -> combined(found.map { |t| path_verdict(rules, t) })
    error(_) -> Spec.Verdict.Deny
  end
end

def combined(verdicts: List[Spec.Verdict]) -> Spec.Verdict
  return Spec.Verdict.Deny if verdicts.include?(Spec.Verdict.Deny)
  return Spec.Verdict.Ask if verdicts.include?(Spec.Verdict.Ask)

  Spec.Verdict.Allow
end

def tool_verdict(rules: Rules, ctx: Spec.Context, tool: Spec.Tool, input: JSON.Value) -> Spec.Verdict
  case tool.target(ctx, input)
    ok(target) -> decide(rules, tool.name, target, tool.asks, some(ctx.root))
    error(_) -> Spec.Verdict.Deny
  end
end

def path_verdict(rules: Rules, t: Patch.Touched) -> Spec.Verdict
  decide = ->(tool: String) { decide(rules, tool, t.path, true) }
  denied = ["edit_file", "write_file", Patch.NAME].any? { |tool| decide.call(tool) == Spec.Verdict.Deny }
  return Spec.Verdict.Deny if denied

  allowing = case t.touch
    Patch.Touch.Edit -> ["edit_file", Patch.NAME]
    Patch.Touch.Write -> ["write_file", Patch.NAME]
    Patch.Touch.Remove -> [Patch.NAME]
  end

  return Spec.Verdict.Allow if (allowing.any? { |tool| decide.call(tool) == Spec.Verdict.Allow })

  Spec.Verdict.Ask
end

def matches?(rule: Rule, tool: String, target: String) -> Bool
  return false if rule.tool != tool

  if tool == "bash"
    command_matches?(rule.pattern, target)
  else
    wildcard?(rule.pattern, target)
  end
end

def command_matches?(pattern: String, command: String) -> Bool
  case Regex.compile("\\A#{command_regex(pattern.split(""), 0, "")}\\z")
    ok(regex) -> Regex.match?(command, regex)
    error(_) -> false
  end
end

def command_regex(chars: List[String], at: Int, out: String) -> String
  return out if at >= chars.size

  if chars[at] != "*"
    command_regex(chars, at + 1, "#{out}#{Regex.escape(chars[at])}")
  elsif at > 0 and Regex.match?(chars[at - 1], WORD)
    command_regex(chars, at + 1, "#{out}(?:[ \\t].*)?")
  else
    command_regex(chars, at + 1, "#{out}.*")
  end
end
