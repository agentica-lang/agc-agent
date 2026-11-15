## The HTTP API of the agent on 127.0.0.1: the routes of the protocol, the event stream of each session, and the
## checks in front of them (`Host`, `Origin`, the Bearer token).
##
## The state folder (0700) holds `server.json` (0600, `Protocol.ServerInfo`) for the clients and `core.lock`, which
## the running server holds locked so that a second one does not start. A client holds `server.lock` while it starts
## a server, so the server takes another file.

import Actor from "std/actor"
import HTTP from "std/http"
import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import Session from "session"
import Tools from "tools"

VERSION = "0.0.1"
SERVER_JSON = "server.json"
LOCK_FILE = "core.lock"
MAX_BODY_BYTES = 1_048_576
CALL_MS = 5000
SYSTEM_PROMPT = <<~TEXT
  You are a coding agent. You work in the session folder with the tools you have: read before you change a file, keep
  changes small, and say briefly what you did.
TEXT

SSE_HEADERS = [
  HTTP.Header(name: "Content-Type", value: "text/event-stream"),
  HTTP.Header(name: "Cache-Control", value: "no-cache"),
]

struct Options
  state_dir: String
  provider: LLM.Provider
  model: String
  env: Fn[String, Result[String]]
  rules: Tools.Rules
  port: Int = 0
  keep_events: Int = 1000
  approval_timeout_ms: Int = 90000
end

struct Server
  http: HTTP.Server
  port: Int
  token: String
  registry: Actor.Ref[Registry, Msg]
  lock: File.Handle
  state_dir: String
end

## Starts the server in the calling task, which owns it: call it from the task that keeps it.
def start(options: Options) -> Result[Server]
  try state_folder(options.state_dir)
  lock = try File.open("#{options.state_dir}/#{LOCK_FILE}", "append")
  return error("a server already runs for #{options.state_dir}") if not try File.try_lock(lock, 1000)

  token = OpenSSL.Random.hex(32)
  behaviour = Actor.Behaviour(init: -> { Registry(options: options) }, handle: &handle, terminate: some(&terminate))
  registry = Actor.start(behaviour)
  address = registry.address
  http = try HTTP.serve(
    "127.0.0.1",
    options.port,
    ->(request, body) { route(token, address, request, body) },
    HTTP.ServerOptions(max_body_bytes: MAX_BODY_BYTES),
  )

  port = HTTP.local_port(http)
  try write_server_json(options.state_dir, Protocol.ServerInfo(port: port, token: token, pid: System.pid))
  ok(Server(http: http, port: port, token: token, registry: registry, lock: lock, state_dir: options.state_dir))
end

def stop(server: Server) -> Void
  HTTP.close_server(server.http)
  _ = Actor.stop(server.registry, CALL_MS)
  _ = Path.remove("#{server.state_dir}/#{SERVER_JSON}")
  _ = File.close(server.lock)
end

private

struct Entry
  summary: Protocol.SessionSummary
  session: Actor.Ref[Session.State, Session.Msg]
end

struct Registry
  options: Options
  sessions: List[Entry] = []
end

enum Msg
  Create(Protocol.NewSession, Channel[Result[String]])
  Find(String, Channel[Optional[Address[Session.Msg]]])
  List(Channel[Protocol.SessionList])
end

def state_folder(path: String) -> Result[Void]
  if not File.stat(path).ok?
    try Dir.mkdir_private(path)
  end

  info = try File.stat(path)
  return error("#{path} is not a folder") if info.kind != "directory"
  return error("#{path} must be private (mode 0700), it has mode #{info.mode}") if info.mode % 64 != 0

  ok()
end

def write_server_json(dir: String, info: Protocol.ServerInfo) -> Result[Void]
  path = "#{dir}/#{SERVER_JSON}"
  try Path.remove(path)
  file = try File.open(path, "create_private")
  written = File.write(file, Protocol.encode_server_info(info))
  try File.close(file)
  written
end

def terminate(registry: Registry) -> Void
  for entry in registry.sessions
    _ = Actor.stop(entry.session, CALL_MS)
  end
end

def handle(registry: Registry, msg: Msg) -> Actor.Step[Registry]
  case msg
    Msg.Create(request, reply) ->
      case open_session(registry, request)
        ok(entry) ->
          Actor.reply(reply, ok(entry.summary.id))
          Actor.continue(registry.with(sessions: registry.sessions.push(entry)))
        error(e) ->
          Actor.reply(reply, error(e))
          Actor.continue(registry)
      end

    Msg.Find(id, reply) ->
      found = registry.sessions.select { |entry| entry.summary.id == id }.map { |entry| entry.session.address }
      address: Optional[Address[Session.Msg]] = none
      if not found.empty?
        address = some(found[0])
      end

      Actor.reply(reply, address)
      Actor.continue(registry)
    Msg.List(reply) ->
      Actor.reply(reply, Protocol.SessionList(sessions: registry.sessions.map { |entry| entry.summary }))
      Actor.continue(registry)
  end
end

def open_session(registry: Registry, request: Protocol.NewSession) -> Result[Entry]
  options = registry.options
  ctx = case Tools.context(request.cwd, options.env, options.rules)
    ok(ctx) -> ok(ctx)
    error(e) -> error("cwd: #{e.message}", kind: Protocol.KIND_INVALID)
  end

  context = try ctx
  id = "s#{registry.sessions.size + 1}-#{OpenSSL.Random.hex(4)}"
  model = request.model.unwrap_or(options.model)
  setup = Session.Setup(
    id: id,
    cwd: context.root,
    model: model,
    provider: options.provider,
    system: system_prompt(context.root),
    ctx: context,
    keep_events: options.keep_events,
    approval_timeout_ms: options.approval_timeout_ms,
  )

  summary = Protocol.SessionSummary(id: id, cwd: context.root, model: model)
  ok(Entry(summary: summary, session: Session.start(setup)))
end

def system_prompt(root: String) -> String
  case File.read_text("#{root}/AGENTS.md")
    ok(text) -> "#{SYSTEM_PROMPT}\n# AGENTS.md of the session folder\n\n#{text}"
    error(_) -> SYSTEM_PROMPT
  end
end

def route(token: String, registry: Address[Msg], request: HTTP.Request, body: HTTP.RequestBody) -> Result[HTTP.Answer]
  for refusal in option_list(refused(token, request))
    return ok(HTTP.Answer.Whole(refusal))
  end

  parts = request.path.split("/").drop(1)
  if request.method == "GET" and request.path == Protocol.HEALTH_PATH
    return whole(200, Protocol.encode_health(Protocol.Health(version: VERSION)))
  end

  return events(registry, request, parts[2]) if request.method == "GET" and parts.size == 4 and parts[3] == "events"

  case HTTP.read_all(body, MAX_BODY_BYTES)
    ok(bytes) -> ok(HTTP.Answer.Whole(answered(registry, request.method, parts, bytes)))
    error(e) -> ok(HTTP.body_refusal(e.message))
  end
end

def answered(registry: Address[Msg], method: String, parts: List[String], bytes: Bytes) -> HTTP.Response
  case answer(registry, method, parts, bytes)
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

def answer(registry: Address[Msg], method: String, parts: List[String], bytes: Bytes) -> Result[HTTP.Response]
  text = try String.from_bytes(bytes)
  case "#{method} #{parts.size}"
    "POST 2" if parts[1] == "sessions" ->
      request = try Protocol.decode_new_session(text)
      created: Result[Result[String]] = Actor.call(registry, CALL_MS) do |reply| Msg.Create(request, reply) end
      id = try try created
      response(201, Protocol.encode_session_created(Protocol.SessionCreated(id: id)))
    "GET 2" if parts[1] == "sessions" ->
      list: Result[Protocol.SessionList] = Actor.call(registry, CALL_MS) do |reply| Msg.List(reply) end
      response(200, Protocol.encode_session_list(try list))
    "GET 3" -> response(200, Protocol.encode_session(try Session.snapshot(try find(registry, parts[2]))))
    "POST 4" if parts[3] == "messages" ->
      message = try Protocol.decode_send_message(text)
      turn_id = try Session.send(try find(registry, parts[2]), message.text)
      response(202, Protocol.encode_message_accepted(Protocol.MessageAccepted(turn_id: turn_id)))
    "POST 4" if parts[3] == "stop" ->
      _ = try Session.stop(try find(registry, parts[2]))
      response(200, "{}")
    "POST 5" if parts[3] == "approvals" ->
      approve = try Protocol.decode_approve(text)
      try Session.answer(try find(registry, parts[2]), parts[4], approve.decision)
      response(200, "{}")
    _ -> ok(failure_response(404, "not_found", "no route for #{method} /#{parts.join("/")}"))
  end
end

def events(registry: Address[Msg], request: HTTP.Request, id: String) -> Result[HTTP.Answer]
  last: Optional[Int] = none
  for text in HTTP.header_values(request.headers, Protocol.LAST_EVENT_ID_HEADER.downcase)
    case Protocol.parse_event_id(text)
      ok(value) -> last = some(value)
      error(e) -> return ok(HTTP.Answer.Whole(failure(e)))
    end
  end

  case subscribe(registry, id, last)
    ok(out) -> ok(HTTP.Answer.Stream(HTTP.StreamResponse(status: 200, headers: SSE_HEADERS, body: out)))
    error(e) -> ok(HTTP.Answer.Whole(failure(e)))
  end
end

def subscribe(registry: Address[Msg], id: String, last: Optional[Int]) -> Result[Channel[Bytes]]
  Session.subscribe(try find(registry, id), last)
end

def find(registry: Address[Msg], id: String) -> Result[Address[Session.Msg]]
  found: Result[Optional[Address[Session.Msg]]] = Actor.call(registry, CALL_MS) do |reply| Msg.Find(id, reply) end
  case try found
    some(address) -> ok(address)
    none -> error("no session #{id}", kind: Protocol.KIND_SESSION_NOT_FOUND)
  end
end

def failure(e: Error) -> HTTP.Response = failure_response(status_of(e.kind), e.kind, e.message)

def status_of(kind: String) -> Int
  return 400 if [Protocol.KIND_INVALID, Protocol.KIND_UNKNOWN].include?(kind)
  return 404 if [Protocol.KIND_SESSION_NOT_FOUND, Protocol.KIND_APPROVAL_NOT_FOUND].include?(kind)
  return 409 if [Protocol.KIND_SESSION_BUSY, Protocol.KIND_APPROVAL_RESOLVED].include?(kind)

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
