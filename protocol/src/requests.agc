## The bodies the clients send.

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

def decision_name(decision: Decision) -> String
  case decision
    Decision.Allow -> "allow"
    Decision.Deny -> "deny"
    Decision.AllowSession -> "allow_session"
  end
end

def parse_decision(name: String) -> Result[Decision] = Wire.lookup(DECISIONS, &decision_name, "decision", name)

def encode_new_session(body: NewSession) -> String = JSON.encode(body)

def decode_new_session(text: String) -> Result[NewSession] = Wire.decode(text, NewSession.codec)

def encode_send_message(body: SendMessage) -> String = JSON.encode(body)

def decode_send_message(text: String) -> Result[SendMessage] = Wire.decode(text, SendMessage.codec)

def encode_approve(body: Approve) -> String = JSON.encode(ApproveWire(decision: decision_name(body.decision)))

def decode_approve(text: String) -> Result[Approve]
  wire = try Wire.decode(text, ApproveWire.codec)
  ok(Approve(decision: try parse_decision(wire.decision)))
end

private

DECISIONS = [Decision.Allow, Decision.Deny, Decision.AllowSession]

struct ApproveWire
  decision: String
end
