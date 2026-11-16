## The approval extension of one session: the rules, and what the session's answers and mode allowed. A session
## without it runs every tool call without asking.

import Approval from "approval"
import Permissions from "permissions"
import Spec from "../tools/spec"

struct Approvals
  rules: Approval.Rules
  ## The session folder.
  root: String
  allows: Permissions.Allows
end

## The extension of a session in `root`: the server's `rules` with those of the project file (its allow rules only when
## `trusted`).
def open(rules: Approval.Rules, root: String, trusted: Bool) -> Result[Approvals]
  ok(Approvals(rules: try Permissions.with_project(rules, root, trusted), root: root, allows: Permissions.Allows()))
end

## The hook a tool call passes before it runs.
def verdict(a: Approvals, ctx: Spec.Context, name: String, input: JSON.Value) -> Spec.Verdict
  Approval.verdict(a.rules, ctx, name, input)
end

## Whether the session's answers or mode allow a call that asks.
def allows?(a: Approvals, tool: String, target: String) -> Bool
  Permissions.allows?(a.allows, a.rules, tool, target, a.root)
end

## The words an `allow_prefix` answer would allow, joined by spaces.
def prefix(tool: String, target: String) -> Optional[String] = Permissions.prefix(tool, target).map { |w| w.join(" ") }

def answered(a: Approvals, decision: String, tool: String, target: String) -> Approvals
  a.with(allows: Permissions.answered(a.allows, decision, tool, target))
end

def accept_edits?(a: Approvals) -> Bool = a.allows.accept_edits

def with_accept_edits(a: Approvals, on: Bool) -> Approvals = a.with(allows: a.allows.with(accept_edits: on))

## Whether a deny rule of `read_file` hides the path, relative to the session folder.
def hidden?(a: Approvals, path: String) -> Bool = Approval.read_denied?(a.rules, path)
