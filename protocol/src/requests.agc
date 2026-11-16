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

## `POST /v1/sessions`. `model` and `api` (the model API, by the name the server gives it) default to the server's.
struct NewSession
  cwd: String
  model: Optional[String]
  api: Optional[String] = none
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
  model: Optional[String] = none
  effort: Optional[String] = none
  ## The edits of files in the session folder run without asking.
  accept_edits: Optional[Bool] = none
end

## `POST /v1/sessions/ID/compact`: the answer says whether there was history to fold.
struct Compacted
  compacted: Bool
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
  for effort in Wire.option_list(body.effort)
    known = EFFORTS.include?(effort) or effort == EFFORT_DEFAULT
    return error("unknown effort: #{effort}", kind: Kinds.KIND_UNKNOWN) if not known
  end

  ok(body)
end

def encode_compacted(body: Compacted) -> String = JSON.encode(body)

def decode_compacted(text: String) -> Result[Compacted] = Wire.decode(text, Compacted.codec)

## The fields of the requests and the names of their values on the wire, for `Protocol.WIRE`.
def shape() -> List[String]
  records = [
    NewSession.members,
    SendMessage.members,
    Approve.members,
    UpdateSession.members,
    Compacted.members,
    ApproveWire.members,
  ]

  Wire.fields(records) + decisions().map(&decision_name)
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
