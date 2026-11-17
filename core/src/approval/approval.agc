## What the agent may do without asking: OpenCode's rules (v1.19.5, MIT, see THIRD_PARTY_NOTICES). A rule is
## `ACTION TOOL(PATTERN)`, the action `allow`, `ask` or `deny`; `TOOL` alone is `TOOL(*)`. The tool and the pattern are
## globs: `*` matches any text (line ends too), `?` one character, and a pattern that ends in ` *` also matches without
## it (`git *` matches `git`); `~` or `$HOME` at its start is the home folder. The last rule that matches wins; with
## none, the tool's default (`Spec.Tool.asks`).
##
## A `bash` command is checked by its parts (`Shell`): each command of the line by its text, and each folder outside
## the session folder that `cd`, `rm`, `cp` and the like name, as `external_directory(FOLDER/*)`. Any deny denies, else
## any ask asks. A line that tree-sitter-bash cannot read or misreads asks, unless a deny rule matches it whole or one
## of its commands. The rules of `read_file` also check the files that `cat`, `grep` and the like name (`Shell.READS`);
## those of `edit_file` and `write_file` the file tools only. A rule is a convenience and not a sandbox: see the
## security model of `Tools`.
##
## A change to a path under `.git/` (`write_file`, `edit_file`, `apply_patch`) always asks, because `.git/config` and
## the hooks run programs (`core.fsmonitor`, aliases) the next time git runs; the name is compared without case and
## trailing dots. Only a deny rule can change that. `edit_file` reads the file, so a deny rule of `read_file` denies it
## too.

import Regex from "std/regex"
import Shell from "shell"
import Patch from "../tools/patch"
import Spec from "../tools/spec"
import Tools from "../tools/tools"

## OpenCode's defaults for reads, before the rules of the config: a `.env` file asks, `.env.example` does not.
DEFAULTS = ["ask read_file(*.env)", "ask read_file(*.env.*)", "allow read_file(*.env.example)"]
## The longest glob of a rule: a match costs up to the length of the pattern times that of the target.
MAX_PATTERN = 256

struct Rule
  action: Spec.Verdict
  tool: String
  pattern: String
  ## The pattern is the whole target as it is, not a glob: the exact command an "always" answer allows.
  literal: Bool = false
end

struct Rules
  all: List[Rule]
end

def parse_rule(text: String) -> Result[Rule]
  space = text.index_of(" ")
  return error("rule is not \"ACTION TOOL(PATTERN)\": #{text}") if space.none?

  action = try action_of(text.slice(0, space.unwrap!), text)
  rest = text.slice(space.unwrap! + 1, text.length - space.unwrap! - 1).strip

  open = rest.index_of("(")
  tool = rest.slice(0, open.unwrap_or(rest.length))
  return error("rule has no tool: #{text}") if tool == ""
  return error("rule's tool has a space (write TOOL(PATTERN)): #{text}") if tool.include?(" ") or tool.include?("\t")
  return ok(Rule(action: action, tool: tool, pattern: "*")) if open.none?
  return error("rule is not \"ACTION TOOL(PATTERN)\": #{text}") if not rest.end_with?(")")

  start = open.unwrap!
  pattern = rest.slice(start + 1, rest.length - start - 2)
  return error("rule has no pattern: #{text}") if pattern == ""
  return error("rule's pattern is over #{MAX_PATTERN} characters: #{text}") if pattern.length > MAX_PATTERN

  ok(Rule(action: action, tool: tool, pattern: expanded(pattern)))
end

def parse_rules(texts: List[String]) -> Result[Rules]
  all: List[Rule] = []
  for text in texts
    all = all.push(try parse_rule(text))
  end

  ok(Rules(all: all))
end

## Whether a call runs, waits for an answer or is refused. A call whose input or path is not valid is refused.
def verdict(rules: Rules, ctx: Spec.Context, name: String, input: JSON.Value) -> Spec.Verdict
  return patch_verdict(rules, ctx, input) if name == Patch.NAME

  case Tools.offered_tool(ctx, name)
    ok(tool) -> tool_verdict(rules, ctx, tool, input)
    error(_) -> Spec.Verdict.Deny
  end
end

## The verdict of `tool` on `target`, a command for `bash` (in the session folder `root`); `asks` is whether the tool
## asks when no rule matches.
def decide(rules: Rules, root: String, tool: String, target: String, asks: Bool) -> Spec.Verdict
  return decide_one(rules, tool, target, asks) if tool != "bash"

  scan = Shell.scan(root, target)
  verdicts = scan.asked.map { |r| decide_one(rules, r.tool, r.pattern, r.tool == "bash") }
  return combined(verdicts) if scan.clear
  return Spec.Verdict.Deny if verdicts.include?(Spec.Verdict.Deny)

  case decide_one(rules, "bash", target, true)
    Spec.Verdict.Deny -> Spec.Verdict.Deny
    _ -> Spec.Verdict.Ask
  end
end

## The action of the last rule that matches.
def evaluate(rules: Rules, tool: String, target: String) -> Optional[Spec.Verdict]
  found: Optional[Spec.Verdict] = none
  for rule in rules.all
    matched = (rule.literal and target == rule.pattern) or (not rule.literal and match?(target, rule.pattern))
    if match?(tool, rule.tool) and matched
      found = some(rule.action)
    end
  end

  found
end

## OpenCode's `Wildcard.match`: `*` any text, `?` one character, a trailing ` *` optional; `\\` counts as `/`.
def match?(text: String, pattern: String) -> Bool
  chars = text.replace("\\", "/").split("")
  glob = pattern.replace("\\", "/")
  return true if glob.end_with?(" *") and globbed?(chars, glob.slice(0, glob.length - 2).split(""))

  globbed?(chars, glob.split(""))
end

## A change under `.git/`, which always asks unless a deny rule refuses it. The target of `apply_patch` is its paths
## joined with ", ": each one is checked.
def protected?(tool: String, target: String) -> Bool
  return false if not WRITES.include?(tool)

  target.split(", ").any? { |path| path.split("/").any? { |name| Regex.match?(name.downcase, GIT) } }
end

## Whether a rule of `read_file` denies the path (relative to the session folder): `glob` and `grep` skip it too.
def read_denied?(rules: Rules, path: String) -> Bool = evaluate(rules, "read_file", path) == some(Spec.Verdict.Deny)

def combined(verdicts: List[Spec.Verdict]) -> Spec.Verdict
  return Spec.Verdict.Deny if verdicts.include?(Spec.Verdict.Deny)
  return Spec.Verdict.Ask if verdicts.include?(Spec.Verdict.Ask)

  Spec.Verdict.Allow
end

## The verdict of one tool and target, without reading a `bash` command into its parts.
def decide_one(rules: Rules, tool: String, target: String, asks: Bool) -> Spec.Verdict
  found = evaluate(rules, tool, target)
  hidden = tool == "edit_file" and read_denied?(rules, target)
  if hidden or found == some(Spec.Verdict.Deny)
    Spec.Verdict.Deny
  elsif protected?(tool, target)
    Spec.Verdict.Ask
  elsif found.some?
    found.unwrap!
  elsif asks
    Spec.Verdict.Ask
  else
    Spec.Verdict.Allow
  end
end

private

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

def tool_verdict(rules: Rules, ctx: Spec.Context, tool: Spec.Tool, input: JSON.Value) -> Spec.Verdict
  case tool.target(ctx, input)
    ok(target) -> decide(rules, ctx.root, tool.name, target, tool.asks)
    error(_) -> Spec.Verdict.Deny
  end
end

def path_verdict(rules: Rules, t: Patch.Touched) -> Spec.Verdict
  decide = ->(tool: String) { decide_one(rules, tool, t.path, true) }
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

def expanded(pattern: String) -> String
  home = System.env("HOME")
  return pattern if not home.ok?

  for start in ["~", "$HOME"]
    if pattern == start or pattern.start_with?("#{start}/")
      return "#{home.unwrap!}#{pattern.slice(start.length, pattern.length - start.length)}"
    end
  end

  pattern
end

def action_of(word: String, text: String) -> Result[Spec.Verdict]
  case word
    "allow" -> ok(Spec.Verdict.Allow)
    "ask" -> ok(Spec.Verdict.Ask)
    "deny" -> ok(Spec.Verdict.Deny)
    _ -> error("rule's action is not allow, ask or deny: #{text}")
  end
end

# A glob match that goes back to the last `*` on a miss: linear for most patterns, never exponential.
def globbed?(text: List[String], glob: List[String]) -> Bool
  t = 0
  g = 0
  star = -1
  mark = 0
  while t < text.size
    if g < glob.size and glob[g] == "*"
      star = g
      mark = t
      g = g + 1
    elsif g < glob.size and (glob[g] == "?" or glob[g] == text[t])
      t = t + 1
      g = g + 1
    elsif star >= 0
      g = star + 1
      mark = mark + 1
      t = mark
    else
      return false
    end
  end

  while g < glob.size and glob[g] == "*"
    g = g + 1
  end

  g == glob.size
end
