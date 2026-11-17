## The HTTP API of the agent on 127.0.0.1: the routes of the protocol, the event stream of each session, and the
## checks in front of them (`Host`, `Origin`, the Bearer token). The sessions are `Sessions`.
##
## The state folder (0700) holds `server.json` (0600, `Protocol.ServerInfo`) for the clients and `core.lock`, which
## the running server holds locked so that a second one does not start. A client holds `server.lock` while it starts
## a server, so the server takes another file.

import HTTP from "std/http"
import Bond from "pkg/bond/bond"
import Protocol from "pkg/protocol/protocol"
import Config from "../config/config"
import Cli from "../config/cli"
import Chatgpt from "../providers/chatgpt"
import Logins from "../providers/logins"
import Providers from "../providers/providers"
import Extensions from "../config/registry"
import Folders from "../config/folders"
import Sessions from "../session/session"

SERVER_JSON = "server.json"
LOCK_FILE = "core.lock"
MAX_BODY_BYTES = 1_048_576
DRAIN_POLL_MS = 100
## A cancelled turn ends in this time at most before the sessions stop.
CANCEL_MS = 3000
## Then the connections that are still open are closed.
SHUTDOWN_MS = 5000
## How long `stop_requested` waits before it waits again.
STOP_POLL_MS = 3_600_000

## What the routes of the server control share with the task that owns it: a stop request, as `now`, the start, the
## flags `draining` (no new work) and `now` (cancel the turns), and how long a stop waits for the turns.
struct Control
  stopping: Channel[Bool]
  started_s: Int
  flags: ATS[String, Bool]
  drain_ms: Int
  approvals: Bool = false
  code_mode: Bool = false
  no_worker: Bool = false
end

struct Server
  http: HTTP.Server
  port: Int
  token: String
  sessions: Sessions.Sessions
  lock: File.Handle
  state_dir: String
  control: Control
  ## The services of the extensions that started: they run while the server holds its lock.
  services: List[Extensions.Running] = []
end

## Starts the server in the calling task, which owns it: call it from the task that keeps it.
def start(options: Config.Options) -> Result[Server]
  try Folders.private_folder(options.state_dir)
  try Folders.private_folder(options.data_dir)
  try Folders.private_folder(Sessions.folder(options))
  lock = try File.open("#{options.state_dir}/#{LOCK_FILE}", "append")
  locked = File.try_lock(lock, 1000)
  if locked != ok(true)
    _ = File.close(lock)
    return error("a server already runs for #{options.state_dir}")
  end

  registry = options.registry.map { |served| served.registry }.unwrap_or(Extensions.Registry())
  begun = Extensions.start_services(registry.services, registry.service_ms)
  if not begun.ok?
    _ = File.close(lock)
    return error(begun.message)
  end

  running = begun.unwrap!

  sessions = Sessions.start(options)
  started = serve(options, sessions, lock)
  if not started.ok?
    Sessions.stop(sessions)
    Extensions.stop_services(running)
    _ = File.close(lock)
  end

  case started
    ok(server) -> ok(server.with(services: running))
    error(e) -> error(e)
  end
end

def new_control(drain_ms: Int) -> Control
  Control(stopping: Channel.new(1), started_s: Time.now_ms / 1000, flags: ATS.new(), drain_ms: drain_ms)
end

## Asks the server to stop, as `POST /v1/server/stop` does; a signal does the same with `now`.
def request_stop(server: Server, now: Bool) -> Void
  asked(server.control, now)
end

## Waits for the request to stop (it waits again after `poll_ms` without one): whether it asks to cancel the turns.
def stop_requested(server: Server, poll_ms: Int = STOP_POLL_MS) -> Bool
  while true
    case server.control.stopping.recv(poll_ms)
      ok(now) -> return now
      error(_) -> nil
    end
  end

  false
end

## The stop that a request asked for, from the task that owns the server. The server stops starting work but still
## answers its status and the stop (a second one with `now` cancels the turns); the turns end (cancelled at once with
## `now`, else after `drain_ms` at most, a turn that waits for an approval counts as ended); the sessions are flushed,
## which ends the event streams; then no connection is taken, and the files of the server go. `http_ms` is how long the
## connections that are still open get.
def shutdown(server: Server, now: Bool, http_ms: Int = SHUTDOWN_MS) -> Void
  asked(server.control, now)
  drain(server.sessions, server.control)
  Sessions.stop(server.sessions)
  HTTP.shutdown(server.http, http_ms)
  Extensions.stop_services(server.services)
  _ = Path.remove("#{server.state_dir}/#{SERVER_JSON}")
  _ = File.close(server.lock)
end

def stop(server: Server) -> Void
  Bond.stop(server.http)
  _ = Bond.wait(server.http)
  Sessions.stop(server.sessions)
  Extensions.stop_services(server.services)
  _ = Path.remove("#{server.state_dir}/#{SERVER_JSON}")
  _ = File.close(server.lock)
end

## The routes of the protocol behind the checks, over the sessions: what `start` serves.
def app(token: String, sessions: Sessions.Sessions, control: Control) -> Bond.App
  all = Protocol.SESSIONS_PATH
  one = "#{all}/:id"
  provider = Protocol.auth_path(":provider")
  (
    Bond.app()
    |> Bond.before(->(conn) { ok(guard(token, control, conn)) })
    |> Bond.get(Protocol.HEALTH_PATH, &health)
    |> Bond.get(Protocol.SERVER_PATH, ->(conn) { reply(conn, 200, status(sessions, control)) })
    |> Bond.post(Protocol.SERVER_STOP_PATH, ->(conn) { reply(conn, 200, stop_route(control, conn)) })
    |> Bond.post(all, ->(conn) { reply(conn, 201, create(sessions, conn)) })
    |> Bond.get(all, ->(conn) { reply(conn, 200, list(sessions)) })
    |> Bond.get(Protocol.PROVIDERS_PATH, ->(conn) { reply(conn, 200, providers(sessions)) })
    |> Bond.get(Protocol.AUTH_PATH, ->(conn) { reply(conn, 200, logins(sessions)) })
    |> Bond.delete(Protocol.AUTH_PATH, ->(conn) { reply(conn, 200, logout(sessions, none)) })
    |> Bond.put(Protocol.AUTH_PATH, ->(conn) { reply(conn, 200, skip(sessions)) })
    |> Bond.post(provider, ->(conn) { reply(conn, 200, login(sessions, conn)) })
    |> Bond.get(provider, ->(conn) { reply(conn, 200, device_state(sessions, conn)) })
    |> Bond.delete(provider, ->(conn) { reply(conn, 200, logout(sessions, some(try Bond.param(conn, "provider")))) })
    |> Bond.get(one, ->(conn) { reply(conn, 200, snapshot(sessions, conn)) })
    |> Bond.patch(one, ->(conn) { reply(conn, 200, update(sessions, conn)) })
    |> Bond.delete(one, ->(conn) { reply(conn, 200, delete(sessions, conn)) })
    |> Bond.post("#{one}/messages", ->(conn) { reply(conn, 202, send(sessions, conn)) })
    |> Bond.post("#{one}/compact", ->(conn) { reply(conn, 200, compact(sessions, conn)) })
    |> Bond.get("#{one}/tree", ->(conn) { reply(conn, 200, tree(sessions, conn)) })
    |> Bond.get("#{one}/export", ->(conn) { reply(conn, 200, exported(sessions, conn)) })
    |> Bond.post("#{one}/branch", ->(conn) { reply(conn, 200, branch(sessions, conn)) })
    |> Bond.post("#{one}/fork", ->(conn) { reply(conn, 201, fork(sessions, conn)) })
    |> Bond.post("#{one}/shell", ->(conn) { reply(conn, 202, shell(sessions, conn)) })
    |> Bond.get("#{one}/files", ->(conn) { reply(conn, 200, files(sessions, conn)) })
    |> Bond.get("#{one}/profiles", ->(conn) { reply(conn, 200, profiles(sessions, conn)) })
    |> Bond.get("#{one}/commands", ->(conn) { reply(conn, 200, commands(sessions, conn)) })
    |> Bond.post("#{one}/stop", ->(conn) { reply(conn, 200, stop_turn(sessions, conn)) })
    |> Bond.post("#{one}/approvals/:approval", ->(conn) { reply(conn, 200, approve(sessions, conn)) })
    |> Bond.get("#{one}/events", ->(conn) { events(sessions, conn) })
    |> Bond.not_found(->(conn) { ok(no_route(conn)) })
    |> Bond.after(&answer_405_as_404)
  )
end

private

def serve(options: Config.Options, sessions: Sessions.Sessions, lock: File.Handle) -> Result[Server]
  token = OpenSSL.Random.hex(32)
  control = new_control(options.drain_ms).with(
    approvals: options.asking,
    code_mode: options.code_mode.some?,
    no_worker: options.no_worker,
  )

  http = try Bond.start_with(
    app(token, sessions, control),
    "127.0.0.1",
    options.port,
    HTTP.ServerOptions(max_body_bytes: MAX_BODY_BYTES),
  )

  port = Bond.local_port(http)
  case write_server_json(options.state_dir, Protocol.ServerInfo(port: port, token: token, pid: System.pid))
    ok(_) ->
      ok(
        Server(
          http: http,
          port: port,
          token: token,
          sessions: sessions,
          lock: lock,
          state_dir: options.state_dir,
          control: control,
        ),
      )
    error(e) ->
      Bond.stop(http)
      error(e)
  end
end

def write_server_json(dir: String, info: Protocol.ServerInfo) -> Result[Void]
  path = "#{dir}/#{SERVER_JSON}"
  try Path.remove(path)
  file = try File.open(path, "create_private")
  written = File.write(file, Protocol.encode_server_info(info))
  try File.close(file)
  written
end

def health(conn: Bond.Conn) -> Result[Bond.Conn]
  reply(
    conn,
    200,
    ok(Protocol.encode_health(Protocol.Health(version: Cli.VERSION, wire: some(Protocol.wire_digest())))),
  )
end

def status(sessions: Sessions.Sessions, control: Control) -> Result[String]
  activity = try Sessions.activity(sessions)
  ok(
    Protocol.encode_server_status(
      Protocol.ServerStatus(
        pid: System.pid,
        version: Cli.VERSION,
        started_s: control.started_s,
        sessions: activity.sessions,
        running_turns: activity.running,
        stopping: flag?(control, "draining"),
        approvals: some(control.approvals),
        code_mode: some(control.code_mode),
        no_worker: some(control.no_worker),
      ),
    ),
  )
end

# The answer goes out first: the task that owns the server stops it after, without cutting this request.
def stop_route(control: Control, conn: Bond.Conn) -> Result[String]
  request = try Protocol.decode_stop_server(try String.from_bytes(conn.body))
  asked(control, request.now.unwrap_or(false))
  ok("{}")
end

def asked(control: Control, now: Bool) -> Void
  ATS.put(control.flags, "draining", true)
  if now
    ATS.put(control.flags, "now", true)
  end

  _ = control.stopping.send(now, 0)
end

def flag?(control: Control, name: String) -> Bool = ATS.get(control.flags, name).unwrap_or(false)

# Waits until no session works but on an approval nobody answers now, or `drain_ms` pass, or a stop with `now` comes;
# then cancels what is left and waits for it to end.
def drain(sessions: Sessions.Sessions, control: Control) -> Void
  waited = 0
  while waited < control.drain_ms and not flag?(control, "now") and busy?(sessions)
    Task.sleep(DRAIN_POLL_MS)
    waited = waited + DRAIN_POLL_MS
  end

  _ = Sessions.cancel_turns(sessions)
  ended = 0
  while ended < CANCEL_MS and running?(sessions)
    Task.sleep(DRAIN_POLL_MS)
    ended = ended + DRAIN_POLL_MS
  end
end

def busy?(sessions: Sessions.Sessions) -> Bool
  case Sessions.activity(sessions)
    ok(activity) -> activity.busy > 0
    error(_) -> false
  end
end

def running?(sessions: Sessions.Sessions) -> Bool
  case Sessions.activity(sessions)
    ok(activity) -> activity.running > 0
    error(_) -> false
  end
end

def create(sessions: Sessions.Sessions, conn: Bond.Conn) -> Result[String]
  request = try Protocol.decode_new_session(try String.from_bytes(conn.body))
  id = try Sessions.create(sessions, request)
  profile = case Sessions.snapshot(sessions, id)
    ok(session) -> session.profile
    error(_) -> none
  end

  ok(Protocol.encode_session_created(Protocol.SessionCreated(id: id, profile: profile)))
end

def list(sessions: Sessions.Sessions) -> Result[String]
  ok(Protocol.encode_session_list(Protocol.SessionList(sessions: try Sessions.list(sessions))))
end

def snapshot(sessions: Sessions.Sessions, conn: Bond.Conn) -> Result[String]
  ok(Protocol.encode_session(try Sessions.snapshot(sessions, try Bond.param(conn, "id"))))
end

def update(sessions: Sessions.Sessions, conn: Bond.Conn) -> Result[String]
  change = try Protocol.decode_update_session(try String.from_bytes(conn.body))
  try Sessions.update(sessions, try Bond.param(conn, "id"), change)
  ok("{}")
end

def delete(sessions: Sessions.Sessions, conn: Bond.Conn) -> Result[String]
  try Sessions.delete(sessions, try Bond.param(conn, "id"))
  ok("{}")
end

def send(sessions: Sessions.Sessions, conn: Bond.Conn) -> Result[String]
  message = try Protocol.decode_send_message(try String.from_bytes(conn.body))
  accepted = try Sessions.send(sessions, try Bond.param(conn, "id"), message.text)
  ok(Protocol.encode_message_accepted(accepted))
end

def compact(sessions: Sessions.Sessions, conn: Bond.Conn) -> Result[String]
  compacted = try Sessions.compact(sessions, try Bond.param(conn, "id"))
  ok(Protocol.encode_compacted(Protocol.Compacted(compacted: compacted)))
end

def tree(sessions: Sessions.Sessions, conn: Bond.Conn) -> Result[String]
  ok(Protocol.encode_session_tree(try Sessions.tree(sessions, try Bond.param(conn, "id"))))
end

def exported(sessions: Sessions.Sessions, conn: Bond.Conn) -> Result[String]
  ok(Protocol.encode_session_export(try Sessions.exported(sessions, try Bond.param(conn, "id"))))
end

def branch(sessions: Sessions.Sessions, conn: Bond.Conn) -> Result[String]
  request = try Protocol.decode_branch(try String.from_bytes(conn.body))
  ok(Protocol.encode_branched(try Sessions.branch(sessions, try Bond.param(conn, "id"), request.entry)))
end

def fork(sessions: Sessions.Sessions, conn: Bond.Conn) -> Result[String]
  request = try Protocol.decode_fork(try String.from_bytes(conn.body))
  ok(Protocol.encode_branched(try Sessions.fork(sessions, try Bond.param(conn, "id"), request.entry)))
end

def shell(sessions: Sessions.Sessions, conn: Bond.Conn) -> Result[String]
  request = try Protocol.decode_run_shell(try String.from_bytes(conn.body))
  ok(Protocol.encode_shell_accepted(try Sessions.shell(sessions, try Bond.param(conn, "id"), request)))
end

def stop_turn(sessions: Sessions.Sessions, conn: Bond.Conn) -> Result[String]
  request = try Protocol.decode_stop_turn(try String.from_bytes(conn.body))
  stopped = try Sessions.stop_turn(sessions, try Bond.param(conn, "id"), request.turn_id)
  ok(Protocol.encode_stopped(Protocol.Stopped(stopped: stopped)))
end

def commands(sessions: Sessions.Sessions, conn: Bond.Conn) -> Result[String]
  ok(Protocol.encode_command_list(try Sessions.commands(sessions, try Bond.param(conn, "id"))))
end

def profiles(sessions: Sessions.Sessions, conn: Bond.Conn) -> Result[String]
  ok(Protocol.encode_profile_list(try Sessions.profiles(sessions, try Bond.param(conn, "id"))))
end

def files(sessions: Sessions.Sessions, conn: Bond.Conn) -> Result[String]
  ok(Protocol.encode_file_list(try Sessions.files(sessions, try Bond.param(conn, "id"))))
end

def providers(sessions: Sessions.Sessions) -> Result[String]
  ok(Protocol.encode_provider_list(Sessions.providers(sessions)))
end

def logins(sessions: Sessions.Sessions) -> Result[String]
  listing = try Logins.list(try holder(sessions))
  ok(
    Protocol.encode_login_list(
      Protocol.LoginList(providers: listing.providers.map(&login_status), first: listing.first),
    ),
  )
end

# The key stays in this task and the holder: what goes back is where it is now. `local` takes a base URL instead.
def login(sessions: Sessions.Sessions, conn: Bond.Conn) -> Result[String]
  name = try Bond.param(conn, "provider")
  body = try String.from_bytes(conn.body)
  holder = try holder(sessions)
  if name == Chatgpt.NAME
    device = try Logins.device_start(holder)
    started = Protocol.DeviceLogin(user_code: device.user_code, url: device.url, expires_in: Chatgpt.DEVICE_MS / 1000)
    return ok(Protocol.encode_device_login(started))
  end

  if name == Providers.LOCAL
    request = try Protocol.decode_login_url(body)
    return ok(Protocol.encode_login_status(login_status(try Logins.login_url(holder, name, request.base_url))))
  end

  request = try Protocol.decode_login(body)
  ok(Protocol.encode_login_status(login_status(try Logins.login(holder, name, request.key))))
end

# Only a device login has a state to ask for.
def device_state(sessions: Sessions.Sessions, conn: Bond.Conn) -> Result[String]
  name = try Bond.param(conn, "provider")
  return error("only #{Chatgpt.NAME} has a login to wait for", kind: Protocol.KIND_INVALID) if name != Chatgpt.NAME

  found = try Logins.device_state(try holder(sessions))
  ok(Protocol.encode_device_state(Protocol.DeviceState(state: found.state, message: found.message)))
end

def logout(sessions: Sessions.Sessions, name: Optional[String]) -> Result[String]
  try Logins.logout(try holder(sessions), name)
  ok("{}")
end

def skip(sessions: Sessions.Sessions) -> Result[String]
  try Logins.skip(try holder(sessions))
  ok("{}")
end

def holder(sessions: Sessions.Sessions) -> Result[Logins.Holder]
  sessions.options.logins.to_result("this server has no login")
end

def login_status(found: Logins.Status) -> Protocol.LoginStatus
  Protocol.LoginStatus(
    name: found.name,
    label: found.label,
    key_env: found.key_env,
    from: found.from,
    coming: found.coming,
    asks: found.asks,
    base_url: found.base_url,
  )
end

def approve(sessions: Sessions.Sessions, conn: Bond.Conn) -> Result[String]
  approve = try Protocol.decode_approve(try String.from_bytes(conn.body))
  try Sessions.answer(sessions, try Bond.param(conn, "id"), try Bond.param(conn, "approval"), approve.decision)
  ok("{}")
end

def events(sessions: Sessions.Sessions, conn: Bond.Conn) -> Result[Bond.Conn]
  last: Optional[Int] = none
  for text in HTTP.header_values(conn.headers, Protocol.LAST_EVENT_ID_HEADER.downcase)
    case Protocol.parse_event_id(text)
      ok(value) -> last = some(value)
      error(e) -> return reply(conn, status_of(e.kind), error(e))
    end
  end

  case Sessions.subscribe(sessions, try Bond.param(conn, "id"), last)
    ok(out) -> ok(Bond.header(Bond.sse(conn, out), "content-type", "text/event-stream"))
    error(e) -> reply(conn, status_of(e.kind), error(e))
  end
end

# `Host` must name this machine, so a web page of another name that resolves here (DNS rebinding) is refused. A
# browser sends `Origin`: only a page of this server may call it.
def guard(token: String, control: Control, conn: Bond.Conn) -> Bond.Conn
  host = header(conn, "host")
  return refuse(conn, 403, Protocol.KIND_FORBIDDEN, "host not allowed") if not local_host?(host)

  for origin in HTTP.header_values(conn.headers, "origin")
    return refuse(conn, 403, Protocol.KIND_FORBIDDEN, "origin not allowed") if origin != "http://#{host}"
  end

  given = header(conn, "authorization")
  if not OpenSSL.HMAC.secure_compare(given.bytes, "Bearer #{token}".bytes)
    return refuse(conn, 401, Protocol.KIND_UNAUTHORIZED, "missing or wrong token")
  end

  if flag?(control, "draining") and starts_work?(conn)
    return refuse(conn, 503, Protocol.KIND_SERVER_STOPPING, "the server is stopping")
  end

  conn
end

# A request that would start a session, a turn, a shell command, a compaction or a branch.
def starts_work?(conn: Bond.Conn) -> Bool
  return false if conn.method != "POST"

  (
    conn.path == Protocol.SESSIONS_PATH or
    ["/messages", "/shell", "/compact", "/branch", "/fork"].any? { |end_| conn.path.end_with?(end_) }
  )
end

# A repeated header is refused as a wrong one.
def header(conn: Bond.Conn, name: String) -> String
  values = HTTP.header_values(conn.headers, name)
  return "" if values.size != 1

  values[0]
end

def local_host?(host: String) -> Bool
  name = host.split(":").first
  ["127.0.0.1", "localhost"].include?(name) and host.split(":").size <= 2
end

# A path with a route for other methods is a 404 of the protocol, not a 405.
def answer_405_as_404(conn: Bond.Conn) -> Result[Bond.Conn]
  return ok(no_route(conn)) if conn.status == 405

  ok(conn)
end

def no_route(conn: Bond.Conn) -> Bond.Conn
  json(conn, 404, failure_text("not_found", "no route for #{conn.method} #{conn.path}"))
end

def reply(conn: Bond.Conn, status: Int, body: Result[String]) -> Result[Bond.Conn]
  case body
    ok(text) -> ok(json(conn, status, text))
    error(e) -> ok(failure(conn, e))
  end
end

def failure(conn: Bond.Conn, e: Error) -> Bond.Conn
  # A request that reached a session as it was deleted.
  return refuse(conn, 404, Protocol.KIND_SESSION_NOT_FOUND, "session deleted") if e.kind == "channel.gone"

  json(conn, status_of(e.kind), failure_text(e.kind, e.message))
end

def status_of(kind: String) -> Int
  return 400 if [Protocol.KIND_INVALID, Protocol.KIND_UNKNOWN, Protocol.KIND_LOGIN_REJECTED].include?(kind)
  return 403 if kind == Protocol.KIND_SHELL_DENIED
  return 404 if [Protocol.KIND_SESSION_NOT_FOUND, Protocol.KIND_APPROVAL_NOT_FOUND].include?(kind)
  return 409 if [Protocol.KIND_SESSION_BUSY, Protocol.KIND_APPROVAL_RESOLVED].include?(kind)
  return 503 if kind == Protocol.KIND_SESSION_UNAVAILABLE

  500
end

def refuse(conn: Bond.Conn, status: Int, kind: String, message: String) -> Bond.Conn
  json(conn, status, failure_text(kind, message)).with(halted: true)
end

def failure_text(kind: String, message: String) -> String
  Protocol.encode_failure(Protocol.Failure(kind: kind, message: message))
end

def json(conn: Bond.Conn, status: Int, text: String) -> Bond.Conn
  Bond.header(Bond.text(conn, status, text), "content-type", "application/json")
end
