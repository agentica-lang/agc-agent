## The bodies the clients send. A decoder here refuses a key it does not know and an empty required string; the replies
## and events do not (see `Wire`).

import Kinds from "kinds"
import Wire from "wire"

## The thinking levels a session takes (`effort`), lowest first.
EFFORTS = ["low", "medium", "high"]
## The effort of `UpdateSession` that goes back to the model's own default.
EFFORT_DEFAULT = "default"

## How a client answers an approval request. `AllowSession` also allows the same call again in the session,
## `AllowPrefix` the `bash` commands that start with the request's `prefix` (the same call when it has none), and
## `AllowTool` every call of the tool; none of them reaches into `.git/`.
enum Decision
  Allow
  Deny
  AllowSession
  AllowPrefix
  AllowTool
end

## `POST /v1/sessions`. `provider`, `model` and `api` (the model API, by the name the server gives it) default to the
## server's; `api` to the provider's own.
struct NewSession
  cwd: String
  model: Optional[String]
  api: Optional[String] = none
  provider: Optional[String] = none
end

## `POST /v1/sessions/ID/messages`.
struct SendMessage
  text: String
end

## `POST /v1/sessions/ID/approvals/AID`.
struct Approve
  decision: Decision
end

## `PATCH /v1/sessions/ID`: what to change from the next turn on; a field left out stays.
struct UpdateSession
  ## Another provider takes its own model API, and its default model unless `model` names one.
  provider: Optional[String] = none
  model: Optional[String] = none
  effort: Optional[String] = none
  ## The edits of files in the session folder run without asking.
  accept_edits: Optional[Bool] = none
end

## `POST /v1/sessions/ID/compact`: the answer says whether there was history to fold.
struct Compacted
  compacted: Bool
end

## `POST /v1/sessions/ID/branch`: the session goes on from `entry` of its tree, the `id` of a `TreeNode` (before that
## message) or its `last` (after that turn); 0 is the start.
struct Branch
  entry: Int
end

## `POST /v1/sessions/ID/fork`: a new session with the history up to `entry`, as `Branch` takes it; none copies the
## session as it is now.
struct Fork
  entry: Optional[Int] = none
end

## `POST /v1/sessions/ID/shell`: runs `command` in the session folder as the `bash` tool would, while no turn runs.
## With `context`, its output goes to the model before the next message.
struct RunShell
  command: String
  context: Bool
end

## Every decision, in a fixed order.
def decisions() -> List[Decision] = Wire.chain(Decision.Allow, &following)

def decision_name(decision: Decision) -> String
  case decision
    Decision.Allow -> "allow"
    Decision.Deny -> "deny"
    Decision.AllowSession -> "allow_session"
    Decision.AllowPrefix -> "allow_prefix"
    Decision.AllowTool -> "allow_tool"
  end
end

def parse_decision(name: String) -> Result[Decision] = Wire.lookup(decisions(), &decision_name, "decision", name)

def encode_new_session(body: NewSession) -> String = JSON.encode(body)

def decode_new_session(text: String) -> Result[NewSession]
  body = try Wire.decode_strict(text, NewSession.codec)
  try Wire.non_empty("cwd", body.cwd)
  try Wire.non_empty_if_present("model", body.model)
  try Wire.non_empty_if_present("api", body.api)
  try Wire.non_empty_if_present("provider", body.provider)
  ok(body)
end

def encode_send_message(body: SendMessage) -> String = JSON.encode(body)

def decode_send_message(text: String) -> Result[SendMessage]
  body = try Wire.decode_strict(text, SendMessage.codec)
  try Wire.non_empty("text", body.text)
  ok(body)
end

def encode_approve(body: Approve) -> String = JSON.encode(ApproveWire(decision: decision_name(body.decision)))

def decode_approve(text: String) -> Result[Approve]
  wire = try Wire.decode_strict(text, ApproveWire.codec)
  ok(Approve(decision: try parse_decision(wire.decision)))
end

def encode_update_session(body: UpdateSession) -> String = JSON.encode(body)

def decode_update_session(text: String) -> Result[UpdateSession]
  body = try Wire.decode_strict(text, UpdateSession.codec)
  try Wire.non_empty_if_present("model", body.model)
  try Wire.non_empty_if_present("provider", body.provider)
  for effort in Wire.option_list(body.effort)
    known = EFFORTS.include?(effort) or effort == EFFORT_DEFAULT
    return error("unknown effort: #{effort}", kind: Kinds.KIND_UNKNOWN) if not known
  end

  ok(body)
end

def encode_compacted(body: Compacted) -> String = JSON.encode(body)

def decode_compacted(text: String) -> Result[Compacted] = Wire.decode(text, Compacted.codec)

def encode_branch(body: Branch) -> String = JSON.encode(body)

def decode_branch(text: String) -> Result[Branch]
  body = try Wire.decode_strict(text, Branch.codec)
  try Wire.non_negative("entry", body.entry)
  ok(body)
end

def encode_fork(body: Fork) -> String = JSON.encode(body)

def decode_fork(text: String) -> Result[Fork]
  body = try Wire.decode_strict(text, Fork.codec)
  try Wire.non_negative("entry", body.entry.unwrap_or(0))
  ok(body)
end

def encode_run_shell(body: RunShell) -> String = JSON.encode(body)

def decode_run_shell(text: String) -> Result[RunShell]
  body = try Wire.decode_strict(text, RunShell.codec)
  try Wire.non_empty("command", body.command)
  ok(body)
end

## The fields of the requests and the names of their values on the wire, for `Protocol.WIRE`.
def shape() -> List[String]
  records = [
    Wire.record("NewSession", NewSession.members),
    Wire.record("SendMessage", SendMessage.members),
    Wire.record("Approve", Approve.members),
    Wire.record("UpdateSession", UpdateSession.members),
    Wire.record("Compacted", Compacted.members),
    Wire.record("Branch", Branch.members),
    Wire.record("Fork", Fork.members),
    Wire.record("RunShell", RunShell.members),
    Wire.record("ApproveWire", ApproveWire.members),
  ]

  records + [Wire.values("Decision", decisions().map(&decision_name))]
end

private

struct ApproveWire
  decision: String
end

def following(decision: Decision) -> Optional[Decision]
  case decision
    Decision.Allow -> some(Decision.Deny)
    Decision.Deny -> some(Decision.AllowSession)
    Decision.AllowSession -> some(Decision.AllowPrefix)
    Decision.AllowPrefix -> some(Decision.AllowTool)
    Decision.AllowTool -> none
  end
end
