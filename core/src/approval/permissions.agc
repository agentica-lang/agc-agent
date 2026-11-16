## Where the approval rules come from, and what a session allowed while it runs.
##
## Rules: the user's config file (`FINN_CONFIG`, else `$XDG_CONFIG_HOME/finn/config.json`, else
## `~/.config/finn/config.json`), `{"allow": [...], "deny": [...]}` in the syntax of `Approval`; and the project file
## `.finn/config.json` of the session folder, whose deny rules always count and whose allow rules count only in a
## folder of `FINN_TRUSTED_DIRS` (`:` between folders), since anyone who writes the project can write them.
##
## A session allows more by its answers: the same call (`allow_session`), the same command prefix for `bash`
## (`allow_prefix`: `git log`, `npm test`), or the whole tool (`allow_tool`); and in the accept-edits mode the edits of
## files run without asking. None of them reaches into `.git/`, and the deny rules are checked before them, as far as
## the parser sees a command: for `bash`, a rule is matched against each simple command and every tail of its words (so
## `sudo`, `env`, `timeout 5` or `xargs` in front do not hide it), and a command whose words cannot be checked (a quote,
## a `$`, a glob) is not allowed through them while a deny rule of `bash` exists. While a deny rule of `read_file`
## exists, only the same call is allowed again for `bash`: any command may read the file. They last as long as the
## server runs: a restart forgets them. Known limit: an option that writes is not seen, but for git's `--output`.

import Shell from "pkg/shell/shell"
import Approval from "approval"
import Sandbox from "../tools/sandbox"

CONFIG_ENV = "FINN_CONFIG"
PROJECT_FILE = ".finn/config.json"
## The tools whose calls the accept-edits mode runs.
EDITS = ["write_file", "edit_file", "apply_patch"]
## Programs that run the command in their arguments, and interpreters: an answer allows only the same call.
RUNNERS = [
  "env", "xargs", "sh", "bash", "zsh", "python", "python3", "node", "ruby", "perl", "sudo", "nice", "nohup", "timeout",
  "command", "time",
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

## The rules of the user's config file; none when the default file is not there.
def user_rules(read: Fn[String, Result[String]]) -> Result[Approval.Rules]
  case config_path(read)
    some(path) -> rules_of(path)
    none -> ok(no_rules())
  end
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
  return false if tool == "bash" and bash_denied?(rules, target)
  return true if allows.exact.include?(key(tool, target))
  return false if (tool == "bash" and rules.deny.any? { |rule| rule.tool == "read_file" })
  return true if allows.tools.include?(tool)
  return true if allows.accept_edits and EDITS.include?(tool)

  tool == "bash" and not allows.prefixes.empty? and prefixed?(allows.prefixes, target, root, Approval.guarded?(rules))
end

## Whether a deny rule of `bash` matches a simple command of `target`: a tail of its words joined by spaces, also with
## one more argument (as `xargs` adds); or cannot be checked: the command does not parse, or a word is not plain.
def bash_denied?(rules: Approval.Rules, target: String) -> Bool
  return false if (not rules.deny.any? { |rule| rule.tool == "bash" })

  case Shell.parse(target)
    ok(script) -> script.pipelines.any? { |p| p.commands.any? { |c| command_denied?(rules, c) } }
    error(_) -> true
  end
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

def command_denied?(rules: Approval.Rules, command: Shell.Command) -> Bool
  words = Shell.argv(command)
  return true if (words.any? { |word| word.empty? or word.include?(" ") or not Approval.plain?(word) })

  (0...words.size).to_a.any? do |from|
    text = words.drop(from).join(" ")
    Approval.denied?(rules, "bash", text) or Approval.denied?(rules, "bash", "#{text} x")
  end
end
