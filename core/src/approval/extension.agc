## The approval extension of one session: the rules, and what the session's answers and mode allowed. With `asking`
## off, a call that would ask runs, and only the deny rules count (they hide files from `glob` and `grep` too). A
## session without it runs every tool call.

import Approval from "approval"
import Permissions from "permissions"
import Shell from "shell"
import Spec from "../tools/spec"

struct Approvals
  rules: Approval.Rules
  allows: Permissions.Allows
  ## The session folder.
  root: String
  asking: Bool = true
end

## The extension of a session in `root`: `Approval.DEFAULTS`, then the server's `rules`, then those of the project file
## (all of them when `trusted`, else only its deny rules).
def open(rules: Approval.Rules, root: String, trusted: Bool, asking: Bool) -> Result[Approvals]
  defaults = try Approval.parse_rules(Approval.DEFAULTS)
  all = try Permissions.with_project(Approval.Rules(all: defaults.all + rules.all), root, trusted)
  ok(Approvals(rules: all.with(root: root), allows: Permissions.Allows(), root: root, asking: asking))
end

## Whether tool calls pass the hook: when it asks, or when a deny rule may refuse one.
def gated?(a: Approvals) -> Bool = a.asking or a.rules.all.any? { |rule| rule.action == Spec.Verdict.Deny }

## The hook a tool call passes before it runs. A deny rule wins over every allow rule, in both modes. With the asking
## off, a call that would ask runs.
def verdict(a: Approvals, ctx: Spec.Context, name: String, input: JSON.Value) -> Spec.Verdict
  found = Approval.verdict(a.rules, ctx, name, input)
  return found if a.asking or found == Spec.Verdict.Deny

  Spec.Verdict.Allow
end

## Whether the session's answers or mode allow a call that asks.
def allows?(a: Approvals, tool: String, target: String) -> Bool
  Permissions.allows?(a.allows, a.rules, a.root, tool, target)
end

## What an `allow_prefix` answer would allow: the patterns of `bash`, and `external_directory(FOLDER/*)`.
def prefix(a: Approvals, tool: String, target: String) -> Optional[String]
  Permissions.prefix(a.root, tool, target).map { |found| found.map { |r| shown(r) }.join(", ") }
end

def answered(a: Approvals, decision: String, tool: String, target: String) -> Approvals
  a.with(allows: Permissions.answered(a.allows, decision, a.root, tool, target))
end

def accept_edits?(a: Approvals) -> Bool = a.asking and a.allows.accept_edits

def with_accept_edits(a: Approvals, on: Bool) -> Approvals = a.with(allows: a.allows.with(accept_edits: on))

## Whether a deny rule of `read_file` hides the path, relative to the session folder.
def hidden?(a: Approvals, path: String) -> Bool = Approval.read_denied?(a.rules, path)

private

def shown(r: Shell.Resource) -> String
  return r.pattern if r.tool == "bash"

  "#{r.tool}(#{r.pattern})"
end
