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

## `GET /v1/server`: `started_s` is when the process started (Unix seconds); `running_turns` counts the sessions that
## have a turn or a shell command running now; `stopping` says a stop waits for them.
struct ServerStatus
  pid: Int
  version: String
  started_s: Int
  sessions: Int
  running_turns: Int
  stopping: Bool
end

## The answer of `POST /v1/sessions`.
struct SessionCreated
  id: String
end

## The `202` answer of `POST /v1/sessions/ID/messages`. A message queued into the running turn `turn_id` has the
## `message_id` of its `message_queued`; one that started the turn has none.
struct MessageAccepted
  turn_id: String
  message_id: Optional[String] = none
end

## `api` is the model API of the session, by the name the server gives it, and `provider` its provider (none from a
## server before providers). `model` is the one the session uses now, `updated_s` when its file last changed (Unix seconds), and `title` its first
## user message ("" before one).
struct SessionSummary
  id: String
  cwd: String
  model: String
  api: String
  provider: Optional[String] = none
  updated_s: Int = 0
  title: String = ""
end

## The answer of `GET /v1/sessions`.
struct SessionList
  sessions: List[SessionSummary]
end

## A provider a session may use: its own model API, and the models it offers (`/model` lists them).
struct ProviderInfo
  name: String
  api: String
  models: List[String]
end

## The answer of `GET /v1/providers`: what the server offers now, and the provider of a session that names none.
struct ProviderList
  provider: String
  providers: List[ProviderInfo]
end

## A provider a login can set up. `from` is where its key comes from: `env` (its variable, which wins), `stored` (a
## login) or empty; `coming` is a login with no flow yet, which cannot be picked.
struct LoginStatus
  name: String
  label: String
  key_env: String
  from: String
  coming: Bool
end

## The answer of `GET /v1/auth`. `first`: no key file and no key in the environment, so a client offers a login.
struct LoginList
  providers: List[LoginStatus]
  first: Bool
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
  ## The edits of files run without asking (`PATCH` with `accept_edits`).
  accept_edits: Bool = false
  ## What the session cost so far in USD, when the model catalog has its prices.
  cost: Optional[Float] = none
  ## The thinking level of the session's calls; none leaves it to the model.
  effort: Optional[String] = none
  provider: String = ""
  api: String = ""
  ## The `!` command that runs, none when none does.
  shell_id: Optional[String] = none
end

## A user message of `SessionTree`. `id` is its entry: a branch from it goes back before the message. `last` is the
## entry that ends its turn: a branch from there goes on after the turn. `parent` is the message before it on its
## branch, none for a first one; `active` marks the messages of the branch the session is on. `answer` is the start of
## the turn's answer, its first line cut to 200 characters.
struct TreeNode
  id: Int
  parent: Optional[Int] = none
  text: String
  answer: String = ""
  last: Int
  active: Bool = false
end

## The answer of `GET /v1/sessions/ID/tree`: the user messages of every branch, in the order they were sent.
struct SessionTree
  nodes: List[TreeNode]
end

## The answer of `branch` and (`201`) of `fork`: the session that goes on, and the user message the branch went back
## before, for the editor ("" after a turn or for a copy).
struct Branched
  id: String
  text: String = ""
end

## The `202` answer of `POST /v1/sessions/ID/shell`: the id of its `shell_started` and `shell_finished`.
struct ShellAccepted
  shell_id: String
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

def encode_session_tree(reply: SessionTree) -> String = JSON.encode(reply)

def decode_session_tree(text: String) -> Result[SessionTree] = Wire.decode(text, SessionTree.codec)

def encode_server_status(reply: ServerStatus) -> String = JSON.encode(reply)

def decode_server_status(text: String) -> Result[ServerStatus] = Wire.decode(text, ServerStatus.codec)

def encode_branched(reply: Branched) -> String = JSON.encode(reply)

def decode_branched(text: String) -> Result[Branched] = Wire.decode(text, Branched.codec)

def encode_provider_list(reply: ProviderList) -> String = JSON.encode(reply)

def decode_provider_list(text: String) -> Result[ProviderList] = Wire.decode(text, ProviderList.codec)

def encode_shell_accepted(reply: ShellAccepted) -> String = JSON.encode(reply)

def encode_login_status(reply: LoginStatus) -> String = JSON.encode(reply)

def decode_login_status(text: String) -> Result[LoginStatus] = Wire.decode(text, LoginStatus.codec)

def encode_login_list(reply: LoginList) -> String = JSON.encode(reply)

def decode_login_list(text: String) -> Result[LoginList] = Wire.decode(text, LoginList.codec)

def decode_shell_accepted(text: String) -> Result[ShellAccepted] = Wire.decode(text, ShellAccepted.codec)

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
      accept_edits: some(reply.accept_edits),
      cost: Wire.field(reply.cost),
      effort: reply.effort,
      provider: some(reply.provider),
      api: some(reply.api),
      shell_id: reply.shell_id,
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
      accept_edits: wire.accept_edits.unwrap_or(false),
      cost: Wire.optional(wire.cost),
      effort: wire.effort,
      provider: wire.provider.unwrap_or(""),
      api: wire.api.unwrap_or(""),
      shell_id: wire.shell_id,
    ),
  )
end

## The fields of the replies and the names of their values on the wire, for `Protocol.WIRE`.
def shape() -> List[String]
  records = [
    Wire.record("Health", Health.members),
    Wire.record("SessionCreated", SessionCreated.members),
    Wire.record("MessageAccepted", MessageAccepted.members),
    Wire.record("SessionSummary", SessionSummary.members),
    Wire.record("SessionList", SessionList.members),
    Wire.record("ProviderInfo", ProviderInfo.members),
    Wire.record("ProviderList", ProviderList.members),
    Wire.record("Message", Message.members),
    Wire.record("Session", Session.members),
    Wire.record("ServerInfo", ServerInfo.members),
    Wire.record("TreeNode", TreeNode.members),
    Wire.record("SessionTree", SessionTree.members),
    Wire.record("Branched", Branched.members),
    Wire.record("ServerStatus", ServerStatus.members),
    Wire.record("ShellAccepted", ShellAccepted.members),
    Wire.record("LoginStatus", LoginStatus.members),
    Wire.record("LoginList", LoginList.members),
    Wire.record("MessageWire", MessageWire.members),
    Wire.record("SessionWire", SessionWire.members),
  ]

  records + [Wire.values("Role", roles().map(&role_name))]
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
  accept_edits: Optional[Bool] = none
  cost: JSON.Field[Float]
  effort: Optional[String] = none
  provider: Optional[String] = none
  api: Optional[String] = none
  shell_id: Optional[String] = none
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
