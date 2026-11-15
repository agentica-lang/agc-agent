## The bodies the clients send. A decoder here refuses a key it does not know and an empty required string; the replies
## and events do not (see `Wire`).

import Wire from "wire"

## How a client answers an approval request.
enum Decision
  Allow
  Deny
  AllowSession
end

## `POST /v1/sessions`.
struct NewSession
  cwd: String
  model: Optional[String]
end

## `POST /v1/sessions/ID/messages`.
struct SendMessage
  text: String
end

## `POST /v1/sessions/ID/approvals/AID`.
struct Approve
  decision: Decision
end

## Every decision, in a fixed order.
def decisions() -> List[Decision] = Wire.chain(Decision.Allow, &following)

def decision_name(decision: Decision) -> String
  case decision
    Decision.Allow -> "allow"
    Decision.Deny -> "deny"
    Decision.AllowSession -> "allow_session"
  end
end

def parse_decision(name: String) -> Result[Decision] = Wire.lookup(decisions(), &decision_name, "decision", name)

def encode_new_session(body: NewSession) -> String = JSON.encode(body)

def decode_new_session(text: String) -> Result[NewSession]
  body = try Wire.decode_strict(text, NewSession.codec)
  try Wire.non_empty("cwd", body.cwd)
  try Wire.non_empty_if_present("model", body.model)
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

private

struct ApproveWire
  decision: String
end

def following(decision: Decision) -> Optional[Decision]
  case decision
    Decision.Allow -> some(Decision.Deny)
    Decision.Deny -> some(Decision.AllowSession)
    Decision.AllowSession -> none
  end
end
