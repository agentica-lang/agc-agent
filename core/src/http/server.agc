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
import Sessions from "../session/session"

VERSION = "0.0.1"
SERVER_JSON = "server.json"
LOCK_FILE = "core.lock"
MAX_BODY_BYTES = 1_048_576
## A stop waits this long for the running turns to end, then cancels them.
DRAIN_MS = 60_000
DRAIN_POLL_MS = 100
## Then the connections that are still open (event streams) are closed.
SHUTDOWN_MS = 5000

## What the routes of the server control share with the task that owns it: a stop request, as `now`, and the start.
struct Control
  stopping: Channel[Bool]
  started_s: Int
end

struct Server
  http: HTTP.Server
  port: Int
  token: String
  sessions: Sessions.Sessions
  lock: File.Handle
  state_dir: String
  control: Control
end

## Starts the server in the calling task, which owns it: call it from the task that keeps it.
def start(options: Config.Options) -> Result[Server]
  try private_folder(options.state_dir)
  try private_folder(options.data_dir)
  try private_folder(Sessions.folder(options))
  lock = try File.open("#{options.state_dir}/#{LOCK_FILE}", "append")
  locked = File.try_lock(lock, 1000)
  if locked != ok(true)
    _ = File.close(lock)
    return error("a server already runs for #{options.state_dir}")
  end

  sessions = Sessions.start(options)
  started = serve(options, sessions, lock)
  if not started.ok?
    Sessions.stop(sessions)
    _ = File.close(lock)
  end

  started
end

def new_control() -> Control = Control(stopping: Channel.new(1), started_s: Time.now_ms / 1000)

## Waits for `POST /v1/server/stop`: whether it asks to cancel the running turns.
def stop_requested(server: Server) -> Bool
  case server.control.stopping.recv(86_400_000)
    ok(now) -> now
    error(_) -> false
  end
end

## The stop that a request asked for, from the task that owns the server: no new connection, the turns end (cancelled
## at once with `now`, else after `DRAIN_MS` at most), the sessions are flushed, and the files of the server go.
def shutdown(server: Server, now: Bool) -> Void
  drain = Task.spawn(-> { drained(server.sessions, now) })
  HTTP.shutdown(server.http, SHUTDOWN_MS)
  Task.await(drain)
  _ = Path.remove("#{server.state_dir}/#{SERVER_JSON}")
  _ = File.close(server.lock)
end

def stop(server: Server) -> Void
  Bond.stop(server.http)
  _ = Bond.wait(server.http)
  Sessions.stop(server.sessions)
  _ = Path.remove("#{server.state_dir}/#{SERVER_JSON}")
  _ = File.close(server.lock)
end

## The routes of the protocol behind the checks, over the sessions: what `start` serves.
def app(token: String, sessions: Sessions.Sessions, control: Control) -> Bond.App
  all = Protocol.SESSIONS_PATH
  one = "#{all}/:id"
  (
    Bond.app()
    |> Bond.before(->(conn) { ok(guard(token, conn)) })
    |> Bond.get(Protocol.HEALTH_PATH, &health)
    |> Bond.get(Protocol.SERVER_PATH, ->(conn) { reply(conn, 200, status(sessions, control)) })
    |> Bond.post(Protocol.SERVER_STOP_PATH, ->(conn) { reply(conn, 200, request_stop(control, conn)) })
    |> Bond.post(all, ->(conn) { reply(conn, 201, create(sessions, conn)) })
    |> Bond.get(all, ->(conn) { reply(conn, 200, list(sessions)) })
    |> Bond.get(one, ->(conn) { reply(conn, 200, snapshot(sessions, conn)) })
    |> Bond.patch(one, ->(conn) { reply(conn, 200, update(sessions, conn)) })
    |> Bond.delete(one, ->(conn) { reply(conn, 200, delete(sessions, conn)) })
    |> Bond.post("#{one}/messages", ->(conn) { reply(conn, 202, send(sessions, conn)) })
    |> Bond.post("#{one}/compact", ->(conn) { reply(conn, 200, compact(sessions, conn)) })
    |> Bond.get("#{one}/tree", ->(conn) { reply(conn, 200, tree(sessions, conn)) })
    |> Bond.post("#{one}/branch", ->(conn) { reply(conn, 200, branch(sessions, conn)) })
    |> Bond.post("#{one}/fork", ->(conn) { reply(conn, 201, fork(sessions, conn)) })
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
  control = new_control()
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

def private_folder(given: String) -> Result[Void]
  path = try Path.resolve(given)
  if not File.stat(path).ok?
    try Dir.mkdir(parent(path))
    try Dir.mkdir_private(path)
  end

  info = try File.stat(path)
  return error("#{path} is not a folder") if info.kind != "directory"
  return error("#{path} must be private (mode 0700), it has mode #{info.mode}") if info.mode % 64 != 0

  for me in option_list(owner_id())
    return error("#{path} is not owned by you") if info.user_id != me
  end

  ok()
end

def parent(path: String) -> String
  parts = path.split("/")
  return "/" if parts.size <= 2

  parts.take(parts.size - 1).join("/")
end

# The user id of this process, from the owner of its /proc entry or of the home folder; none where neither is there.
def owner_id() -> Optional[Int]
  for place in ["/proc/self", System.env("HOME").unwrap_or("")]
    case File.stat(place)
      ok(info) if place != "" -> return some(info.user_id)
      _ -> nil
    end
  end

  none
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
  reply(conn, 200, ok(Protocol.encode_health(Protocol.Health(version: VERSION, wire: some(Protocol.wire_digest())))))
end

def status(sessions: Sessions.Sessions, control: Control) -> Result[String]
  activity = try Sessions.activity(sessions)
  ok(
    Protocol.encode_server_status(
      Protocol.ServerStatus(
        pid: System.pid,
        version: VERSION,
        started_s: control.started_s,
        sessions: activity.sessions,
        running_turns: activity.running_turns,
      ),
    ),
  )
end

# The answer goes out first: the task that owns the server stops it after, without cutting this request.
def request_stop(control: Control, conn: Bond.Conn) -> Result[String]
  request = try Protocol.decode_stop_server(try String.from_bytes(conn.body))
  _ = control.stopping.send(request.now, 0)
  ok("{}")
end

def drained(sessions: Sessions.Sessions, now: Bool) -> Void
  if now
    _ = Sessions.cancel_turns(sessions)
  end

  waited = 0
  while waited < DRAIN_MS and running?(sessions)
    Task.sleep(DRAIN_POLL_MS)
    waited = waited + DRAIN_POLL_MS
  end

  _ = Sessions.cancel_turns(sessions)
  Sessions.stop(sessions)
end

def running?(sessions: Sessions.Sessions) -> Bool
  case Sessions.activity(sessions)
    ok(activity) -> activity.running_turns > 0
    error(_) -> false
  end
end

def create(sessions: Sessions.Sessions, conn: Bond.Conn) -> Result[String]
  request = try Protocol.decode_new_session(try String.from_bytes(conn.body))
  id = try Sessions.create(sessions, request)
  ok(Protocol.encode_session_created(Protocol.SessionCreated(id: id)))
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

def branch(sessions: Sessions.Sessions, conn: Bond.Conn) -> Result[String]
  request = try Protocol.decode_branch(try String.from_bytes(conn.body))
  ok(Protocol.encode_branched(try Sessions.branch(sessions, try Bond.param(conn, "id"), request.entry)))
end

def fork(sessions: Sessions.Sessions, conn: Bond.Conn) -> Result[String]
  request = try Protocol.decode_fork(try String.from_bytes(conn.body))
  ok(Protocol.encode_branched(try Sessions.fork(sessions, try Bond.param(conn, "id"), request.entry)))
end

def stop_turn(sessions: Sessions.Sessions, conn: Bond.Conn) -> Result[String]
  _ = try Sessions.stop_turn(sessions, try Bond.param(conn, "id"))
  ok("{}")
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
def guard(token: String, conn: Bond.Conn) -> Bond.Conn
  host = header(conn, "host")
  return refuse(conn, 403, Protocol.KIND_FORBIDDEN, "host not allowed") if not local_host?(host)

  for origin in HTTP.header_values(conn.headers, "origin")
    return refuse(conn, 403, Protocol.KIND_FORBIDDEN, "origin not allowed") if origin != "http://#{host}"
  end

  given = header(conn, "authorization")
  if not OpenSSL.HMAC.secure_compare(given.bytes, "Bearer #{token}".bytes)
    return refuse(conn, 401, Protocol.KIND_UNAUTHORIZED, "missing or wrong token")
  end

  conn
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
  return 400 if [Protocol.KIND_INVALID, Protocol.KIND_UNKNOWN].include?(kind)
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

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
