## The HTTP calls of the protocol to a server. Every call carries the token. A failed one is an error whose `kind` is
## the server's (`session.busy`, `approval.resolved`, ...) and whose `code` is the HTTP status.

import HTTP from "std/http"
import Protocol from "pkg/protocol/protocol"

CALL_TIMEOUT_MS = 10_000
## A login waits for the check of the key at the provider (at most 10 s on the server).
LOGIN_TIMEOUT_MS = 20_000
PROBE_TIMEOUT_MS = 2_000
COMPACT_TIMEOUT_MS = 600_000
## A reload waits up to 150 s for another one that runs, then reads the files.
RELOAD_TIMEOUT_MS = 180_000
EXPORT_TIMEOUT_MS = 120_000
## The most a client takes of an export, the limit of `HTTP`.
EXPORT_BODY_BYTES = 67_108_864
## The most a client takes of a session: its history holds every message of the branch, and a line of each tool call.
SESSION_BODY_BYTES = 16_777_216
# The head of an event stream comes at once. Its body can be quiet for as long as the model thinks, and the protocol
# has no heartbeat: it is read with no time limit, and a cancel stops it.
EVENTS_HEAD_MS = 10_000
ERROR_BODY_BYTES = 65_536
## The server did not answer: nothing listens, or the connection failed.
KIND_UNREACHABLE = "client.unreachable"
KIND_TIMEOUT = "client.timeout"
## A reply over the limit of the call, the kind of `HTTP`.
KIND_TOO_LARGE = "http.too_large"

## What `--yolo` does on a server whose approvals are on, or not known.
YOLO_ASKS_NOT = "--yolo: the tool calls of the turns this client starts run without asking"

## Where a server listens and the token it wants.
struct Server
  url: String
  token: String
end

## The health check is short: a server that does not answer in time is not started again, it is reported.
def health(server: Server) -> Result[Protocol.Health]
  body = try call_within(server, "GET", Protocol.HEALTH_PATH, "", PROBE_TIMEOUT_MS)
  Protocol.decode_health(body)
end

## What the server does now: its pid and version, when it started, and its sessions and turns.
def server_status(server: Server) -> Result[Protocol.ServerStatus]
  body = try call_within(server, "GET", Protocol.SERVER_PATH, "", PROBE_TIMEOUT_MS)
  Protocol.decode_server_status(body)
end

## Whether the config of the server leaves the mouse on; on when the server does not say.
def mouse(server: Server) -> Bool
  case server_status(server)
    ok(status) -> status.mouse.unwrap_or(true)
    error(_) -> true
  end
end

## How the config of the server has the full screen copy a selection; `auto` when the server does not say.
def clipboard(server: Server) -> Protocol.ClipboardSetting
  case server_status(server)
    ok(status) -> status.clipboard.unwrap_or(Protocol.ClipboardSetting())
    error(_) -> Protocol.ClipboardSetting()
  end
end

## The last `lines` lines of the server log, and the warnings it logged since it started.
def server_log(server: Server, lines: Int) -> Result[Protocol.ServerLog]
  body = try call_within(server, "GET", "#{Protocol.LOGS_PATH}?lines=#{lines}", "", PROBE_TIMEOUT_MS)
  Protocol.decode_server_log(body)
end

## The server reads its config file, MCP servers, skills and project instructions again; it may wait up to 150 s for
## another reload that runs.
def reload(server: Server) -> Result[Protocol.Reloaded]
  Protocol.decode_reloaded(try call_within(server, "POST", Protocol.RELOAD_PATH, "", RELOAD_TIMEOUT_MS))
end

## What `--yolo` does on this server, for the warning at the start: nothing when its approvals are off.
def yolo_warning(server: Server) -> String
  case server_status(server)
    ok(status) if status.approvals == some(false) ->
      "--yolo changes nothing: the approvals of this server are off, so every tool call runs without asking"
    _ -> YOLO_ASKS_NOT
  end
end

## Asks the server to stop: it answers at once and goes once its turns end (`now` cancels them).
def stop_server(server: Server, now: Bool) -> Result[Void]
  _ = try call(
    server,
    "POST",
    Protocol.SERVER_STOP_PATH,
    Protocol.encode_stop_server(Protocol.StopServer(now: some(now))),
  )

  ok()
end

def create_session(server: Server, request: Protocol.NewSession) -> Result[Protocol.SessionCreated]
  body = try call(server, "POST", Protocol.SESSIONS_PATH, Protocol.encode_new_session(request))
  Protocol.decode_session_created(body)
end

def session(server: Server, id: String) -> Result[Protocol.Session]
  options = HTTP.ClientOptions(timeout_ms: CALL_TIMEOUT_MS, max_body_bytes: SESSION_BODY_BYTES)
  Protocol.decode_session(try call_with(server, "GET", Protocol.session_path(id), "", options))
end

def send_message(server: Server, id: String, text: String) -> Result[Protocol.MessageAccepted]
  body = try call(
    server,
    "POST",
    Protocol.messages_path(id),
    Protocol.encode_send_message(Protocol.SendMessage(text: text)),
  )

  Protocol.decode_message_accepted(body)
end

def approve(server: Server, id: String, approval_id: String, decision: Protocol.Decision) -> Result[Void]
  _ = try call(
    server,
    "POST",
    Protocol.approval_path(id, approval_id),
    Protocol.encode_approve(Protocol.Approve(decision: decision)),
  )

  ok()
end

def delete_session(server: Server, id: String) -> Result[Void]
  _ = try call(server, "DELETE", Protocol.session_path(id), "")
  ok()
end

def list_sessions(server: Server) -> Result[Protocol.SessionList]
  Protocol.decode_session_list(try call(server, "GET", Protocol.SESSIONS_PATH, ""))
end

def list_providers(server: Server) -> Result[Protocol.ProviderList]
  Protocol.decode_provider_list(try call(server, "GET", Protocol.PROVIDERS_PATH, ""))
end

def list_commands(server: Server, id: String) -> Result[Protocol.CommandList]
  Protocol.decode_command_list(try call(server, "GET", Protocol.commands_path(id), ""))
end

def list_profiles(server: Server, id: String) -> Result[Protocol.ProfileList]
  Protocol.decode_profile_list(try call(server, "GET", Protocol.profiles_path(id), ""))
end

def list_logins(server: Server) -> Result[Protocol.LoginList]
  Protocol.decode_login_list(try call(server, "GET", Protocol.AUTH_PATH, ""))
end

## Checks `key` at the provider and stores it on the server.
def login(server: Server, provider: String, key: String) -> Result[Protocol.LoginStatus]
  body = Protocol.encode_login(Protocol.Login(key: key))
  Protocol.decode_login_status(try call_within(server, "POST", Protocol.auth_path(provider), body, LOGIN_TIMEOUT_MS))
end

## Checks `url` as the base URL of a local server (its `GET /models`) and stores it on the server.
def login_url(server: Server, provider: String, url: String) -> Result[Protocol.LoginStatus]
  body = Protocol.encode_login_url(Protocol.LoginUrl(base_url: url))
  Protocol.decode_login_status(try call_within(server, "POST", Protocol.auth_path(provider), body, LOGIN_TIMEOUT_MS))
end

## Starts the device login of `provider` (ChatGPT): the code the user types at the URL while the server waits.
def device_start(server: Server, provider: String) -> Result[Protocol.DeviceLogin]
  Protocol.decode_device_login(try call_within(server, "POST", Protocol.auth_path(provider), "{}", LOGIN_TIMEOUT_MS))
end

## Where the device login of `provider` is.
def device_state(server: Server, provider: String) -> Result[Protocol.DeviceState]
  Protocol.decode_device_state(try call(server, "GET", Protocol.auth_path(provider), ""))
end

## Removes the stored key of `provider` (the base URL of `local`), or every stored key and URL when none.
def logout(server: Server, provider: Optional[String]) -> Result[Void]
  path = provider.map { |p| Protocol.auth_path(p) }.unwrap_or(Protocol.AUTH_PATH)
  _ = try call(server, "DELETE", path, "")
  ok()
end

## Makes an empty key file on the server when there is none: a first-start login skipped.
def skip_login(server: Server) -> Result[Void]
  _ = try call(server, "PUT", Protocol.AUTH_PATH, "")
  ok()
end

def update_session(server: Server, id: String, change: Protocol.UpdateSession) -> Result[Void]
  _ = try call(server, "PATCH", Protocol.session_path(id), Protocol.encode_update_session(change))
  ok()
end

## Folds the history into a summary now; false when there was nothing to fold. The model writes the summary, so the
## call may take as long as a turn.
def compact(server: Server, id: String) -> Result[Bool]
  body = try call_within(server, "POST", Protocol.compact_path(id), "", COMPACT_TIMEOUT_MS)
  compacted = try Protocol.decode_compacted(body)
  ok(compacted.compacted)
end

def tree(server: Server, id: String) -> Result[Protocol.SessionTree]
  Protocol.decode_session_tree(try call(server, "GET", Protocol.tree_path(id), ""))
end

## The branch the session is on, for `/export`.
def exported(server: Server, id: String, max_bytes: Int = EXPORT_BODY_BYTES) -> Result[Protocol.SessionExport]
  options = HTTP.ClientOptions(timeout_ms: EXPORT_TIMEOUT_MS, max_body_bytes: max_bytes)
  case call_with(server, "GET", Protocol.export_path(id), "", options)
    ok(body) -> Protocol.decode_session_export(body)
    error(e) if e.kind == KIND_TOO_LARGE ->
      error("the export of the session is over #{max_bytes / 1_048_576} MiB", kind: KIND_TOO_LARGE, cause: e)
    error(e) -> error(e)
  end
end

## Goes on from `entry` of the tree in the same session.
def branch(server: Server, id: String, entry: Int) -> Result[Protocol.Branched]
  body = Protocol.encode_branch(Protocol.Branch(entry: entry))
  Protocol.decode_branched(try call(server, "POST", Protocol.branch_path(id), body))
end

## A new session from `entry` of the tree, a copy of the session when none.
def fork(server: Server, id: String, entry: Optional[Int]) -> Result[Protocol.Branched]
  body = Protocol.encode_fork(Protocol.Fork(entry: entry))
  Protocol.decode_branched(try call(server, "POST", Protocol.fork_path(id), body))
end

## Runs a command in the session folder; its output comes in `shell_finished`.
def shell(server: Server, id: String, request: Protocol.RunShell) -> Result[Protocol.ShellAccepted]
  Protocol.decode_shell_accepted(try call(server, "POST", Protocol.shell_path(id), Protocol.encode_run_shell(request)))
end

## Stops the running turn or shell command; with `turn_id`, only that turn while it runs. Whether one was stopped.
def stop(server: Server, id: String, turn_id: Optional[String] = none) -> Result[Bool]
  body = Protocol.encode_stop_turn(Protocol.StopTurn(turn_id: turn_id))
  ok((try Protocol.decode_stopped(try call(server, "POST", Protocol.stop_path(id), body))).stopped)
end

## The files of the session's folder, for the `@` list.
def files(server: Server, id: String) -> Result[Protocol.FileList]
  Protocol.decode_file_list(try call(server, "GET", Protocol.files_path(id), ""))
end

## The event stream of a session from the event after `last_event_id`. A failed answer is read and becomes the error.
def open_events(server: Server, id: String, last_event_id: Int) -> Result[HTTP.Stream]
  headers = (
    headers(server, "")
      .push(HTTP.Header(name: "Accept", value: "text/event-stream"))
      .push(HTTP.Header(name: Protocol.LAST_EVENT_ID_HEADER, value: Protocol.format_event_id(last_event_id)))
  )

  http = try network(HTTP.open("GET", "#{server.url}#{Protocol.events_path(id)}", "".bytes, headers, events_options()))
  return ok(http) if http.status >= 200 and http.status < 300

  rejected: Result[HTTP.Stream] = failure(http.status, http.headers, drain(http))
  Task.cancel(http.done)
  _ = Task.await(http.done)
  rejected
end

## The limits of an event stream, which is quiet while the model thinks: the head comes in `EVENTS_HEAD_MS`, and no
## read timeout cuts the body.
def events_options() -> HTTP.ClientOptions = HTTP.ClientOptions(timeout_ms: EVENTS_HEAD_MS, read_timeout_ms: 0)

private

def call(server: Server, method: String, path: String, body: String) -> Result[String]
  call_within(server, method, path, body, CALL_TIMEOUT_MS)
end

def call_within(server: Server, method: String, path: String, body: String, timeout_ms: Int) -> Result[String]
  call_with(server, method, path, body, HTTP.ClientOptions(timeout_ms: timeout_ms))
end

def call_with(
  server: Server,
  method: String,
  path: String,
  body: String,
  options: HTTP.ClientOptions,
) -> Result[String]
  client = try network(HTTP.client(options))
  result = HTTP.request(client, method, "#{server.url}#{path}", body.bytes, headers(server, body))
  HTTP.close_client(client)
  response = try network(result)
  return network(HTTP.text(response.body, response.headers)) if response.status >= 200 and response.status < 300

  failure(response.status, response.headers, response.body)
end

def headers(server: Server, body: String) -> List[HTTP.Header]
  auth = HTTP.Header(name: "Authorization", value: "Bearer #{server.token}")
  return [auth] if body == ""

  [auth, HTTP.Header(name: "Content-Type", value: "application/json")]
end

def network[T](result: Result[T]) -> Result[T]
  case result
    ok(value) -> ok(value)
    error(e) if e.kind == KIND_TOO_LARGE -> error(e)
    error(e) -> error("cannot reach the server: #{e.message}", kind: unreachable_kind(e.message), cause: e)
  end
end

def unreachable_kind(message: String) -> String
  return KIND_TIMEOUT if message.include?("timed out")

  KIND_UNREACHABLE
end

def failure[T](status: Int, headers: List[HTTP.Header], body: Bytes) -> Result[T]
  text = HTTP.text(body, headers).unwrap_or("")
  case Protocol.decode_failure(text)
    ok(wire) -> error(wire.message, kind: wire.kind, code: status)
    error(_) -> error("the server answered HTTP #{status}", kind: "client.http", code: status)
  end
end

def drain(http: HTTP.Stream) -> Bytes
  body = "".bytes
  while body.size < ERROR_BODY_BYTES
    case http.body.recv(CALL_TIMEOUT_MS)
      ok(piece) -> body = Bytes.concat([body, piece])
      error(_) -> break
    end
  end

  body
end
