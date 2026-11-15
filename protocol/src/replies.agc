## The bodies the server answers with.

import Wire from "wire"

enum Role
  User
  Assistant
end

## `GET /v1/health`.
struct Health
  version: String
end

## The answer of `POST /v1/sessions`.
struct SessionCreated
  id: String
end

## The `202` answer of `POST /v1/sessions/ID/messages`.
struct MessageAccepted
  turn_id: String
end

struct SessionSummary
  id: String
  cwd: String
  model: String
end

## The answer of `GET /v1/sessions`.
struct SessionList
  sessions: List[SessionSummary]
end

struct Message
  role: Role
  text: String
end

## The answer of `GET /v1/sessions/ID`. Subscribe with `Last-Event-ID` set to `last_event_id` to miss and repeat no
## event; 0 is before the first event.
struct Session
  id: String
  cwd: String
  model: String
  last_event_id: Int
  history: List[Message]
end

def role_name(role: Role) -> String
  case role
    Role.User -> "user"
    Role.Assistant -> "assistant"
  end
end

def parse_role(name: String) -> Result[Role] = Wire.lookup(ROLES, &role_name, "role", name)

def encode_health(reply: Health) -> String = JSON.encode(reply)

def decode_health(text: String) -> Result[Health] = Wire.decode(text, Health.codec)

def encode_session_created(reply: SessionCreated) -> String = JSON.encode(reply)

def decode_session_created(text: String) -> Result[SessionCreated] = Wire.decode(text, SessionCreated.codec)

def encode_message_accepted(reply: MessageAccepted) -> String = JSON.encode(reply)

def decode_message_accepted(text: String) -> Result[MessageAccepted] = Wire.decode(text, MessageAccepted.codec)

def encode_session_list(reply: SessionList) -> String = JSON.encode(reply)

def decode_session_list(text: String) -> Result[SessionList] = Wire.decode(text, SessionList.codec)

def encode_session(reply: Session) -> String
  history = reply.history.map { |m| MessageWire(role: role_name(m.role), text: m.text) }
  JSON.encode(
    SessionWire(
      id: reply.id,
      cwd: reply.cwd,
      model: reply.model,
      last_event_id: reply.last_event_id,
      history: history,
    ),
  )
end

def decode_session(text: String) -> Result[Session]
  wire = try Wire.decode(text, SessionWire.codec)
  history: List[Message] = []
  for item in wire.history
    history = history.push(Message(role: try parse_role(item.role), text: item.text))
  end

  ok(Session(id: wire.id, cwd: wire.cwd, model: wire.model, last_event_id: wire.last_event_id, history: history))
end

private

ROLES = [Role.User, Role.Assistant]

struct MessageWire
  role: String
  text: String
end

struct SessionWire
  id: String
  cwd: String
  model: String
  last_event_id: Int
  history: List[MessageWire]
end
