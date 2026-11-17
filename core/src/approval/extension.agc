## The approval extension of one session: the rules, and what the session's answers and mode allowed. With `asking`
## off, a call that would ask runs, and only the deny rules count (they hide files from `glob` and `grep` too). A
## session without it runs every tool call.

import Approval from "approval"
import Permissions from "permissions"
import Spec from "../tools/spec"

BASH = "bash"

struct Approvals
  rules: Approval.Rules
  ## The session folder.
  root: String
  allows: Permissions.Allows
  asking: Bool = true
end

## The extension of a session in `root`: the server's `rules` with those of the project file (its allow rules only when
## `trusted`).
def open(rules: Approval.Rules, root: String, trusted: Bool, asking: Bool) -> Result[Approvals]
  all = try Permissions.with_project(rules, root, trusted)
  ok(Approvals(rules: all, root: root, allows: Permissions.Allows(), asking: asking))
end

## Whether tool calls pass the hook: when it asks, or when a deny rule may refuse one.
def gated?(a: Approvals) -> Bool = a.asking or not a.rules.deny.empty?

## The hook a tool call passes before it runs. A deny rule wins over every allow rule, in both modes: a `bash`
## command that a deny rule surely matches (a tail of its words, or a word that names a file a `read_file` rule hides)
## is refused, and one that the deny rules cannot clear (it does not parse, or a word is not plain) asks when the
## asking is on and is refused when it is off. Else, with the asking off, a call that would ask runs.
def verdict(a: Approvals, ctx: Spec.Context, name: String, input: JSON.Value) -> Spec.Verdict
  found = Approval.verdict(a.rules, ctx, name, input)
  return found if found == Spec.Verdict.Deny

  if name == BASH
    command = case JSON.get(input, "command")
      ok(value) -> JSON.string(value).unwrap_or("")
      error(_) -> ""
    end

    return Spec.Verdict.Deny if Permissions.bash_matched?(a.rules, command)

    uncleared = Permissions.bash_denied?(a.rules, command) or Permissions.bash_reads_denied?(a.rules, command)
    return Spec.Verdict.Ask if uncleared and a.asking
    return Spec.Verdict.Deny if uncleared
  end

  return found if a.asking

  Spec.Verdict.Allow
end

## Whether the session's answers or mode allow a call that asks.
def allows?(a: Approvals, tool: String, target: String) -> Bool
  Permissions.allows?(a.allows, a.rules, tool, target, a.root)
end

## The words an `allow_prefix` answer would allow, joined by spaces; none for `bash` while a deny rule of `read_file`
## exists, since then only the same call can be allowed.
def prefix(a: Approvals, tool: String, target: String) -> Optional[String]
  return none if (tool == "bash" and a.rules.deny.any? { |rule| rule.tool == "read_file" })

  Permissions.prefix(tool, target).map { |w| w.join(" ") }
end

def answered(a: Approvals, decision: String, tool: String, target: String) -> Approvals
  a.with(allows: Permissions.answered(a.allows, decision, tool, target))
end

def accept_edits?(a: Approvals) -> Bool = a.asking and a.allows.accept_edits

def with_accept_edits(a: Approvals, on: Bool) -> Approvals = a.with(allows: a.allows.with(accept_edits: on))

## Whether a deny rule of `read_file` hides the path, relative to the session folder.
def hidden?(a: Approvals, path: String) -> Bool = Approval.read_denied?(a.rules, path)
