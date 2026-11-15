## What the agent may do without asking. A rule is `tool(pattern)`, where `*` in the pattern matches any text.
##
## For `bash`, a rule matches only a plain command (see `plain?`): any other command asks, whatever the rules say, so a
## deny rule of `bash` does not stop `rm x; true`, which asks. A `*` after a word matches only the end or a space and
## more text, so `git status*` matches `git status --short` and not `git statusx`. A rule is a convenience and not a
## sandbox: see the security model of `Tools`.
##
## A change to a path under `.git/` (`write_file`, `edit_file`) always asks, because `.git/config` and the hooks run
## programs (`core.fsmonitor`, aliases) the next time git runs; the name is compared without case and trailing dots.
## Only a deny rule can change that. `edit_file` reads the file, so a deny rule of `read_file` denies it too.

import Regex from "std/regex"

enum Verdict
  Allow
  Ask
  Deny
end

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

## A command made only of letters, digits, `_ . / : = , + @ % -`, spaces and tabs: nothing in it is special to bash
## (no quote, `$`, backslash, `~`, `*`, `?`, `!`, `;`, `&`, `|`, `<`, `>`, backtick, line end or non-ASCII character),
## so it runs as the words it shows.
def plain?(command: String) -> Bool = Regex.match?(command, PLAIN)

## `asks` is whether the tool asks when no rule matches. A deny rule wins over an allow rule.
def decide(rules: Rules, tool: String, target: String, asks: Bool) -> Verdict
  matchable = tool != "bash" or plain?(target)
  hidden = tool == "edit_file" and read_denied?(rules, target)
  denied = hidden or (matchable and rules.deny.any? { |rule| matches?(rule, tool, target) })
  allowed = matchable and rules.allow.any? { |rule| matches?(rule, tool, target) }
  if denied
    Verdict.Deny
  elsif git_internals?(tool, target)
    Verdict.Ask
  elsif allowed
    Verdict.Allow
  elsif asks
    Verdict.Ask
  else
    Verdict.Allow
  end
end

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
WRITES = ["write_file", "edit_file"]

def git_internals?(tool: String, target: String) -> Bool
  WRITES.include?(tool) and target.split("/").any? { |name| Regex.match?(name.downcase, GIT) }
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
