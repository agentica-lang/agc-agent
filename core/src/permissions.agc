## Where the approval rules come from, and what a session allowed while it runs.
##
## Rules: the user's config file (`FINN_CONFIG`, else `$XDG_CONFIG_HOME/finn/config.json`, else
## `~/.config/finn/config.json`), `{"allow": [...], "deny": [...]}` in the syntax of `Approval`; and the project file
## `.finn/config.json` of the session folder, whose deny rules always count and whose allow rules count only in a
## folder of `FINN_TRUSTED_DIRS` (`:` between folders), since anyone who writes the project can write them.
##
## A session allows more by its answers: the same call (`allow_session`), the same command prefix for `bash`
## (`allow_prefix`: `git log`, `npm test`), or the whole tool (`allow_tool`); and in the accept-edits mode the edits of
## files run without asking. None of them reaches into `.git/`, and a deny rule is checked before them.

import Shell from "pkg/shell/shell"
import Approval from "approval"
import Sandbox from "sandbox"

CONFIG_ENV = "FINN_CONFIG"
PROJECT_FILE = ".finn/config.json"
## The tools whose calls the accept-edits mode runs.
EDITS = ["write_file", "edit_file", "apply_patch"]
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

## The rules of the user's config file; none when the default file is not there.
def user_rules(read: Fn[String, Result[String]]) -> Result[Approval.Rules]
  case read.call(CONFIG_ENV)
    ok(path) if not path.empty? -> rules_of(path)
    _ ->
      case default_config(read)
        some(path) if File.stat(path).ok? -> rules_of(path)
        _ -> ok(no_rules())
      end
  end
end

## `rules` with those of the project file of `root`: its deny rules, and its allow rules when `root` is `trusted`.
def with_project(rules: Approval.Rules, root: String, trusted: Bool) -> Result[Approval.Rules]
  path = "#{root}/#{PROJECT_FILE}"
  return ok(rules) if not File.stat(path).ok?

  project = try rules_of(path)
  allow = rules.allow
  if trusted
    allow = allow + project.allow
  end

  ok(Approval.Rules(allow: allow, deny: rules.deny + project.deny))
end

## The words a prefix answer would allow for a `bash` command: its first word, or two for `TWO_WORDS`; none for another
## tool or a command that is not one simple command.
def prefix(tool: String, target: String) -> Optional[List[String]]
  return none if tool != "bash"

  script = Shell.parse(target).unwrap_or(Shell.Script(pipelines: []))
  return none if script.pipelines.size != 1 or script.pipelines[0].commands.size != 1

  words = Shell.argv(script.pipelines[0].commands[0])
  return some(words.take(2)) if TWO_WORDS.include?(words[0]) and words.size >= 2 and not words[1].start_with?("-")

  some(words.take(1))
end

## Whether the session's answers or mode allow the call (in the session folder `root`).
def allows?(allows: Allows, tool: String, target: String, root: String) -> Bool
  return false if Approval.protected?(tool, target)
  return true if allows.exact.include?(key(tool, target))
  return true if allows.tools.include?(tool)
  return true if allows.accept_edits and EDITS.include?(tool)

  tool == "bash" and not allows.prefixes.empty? and prefixed?(allows.prefixes, target, root)
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

struct RulesFile
  allow: List[String] = []
  deny: List[String] = []
end

def key(tool: String, target: String) -> String = "#{tool}\n#{target}"

def no_rules() -> Approval.Rules = Approval.Rules(allow: [], deny: [])

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

def rules_of(path: String) -> Result[Approval.Rules]
  text = try File.read_text(path)
  file = case JSON.decode(text, RulesFile)
    ok(found) -> ok(found)
    error(e) -> error("#{path}: #{e.message}")
  end

  parsed = try file
  case Approval.parse_rules(parsed.allow, parsed.deny)
    ok(rules) -> ok(rules)
    error(e) -> error("#{path}: #{e.message}")
  end
end

# Every command starts with an allowed prefix or only reads; nothing writes through a redirection or runs in the
# background.
def prefixed?(prefixes: List[List[String]], target: String, root: String) -> Bool
  case Shell.parse(target)
    ok(script) ->
      script.pipelines.all? do |pipeline|
        (
          pipeline.join != some(Shell.Join.Background) and
          pipeline.commands.all? { |c| command_allowed?(prefixes, c, root) }
        )
      end

    error(_) -> false
  end
end

def command_allowed?(prefixes: List[List[String]], command: Shell.Command, root: String) -> Bool
  alone = Shell.Script(pipelines: [Shell.Pipeline(commands: [command])])
  return true if Shell.read_only?(alone, ->(path) { Sandbox.resolve(root, path).ok? }) == Shell.Verdict.Safe

  writes = command.redirects.any? do |r|
    case r
      Shell.Redirect.Out(_, path, _) -> path != "/dev/null"
      _ -> false
    end
  end

  words = Shell.argv(command)
  not writes and prefixes.any? { |p| words.take(p.size) == p }
end
