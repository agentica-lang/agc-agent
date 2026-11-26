## What the agent may do without asking: OpenCode's rules (v1.19.5, MIT, see THIRD_PARTY_NOTICES). A rule is
## `ACTION TOOL(PATTERN)`, the action `allow`, `ask` or `deny`; `TOOL` alone is `TOOL(*)`. The tool and the pattern are
## globs: `*` matches any text (line ends too), `?` one character, and a pattern that ends in ` *` also matches without
## it (`git *` matches `git`); `~` or `$HOME` at its start is the home folder. The last rule that matches wins; with
## none, the tool's default (`Spec.Tool.asks`).
##
## A `bash` command is checked by its parts (`Shell`): each command of the line by its text, and each folder outside
## the session folder that `cd`, `rm`, `cp` and the like name, as `external_directory(FOLDER/*)`. Any deny denies, else
## any ask asks. A line that tree-sitter-bash cannot read or misreads asks, unless a deny rule matches it whole or one
## of its commands. The rules of `read_file` also check, best effort, the files that `cat`, `grep` and the like name
## (`Shell.READS`); those of `edit_file` and `write_file` the file tools only. A rule is a convenience and not a
## sandbox: see the security model of `Tools`.
##
## A change to a path under `.git/` or `.finn/` (`write_file`, `edit_file`, `apply_patch`) always asks: `.git/config`
## and the hooks run programs (`core.fsmonitor`, aliases) the next time git runs, and `.finn/` holds the project's
## rules, skills, profiles and the slash commands whose text the user sends next. The name is compared without case
## and trailing dots. Only a deny rule can change that. `edit_file` reads the file, so a deny rule of `read_file` denies it
## too.

import Regex from "std/regex"
import Shell from "shell"
import Sandbox from "../tools/sandbox"
import Patch from "../tools/patch"
import Spec from "../tools/spec"
import Tools from "../tools/tools"
import WebFetch from "../tools/web_fetch"

## OpenCode's defaults for reads, before the rules of the config: a `.env` file asks, `.env.example` does not. The files
## of Finn's own folders that hold keys, tokens and the server's address are denied to every tool by `finn_denies`
## (an `allow` rule of the config comes after and wins).
DEFAULTS = ["ask read_file(*.env)", "ask read_file(*.env.*)", "allow read_file(*.env.example)"]
## The files of Finn's own folders that no tool reads or writes by default, by their name in the folder.
SECRET_FILES = ["auth.json", "server.json", "config.json", "chatgpt.json"]
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
  ## The session folder: a path of a rule that starts with `/` also matches the files of the folder, which tools name
  ## relative to it. Empty for rules not of a session.
  root: String = ""
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

## The deny rules for the files of `SECRET_FILES` in each of `folders` (the state folder, the folder of the config file
## and of the stored keys), also by the real path of the folder and of a file that is a link (a dotfiles manager), and
## for each of `files` as it is. Made as records, not parsed: a long path never refuses the start.
def finn_denies(folders: List[String], files: List[String]) -> List[Rule]
  paths = files
  for folder in folders
    for place in [folder, Path.real(folder).unwrap_or(folder)].uniq
      paths = paths + SECRET_FILES.map { |name| "#{place}/#{name}" }
    end
  end

  paths = paths + paths.flat_map { |path| [Path.real(path).unwrap_or(path)] }
  rules: List[Rule] = []
  for path in paths.uniq
    for tool in ["read_file", "write_file"]
      rules = rules.push(Rule(action: Spec.Verdict.Deny, tool: tool, pattern: path))
    end
  end

  rules
end

def parse_rules(texts: List[String]) -> Result[Rules]
  all: List[Rule] = []
  for text in texts
    rule = try parse_rule(text)
    all = all.push(rule)
    # The tools check real paths: a rule of `~/x` also matches where a link in the home folder leads.
    for real in real_home(rule)
      all = all.push(real)
    end
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
def evaluate(rules: Rules, tool: String, called: String) -> Optional[Spec.Verdict]
  found: Optional[Spec.Verdict] = none
  # A rule of `web_fetch` sees the URL only: the method and the hash that tell two calls apart are not part of it.
  target = WebFetch.rule_view(tool, called)
  chars = target.replace("\\", "/").split("")
  # A path in the session folder is named relative to it: a rule of an absolute path sees it in full. Only the tools
  # that take a path: a command or the input of an MCP tool is no path.
  full = chars
  if not chars.empty? and chars[0] != "/" and PATH_TOOLS.include?(tool)
    full = []
    if rules.root != ""
      base = rules.root
      if base.end_with?("/")
        base = base.slice(0, base.length - 1)
      end

      full = "#{base}/#{target}".replace("\\", "/").split("")
    end
  end

  for rule in rules.all
    absolute = rule.pattern.start_with?("/")
    # With no full path, a pattern of an absolute path cannot match a relative one: no walk over it.
    next if absolute and full.empty? and not chars.empty?
    next if rule.tool != tool and not match?(tool, rule.tool)

    wanted = chars
    if absolute
      wanted = full
    end

    matched = (rule.literal and target == rule.pattern) or (not rule.literal and matches_chars?(wanted, rule.pattern))
    if matched
      found = some(rule.action)
    end
  end

  found
end

## OpenCode's `Wildcard.match`: `*` any text, `?` one character, a trailing ` *` optional; `\\` counts as `/`.
def match?(text: String, pattern: String) -> Bool = matches_chars?(text.replace("\\", "/").split(""), pattern)

## `match?` of a text already split into its characters (with `\\` as `/`), for many patterns.
def matches_chars?(chars: List[String], pattern: String) -> Bool
  glob = pattern.replace("\\", "/")
  return true if glob.end_with?(" *") and globbed?(chars, glob.slice(0, glob.length - 2).split(""))

  globbed?(chars, glob.split(""))
end

## A change under `.git/` or `.finn/`, which always asks unless a deny rule refuses it. The target of `apply_patch` is its paths
## joined with ", ": each one is checked.
def protected?(tool: String, target: String) -> Bool
  return false if not WRITES.include?(tool)

  target.split(", ")
    .any? do |path|
      path.split("/").any? { |name| Regex.match?(name.downcase, GIT) or Regex.match?(name.downcase, FINN) }
    end
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
FINN = /\A\.finn\.*\z/
WRITES = ["write_file", "edit_file", "apply_patch"]
FILE_TOOLS = ["read_file", "write_file", "edit_file", "glob", "grep"]
READS = ["read_file", "glob", "grep"]
PATH_TOOLS = READS + WRITES

# Each path of `apply_patch` decides as the call that does the same would: an updated file as `edit_file`, an added
# file or the target of a move as `write_file`, each also as `apply_patch`. A deny rule of `edit_file`, `write_file`
# or `apply_patch` on a path (or of `read_file`, as for `edit_file`) denies the patch. A deleted file, or the old path
# of a move, asks unless an `apply_patch` rule allows it. The patch runs without asking only when every path is
# allowed.
def patch_verdict(rules: Rules, ctx: Spec.Context, input: JSON.Value) -> Spec.Verdict
  case Patch.touched(ctx, input)
    ok(found) -> combined(found.map { |t| path_verdict(rules, ctx, t) })
    error(_) -> Spec.Verdict.Deny
  end
end

def tool_verdict(rules: Rules, ctx: Spec.Context, tool: Spec.Tool, input: JSON.Value) -> Spec.Verdict
  case tool.target(ctx, input)
    ok(target) ->
      combined([decide(rules, ctx.root, tool.name, target, tool.asks), outside_verdict(rules, ctx, tool.name, target)])
    error(_) -> Spec.Verdict.Deny
  end
end

# A file tool that reaches outside the session folder is also an `external_directory(FOLDER/*)`, as it is for `bash`:
# with no rule it asks, whatever the tool does by default, so a read of `~/.ssh/id_rsa` is not silent.
def outside_verdict(rules: Rules, ctx: Spec.Context, tool: String, target: String) -> Spec.Verdict
  return Spec.Verdict.Allow if tool == "bash" or not FILE_TOOLS.include?(tool)
  # The folders of the skills the session can load are read as part of the session.
  return Spec.Verdict.Allow if READS.include?(tool) and ctx.read_roots.any? { |dir| Sandbox.inside?(dir, target) }

  case Shell.external(ctx.root, target)
    some(glob) -> decide_one(rules, Shell.EXTERNAL, glob, true)
    none -> Spec.Verdict.Allow
  end
end

def path_verdict(rules: Rules, ctx: Spec.Context, t: Patch.Touched) -> Spec.Verdict
  outside = outside_verdict(rules, ctx, "write_file", t.path)
  decide = ->(tool: String) { decide_one(rules, tool, t.path, true) }
  denied = ["edit_file", "write_file", Patch.NAME].any? { |tool| decide.call(tool) == Spec.Verdict.Deny }
  return Spec.Verdict.Deny if denied

  allowing = case t.touch
    Patch.Touch.Edit -> ["edit_file", Patch.NAME]
    Patch.Touch.Write -> ["write_file", Patch.NAME]
    Patch.Touch.Remove -> [Patch.NAME]
  end

  return Spec.Verdict.Deny if outside == Spec.Verdict.Deny
  return Spec.Verdict.Ask if outside == Spec.Verdict.Ask
  return Spec.Verdict.Allow if allowing.any? { |tool| decide.call(tool) == Spec.Verdict.Allow }

  Spec.Verdict.Ask
end

# The rule with the home folder of the rule (from `~` or `$HOME`) as its real path, when that is not the same text.
def real_home(rule: Rule) -> List[Rule]
  home = System.env("HOME")
  return [] if not home.ok? or home.unwrap! == "" or not rule.pattern.start_with?(home.unwrap!)

  real = Path.real(home.unwrap!).unwrap_or(home.unwrap!)
  return [] if real == home.unwrap!

  rest = rule.pattern.slice(home.unwrap!.length, rule.pattern.length - home.unwrap!.length)
  return [] if rest != "" and not rest.start_with?("/")

  [rule.with(pattern: "#{real}#{rest}")]
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
