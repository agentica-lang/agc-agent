## The bodies the server answers with.

import Events from "events"
import Kinds from "kinds"
import Wire from "wire"

## What a login gives (`LoginStatus.asks`): a key, the base URL of a local server, or a code the user confirms in a
## browser (a device login).
ASKS_KEY = "key"
ASKS_URL = "url"
ASKS_DEVICE = "device"

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
## have a turn or a shell command running now; `stopping` says a stop waits for them; `approvals` says whether a tool
## call that no rule allows asks (none from a server before it).
struct ServerStatus
  pid: Int
  version: String
  started_s: Int
  sessions: Int
  running_turns: Int
  stopping: Bool
  approvals: Optional[Bool] = none
  ## Whether the server offers code mode (`run_script`); none from a server older than this field.
  code_mode: Optional[Bool] = none
end

## The answer of `POST /v1/sessions`.
struct SessionCreated
  id: String
  profile: Optional[Profile] = none
end

## The `202` answer of `POST /v1/sessions/ID/messages`. A message queued into the running turn `turn_id` has the
## `message_id` of its `message_queued`; one that started the turn has none.
struct MessageAccepted
  turn_id: String
  message_id: Optional[String] = none
end

## `api` is the model API of the session, by the name the server gives it, and `provider` its provider (none from a
## server before providers). `model` is the one the session uses now, `updated_s` when its file last changed (Unix
## seconds), and `title` its first user message ("" before one).
struct SessionSummary
  id: String
  cwd: String
  model: String
  api: String
  provider: Optional[String] = none
  updated_s: Int = 0
  title: String = ""
  ## No message, compaction or output of a tool or command yet: a client's list of sessions to resume leaves it out.
  empty: Bool = false
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

## A profile a session may take: the tools its model sees. `source` is `built-in`, `user` or `project`; `warnings` says
## what the server noticed about its file (a name that no tool has, a project file that replaces a profile) or, for a
## session's profile that does not load now, why: the session then shows no tool and refuses turns.
struct Profile
  name: String
  source: String
  description: String = ""
  warnings: List[String] = []
end

## The answer of `GET /v1/sessions/ID/profiles`: the profiles the session may take, by name; one whose file does not
## load has an empty `source` and says why in `warnings`.
struct ProfileList
  profiles: List[Profile]
end

## A slash command of the session's folders, as `/NAME`: `source` is `user` or `project`, or empty for a file that does
## not load (`warnings` says why); `warnings` also names a skill or a command of the user it wins over.
struct CommandInfo
  name: String
  source: String
  description: String = ""
  warnings: List[String] = []
end

## The answer of `GET /v1/sessions/ID/commands`.
struct CommandList
  commands: List[CommandInfo]
end

## A provider a login can set up. `asks` is what a login gives: `key`, or `url` (a local server: its base URL, no
## key; `base_url` is the one it uses now). `from` is where it comes from: `env` (its variable, which wins), `stored`
## (a login) or empty; `coming` is a login with no flow yet, which cannot be picked.
struct LoginStatus
  name: String
  label: String
  key_env: String
  from: String
  coming: Bool
  asks: String = ASKS_KEY
  base_url: String = ""
end

## The answer of `POST /v1/auth/chatgpt`: a device login started. The user opens `url` and types `user_code`; the
## server waits for that, at most `expires_in` seconds.
struct DeviceLogin
  user_code: String
  url: String
  expires_in: Int
end

## The answer of `GET /v1/auth/chatgpt`: where the device login is, `none`, `waiting`, `done` or `failed` (`message`
## says why).
struct DeviceState
  state: String
  message: String
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
  ## The `usage` of the last model call, none before one.
  usage: Optional[Events.Usage] = none
  ## The model's todo list, as its last `todos` event on this branch gave it.
  todos: List[Events.Todo] = []
  profile: Optional[Profile] = none
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

## A line of `SessionExport`: a message (`kind` "user" or "assistant", with its `text`), or a tool call in short
## (`kind` "tool", `tool` its name, `text` what it was called on, `ok` its result, none when it has none), or where
## the history was compacted (`kind` "compaction").
struct ExportEntry
  kind: String
  text: String
  tool: String = ""
  ok: Optional[Bool] = none
end

## The answer of `GET /v1/sessions/ID/export`: the branch the session is on, in order, for a file. `title` is the first
## line of its first user message, `created_ms` when the session began, `todos` its todo list now.
struct SessionExport
  id: String
  title: String
  created_ms: Int
  entries: List[ExportEntry]
  todos: List[Events.Todo]
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

## The answer of `POST /v1/sessions/ID/stop`: whether a turn or command was stopped.
struct Stopped
  stopped: Bool
end

## `GET /v1/sessions/ID/files`: the files of the session folder, for a client's `@` list. Hidden files, the folders of
## build output and dependencies, links and the paths a `read_file` deny rule hides are left out, and the walk is cut
## at a few thousand files or about two seconds: `truncated` says the list was cut. When the user's config names a
## command that lists the files, they are those of its output that the same rules let through; `note` says why the walk
## listed them instead, when the command failed.
struct FileList
  files: List[String]
  truncated: Bool = false
  note: String = ""
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

def encode_session_export(reply: SessionExport) -> String = JSON.encode(reply)

def decode_session_export(text: String) -> Result[SessionExport] = Wire.decode(text, SessionExport.codec)

def encode_server_status(reply: ServerStatus) -> String = JSON.encode(reply)

def decode_server_status(text: String) -> Result[ServerStatus] = Wire.decode(text, ServerStatus.codec)

def encode_branched(reply: Branched) -> String = JSON.encode(reply)

def decode_branched(text: String) -> Result[Branched] = Wire.decode(text, Branched.codec)

def encode_provider_list(reply: ProviderList) -> String = JSON.encode(reply)

def decode_provider_list(text: String) -> Result[ProviderList] = Wire.decode(text, ProviderList.codec)

def encode_command_list(reply: CommandList) -> String = JSON.encode(reply)

def decode_command_list(text: String) -> Result[CommandList] = Wire.decode(text, CommandList.codec)

def encode_profile_list(reply: ProfileList) -> String = JSON.encode(reply)

def decode_profile_list(text: String) -> Result[ProfileList] = Wire.decode(text, ProfileList.codec)

def encode_shell_accepted(reply: ShellAccepted) -> String = JSON.encode(reply)

def encode_login_status(reply: LoginStatus) -> String = JSON.encode(reply)

def decode_login_status(text: String) -> Result[LoginStatus] = Wire.decode(text, LoginStatus.codec)

def encode_device_login(reply: DeviceLogin) -> String = JSON.encode(reply)

def decode_device_login(text: String) -> Result[DeviceLogin] = Wire.decode(text, DeviceLogin.codec)

def encode_device_state(reply: DeviceState) -> String = JSON.encode(reply)

def decode_device_state(text: String) -> Result[DeviceState] = Wire.decode(text, DeviceState.codec)

def encode_login_list(reply: LoginList) -> String = JSON.encode(reply)

def decode_login_list(text: String) -> Result[LoginList] = Wire.decode(text, LoginList.codec)

def decode_shell_accepted(text: String) -> Result[ShellAccepted] = Wire.decode(text, ShellAccepted.codec)

def encode_stopped(reply: Stopped) -> String = JSON.encode(reply)

def decode_stopped(text: String) -> Result[Stopped] = Wire.decode(text, Stopped.codec)

def encode_file_list(reply: FileList) -> String = JSON.encode(reply)

def decode_file_list(text: String) -> Result[FileList] = Wire.decode(text, FileList.codec)

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
      usage: Wire.field(reply.usage.map { |u| Events.usage_wire(u) }),
      todos: some(reply.todos),
      profile: Wire.field(reply.profile),
    ),
  )
end

def decode_session(text: String) -> Result[Session]
  wire = try Wire.decode(text, SessionWire.codec)
  try Wire.non_negative("last_event_id", wire.last_event_id)
  try Wire.non_negative("turn_from_event_id", wire.turn_from_event_id.unwrap_or(0))
  try check_turn(wire)
  try Events.check_todos(wire.todos.unwrap_or([]))
  usage: Optional[Events.Usage] = none
  for given in Wire.option_list(Wire.optional(wire.usage))
    usage = some(try Events.usage_of_wire(given))
  end

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
      usage: usage,
      todos: wire.todos.unwrap_or([]),
      profile: Wire.optional(wire.profile),
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
    Wire.record("Profile", Profile.members),
    Wire.record("ProfileList", ProfileList.members),
    Wire.record("CommandInfo", CommandInfo.members),
    Wire.record("CommandList", CommandList.members),
    Wire.record("Message", Message.members),
    Wire.record("Session", Session.members),
    Wire.record("ServerInfo", ServerInfo.members),
    Wire.record("TreeNode", TreeNode.members),
    Wire.record("SessionTree", SessionTree.members),
    Wire.record("ExportEntry", ExportEntry.members),
    Wire.record("SessionExport", SessionExport.members),
    Wire.record("Branched", Branched.members),
    Wire.record("ServerStatus", ServerStatus.members),
    Wire.record("ShellAccepted", ShellAccepted.members),
    Wire.record("Stopped", Stopped.members),
    Wire.record("FileList", FileList.members),
    Wire.record("LoginStatus", LoginStatus.members),
    Wire.record("LoginList", LoginList.members),
    Wire.record("DeviceLogin", DeviceLogin.members),
    Wire.record("DeviceState", DeviceState.members),
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
  usage: JSON.Field[Events.UsageWire]
  todos: Optional[List[Events.Todo]] = none
  profile: JSON.Field[Profile]
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
