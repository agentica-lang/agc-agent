## What the agent may do without asking. A rule is `tool(pattern)`, where `*` in the pattern matches any text; for
## `bash` it matches only a simple command (see `simple?`).

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

## A command with no way to run a second command or to redirect: none of `;`, `&`, `|`, a backtick, `$(`, `<`, `>` or a
## line end.
def simple?(command: String) -> Bool = not UNSAFE.any? { |part| command.include?(part) }

## `asks` is whether the tool asks when no rule matches. A deny rule wins over an allow rule.
def decide(rules: Rules, tool: String, target: String, asks: Bool) -> Verdict
  matchable = tool != "bash" or simple?(target)
  denied = matchable and rules.deny.any? { |rule| matches?(rule, tool, target) }
  allowed = matchable and rules.allow.any? { |rule| matches?(rule, tool, target) }
  if denied
    Verdict.Deny
  elsif allowed
    Verdict.Allow
  elsif asks
    Verdict.Ask
  else
    Verdict.Allow
  end
end

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

UNSAFE = [";", "&", "|", "`", "$(", "<", ">", "\n", "\r"]

def matches?(rule: Rule, tool: String, target: String) -> Bool = rule.tool == tool and wildcard?(rule.pattern, target)
