## The HTTP API of the agent on 127.0.0.1: the routes of the protocol, the event stream of each session, and the
## checks in front of them (`Host`, `Origin`, the Bearer token). The sessions are `Sessions`.
##
## The state folder (0700) holds `server.json` (0600, `Protocol.ServerInfo`) for the clients and `core.lock`, which
## the running server holds locked so that a second one does not start. A client holds `server.lock` while it starts
## a server, so the server takes another file.

import HTTP from "std/http"
import Protocol from "pkg/protocol/protocol"
import Config from "../config/config"
import Sessions from "../session/session"

VERSION = "0.0.1"
SERVER_JSON = "server.json"
LOCK_FILE = "core.lock"
MAX_BODY_BYTES = 1_048_576
SSE_HEADERS = [
  HTTP.Header(name: "Content-Type", value: "text/event-stream"),
  HTTP.Header(name: "Cache-Control", value: "no-cache"),
]

struct Server
  http: HTTP.Server
  port: Int
  token: String
  sessions: Sessions.Sessions
  lock: File.Handle
  state_dir: String
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

def stop(server: Server) -> Void
  HTTP.close_server(server.http)
  _ = HTTP.wait(server.http)
  Sessions.stop(server.sessions)
  _ = Path.remove("#{server.state_dir}/#{SERVER_JSON}")
  _ = File.close(server.lock)
end

private

def serve(options: Config.Options, sessions: Sessions.Sessions, lock: File.Handle) -> Result[Server]
  token = OpenSSL.Random.hex(32)
  http = try HTTP.serve(
    "127.0.0.1",
    options.port,
    ->(request, body) { route(token, sessions, request, body) },
    HTTP.ServerOptions(max_body_bytes: MAX_BODY_BYTES),
  )

  port = HTTP.local_port(http)
  case write_server_json(options.state_dir, Protocol.ServerInfo(port: port, token: token, pid: System.pid))
    ok(_) ->
      ok(Server(http: http, port: port, token: token, sessions: sessions, lock: lock, state_dir: options.state_dir))
    error(e) ->
      HTTP.close_server(http)
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

def route(
  token: String,
  sessions: Sessions.Sessions,
  request: HTTP.Request,
  body: HTTP.RequestBody,
) -> Result[HTTP.Answer]
  for refusal in option_list(refused(token, request))
    return ok(HTTP.Answer.Whole(refusal))
  end

  if request.method == "GET" and request.path == Protocol.HEALTH_PATH
    return whole(200, Protocol.encode_health(Protocol.Health(version: VERSION, wire: some(Protocol.wire_digest()))))
  end

  prefix = Protocol.SESSIONS_PATH
  if request.path != prefix and not request.path.start_with?("#{prefix}/")
    return ok(HTTP.Answer.Whole(no_route(request.method, request.path)))
  end

  # The parts after /v1/sessions: an id, then a sub-resource.
  parts = request.path.slice(prefix.length, request.path.length - prefix.length).split("/").drop(1)
  return events(sessions, request, parts[0]) if request.method == "GET" and parts.size == 2 and parts[1] == "events"

  case HTTP.read_all(body, MAX_BODY_BYTES)
    ok(bytes) -> ok(HTTP.Answer.Whole(answered(sessions, request.method, parts, bytes)))
    error(e) -> ok(HTTP.body_refusal(e.message))
  end
end

def answered(sessions: Sessions.Sessions, method: String, parts: List[String], bytes: Bytes) -> HTTP.Response
  case answer(sessions, method, parts, bytes)
    ok(response) -> response
    error(e) -> failure(e)
  end
end

# `Host` must name this machine, so a web page of another name that resolves here (DNS rebinding) is refused. A
# browser sends `Origin`: only a page of this server may call it.
def refused(token: String, request: HTTP.Request) -> Optional[HTTP.Response]
  host = header(request, "host")
  return some(failure_response(403, Protocol.KIND_FORBIDDEN, "host not allowed")) if not local_host?(host)

  for origin in HTTP.header_values(request.headers, "origin")
    return some(failure_response(403, Protocol.KIND_FORBIDDEN, "origin not allowed")) if origin != "http://#{host}"
  end

  given = header(request, "authorization")
  if not OpenSSL.HMAC.secure_compare(given.bytes, "Bearer #{token}".bytes)
    return some(failure_response(401, Protocol.KIND_UNAUTHORIZED, "missing or wrong token"))
  end

  none
end

# A repeated header is refused as a wrong one.
def header(request: HTTP.Request, name: String) -> String
  values = HTTP.header_values(request.headers, name)
  return "" if values.size != 1

  values[0]
end

def local_host?(host: String) -> Bool
  name = host.split(":").first
  ["127.0.0.1", "localhost"].include?(name) and host.split(":").size <= 2
end

def answer(sessions: Sessions.Sessions, method: String, parts: List[String], bytes: Bytes) -> Result[HTTP.Response]
  text = try String.from_bytes(bytes)
  case "#{method} #{parts.size}"
    "POST 0" ->
      request = try Protocol.decode_new_session(text)
      id = try Sessions.create(sessions, request)
      response(201, Protocol.encode_session_created(Protocol.SessionCreated(id: id)))
    "GET 0" -> response(200, Protocol.encode_session_list(Protocol.SessionList(sessions: try Sessions.list(sessions))))
    "DELETE 1" ->
      try Sessions.delete(sessions, parts[0])
      response(200, "{}")
    "GET 1" -> response(200, Protocol.encode_session(try Sessions.snapshot(sessions, parts[0])))
    "POST 2" if parts[1] == "messages" ->
      message = try Protocol.decode_send_message(text)
      accepted = try Sessions.send(sessions, parts[0], message.text)
      response(202, Protocol.encode_message_accepted(accepted))
    "PATCH 1" ->
      change = try Protocol.decode_update_session(text)
      try Sessions.update(sessions, parts[0], change)
      response(200, "{}")
    "POST 2" if parts[1] == "compact" ->
      compacted = try Sessions.compact(sessions, parts[0])
      response(200, Protocol.encode_compacted(Protocol.Compacted(compacted: compacted)))
    "GET 2" if parts[1] == "tree" -> response(200, Protocol.encode_session_tree(try Sessions.tree(sessions, parts[0])))
    "POST 2" if parts[1] == "branch" ->
      request = try Protocol.decode_branch(text)
      response(200, Protocol.encode_branched(try Sessions.branch(sessions, parts[0], request.entry)))
    "POST 2" if parts[1] == "fork" ->
      request = try Protocol.decode_fork(text)
      response(201, Protocol.encode_branched(try Sessions.fork(sessions, parts[0], request.entry)))
    "POST 2" if parts[1] == "stop" ->
      _ = try Sessions.stop_turn(sessions, parts[0])
      response(200, "{}")
    "POST 3" if parts[1] == "approvals" ->
      approve = try Protocol.decode_approve(text)
      try Sessions.answer(sessions, parts[0], parts[2], approve.decision)
      response(200, "{}")
    _ -> ok(no_route(method, "#{Protocol.SESSIONS_PATH}/#{parts.join("/")}"))
  end
end

def events(sessions: Sessions.Sessions, request: HTTP.Request, id: String) -> Result[HTTP.Answer]
  last: Optional[Int] = none
  for text in HTTP.header_values(request.headers, Protocol.LAST_EVENT_ID_HEADER.downcase)
    case Protocol.parse_event_id(text)
      ok(value) -> last = some(value)
      error(e) -> return ok(HTTP.Answer.Whole(failure(e)))
    end
  end

  case Sessions.subscribe(sessions, id, last)
    ok(out) -> ok(HTTP.Answer.Stream(HTTP.StreamResponse(status: 200, headers: SSE_HEADERS, body: out)))
    error(e) -> ok(HTTP.Answer.Whole(failure(e)))
  end
end

def no_route(method: String, path: String) -> HTTP.Response
  failure_response(404, "not_found", "no route for #{method} #{path}")
end

def failure(e: Error) -> HTTP.Response
  # A request that reached a session as it was deleted.
  return failure_response(404, Protocol.KIND_SESSION_NOT_FOUND, "session deleted") if e.kind == "channel.gone"

  failure_response(status_of(e.kind), e.kind, e.message)
end

def status_of(kind: String) -> Int
  return 400 if [Protocol.KIND_INVALID, Protocol.KIND_UNKNOWN].include?(kind)
  return 404 if [Protocol.KIND_SESSION_NOT_FOUND, Protocol.KIND_APPROVAL_NOT_FOUND].include?(kind)
  return 409 if [Protocol.KIND_SESSION_BUSY, Protocol.KIND_APPROVAL_RESOLVED].include?(kind)
  return 503 if kind == Protocol.KIND_SESSION_UNAVAILABLE

  500
end

def failure_response(status: Int, kind: String, message: String) -> HTTP.Response
  json_response(status, Protocol.encode_failure(Protocol.Failure(kind: kind, message: message)))
end

def response(status: Int, text: String) -> Result[HTTP.Response] = ok(json_response(status, text))

def whole(status: Int, text: String) -> Result[HTTP.Answer] = ok(HTTP.Answer.Whole(json_response(status, text)))

def json_response(status: Int, text: String) -> HTTP.Response
  HTTP.Response(
    status: status,
    headers: [HTTP.Header(name: "Content-Type", value: "application/json")],
    body: text.bytes,
  )
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
