## The bodies the clients send. A decoder here refuses a key it does not know and an empty required string; the replies
## and events do not (see `Wire`).

import Wire from "wire"

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

## `PATCH /v1/sessions/ID`: the settings to change; a missing one stays. `accept_edits` runs the edits of files in the
## session folder without asking.
struct SessionUpdate
  accept_edits: Optional[Bool] = none
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

def encode_session_update(body: SessionUpdate) -> String = JSON.encode(body)

def decode_session_update(text: String) -> Result[SessionUpdate] = Wire.decode_strict(text, SessionUpdate.codec)

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
