## The bodies the server answers with.

import Events from "events"
import Kinds from "kinds"
import Wire from "wire"

## Who wrote a message of the history. The history is display text: an entry of another kind (a tool call) will be a
## new type, not a new `Role`, so a `case` on `Role` stays exhaustive.
enum Role
  User
  Assistant
end

## `GET /v1/health`. `wire` is the `Protocol.wire_digest` of the server, none from a server older than it.
struct Health
  version: String
  wire: Optional[String] = none
end

## The answer of `POST /v1/sessions`.
struct SessionCreated
  id: String
end

## The `202` answer of `POST /v1/sessions/ID/messages`.
struct MessageAccepted
  turn_id: String
end

## `api` is the model API of the session, by the name the server gives it.
## `model` is the one the session uses now, `updated_s` when its file last changed (Unix seconds), and `title` its first
## user message ("" before one).
struct SessionSummary
  id: String
  cwd: String
  model: String
  api: String
  updated_s: Int = 0
  title: String = ""
end

## The answer of `GET /v1/sessions`.
struct SessionList
  sessions: List[SessionSummary]
end

## A finished message, as the text to draw.
struct Message
  role: Role
  text: String
end

## The answer of `GET /v1/sessions/ID`. Subscribe with `Last-Event-ID` set to `last_event_id` to miss and repeat no
## event; 0 is before the first event, and it is never negative.
##
## `history` holds the finished messages. While a turn runs, `turn_id` is its id and `turn_from_event_id` is the event
## id just before its `turn_started` (none when no turn runs). A client that attaches mid-turn subscribes with
## `Last-Event-ID` set to `turn_from_event_id` instead: the normal replay then gives it the whole running turn, its
## deltas, tool events and approval requests. `pending_approvals` lists the approvals still waiting, for a client that
## only needs to answer them. The server keeps every event of the running turn, however many, so that replay never
## answers `resync`; a client that already drew part of the turn keeps using the last id it saw.
struct Session
  id: String
  cwd: String
  model: String
  last_event_id: Int
  turn_id: Optional[String]
  turn_from_event_id: Optional[Int]
  pending_approvals: List[Events.ApprovalRequested]
  history: List[Message]
  ## What the session cost so far in USD, when the model catalog has its prices.
  cost: Optional[Float] = none
  ## The thinking level of the session's calls; none leaves it to the model.
  effort: Optional[String] = none
end

## `server.json` in the state folder, which only its user can read: where the server listens and its Bearer token.
struct ServerInfo
  port: Int
  token: String
  pid: Int
end

## Every role, in a fixed order.
def roles() -> List[Role] = Wire.chain(Role.User, &following)

def role_name(role: Role) -> String
  case role
    Role.User -> "user"
    Role.Assistant -> "assistant"
  end
end

def parse_role(name: String) -> Result[Role] = Wire.lookup(roles(), &role_name, "role", name)

def encode_health(reply: Health) -> String = JSON.encode(reply)

def decode_health(text: String) -> Result[Health] = Wire.decode(text, Health.codec)

def encode_server_info(info: ServerInfo) -> String = JSON.encode(info)

def decode_server_info(text: String) -> Result[ServerInfo] = Wire.decode(text, ServerInfo.codec)

def encode_session_created(reply: SessionCreated) -> String = JSON.encode(reply)

def decode_session_created(text: String) -> Result[SessionCreated] = Wire.decode(text, SessionCreated.codec)

def encode_message_accepted(reply: MessageAccepted) -> String = JSON.encode(reply)

def decode_message_accepted(text: String) -> Result[MessageAccepted] = Wire.decode(text, MessageAccepted.codec)

def encode_session_list(reply: SessionList) -> String = JSON.encode(reply)

def decode_session_list(text: String) -> Result[SessionList] = Wire.decode(text, SessionList.codec)

## It trusts its input: it does not check what `decode_session` checks about `turn_id`, `turn_from_event_id` and
## `last_event_id`, so the server must build a consistent `Session`.
def encode_session(reply: Session) -> String
  history = reply.history.map { |m| MessageWire(role: role_name(m.role), text: m.text) }
  JSON.encode(
    SessionWire(
      id: reply.id,
      cwd: reply.cwd,
      model: reply.model,
      last_event_id: reply.last_event_id,
      turn_id: reply.turn_id,
      turn_from_event_id: reply.turn_from_event_id,
      pending_approvals: reply.pending_approvals,
      history: history,
      cost: Wire.field(reply.cost),
      effort: reply.effort,
    ),
  )
end

def decode_session(text: String) -> Result[Session]
  wire = try Wire.decode(text, SessionWire.codec)
  try Wire.non_negative("last_event_id", wire.last_event_id)
  try Wire.non_negative("turn_from_event_id", wire.turn_from_event_id.unwrap_or(0))
  try check_turn(wire)
  history: List[Message] = []
  for item in wire.history
    history = history.push(Message(role: try parse_role(item.role), text: item.text))
  end

  ok(
    Session(
      id: wire.id,
      cwd: wire.cwd,
      model: wire.model,
      last_event_id: wire.last_event_id,
      turn_id: wire.turn_id,
      turn_from_event_id: wire.turn_from_event_id,
      pending_approvals: wire.pending_approvals,
      history: history,
      cost: Wire.optional(wire.cost),
      effort: wire.effort,
    ),
  )
end

## The fields of the replies and the names of their values on the wire, for `Protocol.WIRE`.
def shape() -> List[String]
  records = [
    Health.members,
    SessionCreated.members,
    MessageAccepted.members,
    SessionSummary.members,
    SessionList.members,
    Message.members,
    Session.members,
    ServerInfo.members,
    MessageWire.members,
    SessionWire.members,
  ]

  Wire.fields(records) + roles().map(&role_name)
end

private

struct MessageWire
  role: String
  text: String
end

struct SessionWire
  id: String
  cwd: String
  model: String
  last_event_id: Int
  turn_id: Optional[String]
  turn_from_event_id: Optional[Int]
  pending_approvals: List[Events.ApprovalRequested]
  history: List[MessageWire]
  cost: JSON.Field[Float]
  effort: Optional[String] = none
end

def check_turn(wire: SessionWire) -> Result[Void]
  if wire.turn_id.some? != wire.turn_from_event_id.some?
    return error("turn_id and turn_from_event_id come together", kind: Kinds.KIND_INVALID)
  end

  if wire.turn_from_event_id.unwrap_or(0) > wire.last_event_id
    return error("turn_from_event_id is after last_event_id", kind: Kinds.KIND_INVALID)
  end

  ok()
end

def following(role: Role) -> Optional[Role]
  case role
    Role.User -> some(Role.Assistant)
    Role.Assistant -> none
  end
end
