## The HTTP API of the agent on 127.0.0.1: the routes of the protocol, the event stream of each session, and the
## checks in front of them (`Host`, `Origin`, the Bearer token).
##
## The state folder (0700) holds `server.json` (0600, `Protocol.ServerInfo`) for the clients and `core.lock`, which
## the running server holds locked so that a second one does not start. A client holds `server.lock` while it starts
## a server, so the server takes another file.
##
## The sessions live in `sessions/` of the data folder (0700), one file each (`Store`). At start the server reads only
## the first line of each file, for the list; a session is loaded from its file on its first request.

import Actor from "std/actor"
import HTTP from "std/http"
import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import Sandbox from "sandbox"
import Session from "session"
import Store from "store"
import Tools from "tools"

VERSION = "0.0.1"
SERVER_JSON = "server.json"
SESSIONS_DIR = "sessions"
LOCK_FILE = "core.lock"
MAX_BODY_BYTES = 1_048_576
MAX_INSTRUCTIONS_BYTES = 65_536
MAX_READ_BYTES = 1_048_576
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
  data_dir: String
  provider: LLM.Provider
  model: String
  env: Fn[String, Result[String]]
  rules: Tools.Rules
  port: Int = 0
  keep_events: Int = 1000
  approval_timeout_ms: Int = 90000
  ## The model's window in tokens; none asks the provider (`GET /models`).
  context_window: Optional[Int] = none
  ## The model that writes the summary of a compaction; empty is the session's model.
  compact_model: String = ""
  ## llama-server's `/props`, asked for the window before `GET /models`; empty for another API.
  props_url: String = ""
  ## The key `/props` takes, as the provider's.
  api_key: String = ""
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
  try private_folder(options.state_dir)
  try private_folder(options.data_dir)
  try private_folder(sessions_dir(options))
  lock = try File.open("#{options.state_dir}/#{LOCK_FILE}", "append")
  locked = File.try_lock(lock, 1000)
  if locked != ok(true)
    _ = File.close(lock)
    return error("a server already runs for #{options.state_dir}")
  end

  init = -> { Registry(options: options, sessions: load_sessions(options)) }
  behaviour = Actor.Behaviour(init: init, handle: &handle, terminate: some(&terminate))
  registry = Actor.start(behaviour)
  started = serve(options, registry, lock)
  if not started.ok?
    _ = Actor.stop(registry, CALL_MS)
    _ = File.close(lock)
  end

  started
end

def stop(server: Server) -> Void
  HTTP.close_server(server.http)
  _ = HTTP.wait(server.http)
  _ = Actor.stop(server.registry, CALL_MS)
  _ = Path.remove("#{server.state_dir}/#{SERVER_JSON}")
  _ = File.close(server.lock)
end

private

struct Entry
  summary: Protocol.SessionSummary
  header: Store.Header
  file: String
  ## None until the session is first used.
  session: Optional[Actor.Ref[Session.State, Session.Msg]]
end

struct Listed
  file: String
  header: Store.Header
end

struct Registry
  options: Options
  sessions: List[Entry] = []
end

enum Msg
  Create(Protocol.NewSession, Channel[Result[String]])
  Find(String, Channel[Result[Address[Session.Msg]]])
  Delete(String, Channel[Result[Void]])
  List(Channel[Protocol.SessionList])
end

def serve(options: Options, registry: Actor.Ref[Registry, Msg], lock: File.Handle) -> Result[Server]
  token = OpenSSL.Random.hex(32)
  address = registry.address
  http = try HTTP.serve(
    "127.0.0.1",
    options.port,
    ->(request, body) { route(token, address, request, body) },
    HTTP.ServerOptions(max_body_bytes: MAX_BODY_BYTES),
  )

  port = HTTP.local_port(http)
  case write_server_json(options.state_dir, Protocol.ServerInfo(port: port, token: token, pid: System.pid))
    ok(_) ->
      ok(Server(http: http, port: port, token: token, registry: registry, lock: lock, state_dir: options.state_dir))
    error(e) ->
      HTTP.close_server(http)
      error(e)
  end
end

def private_folder(given: String) -> Result[Void]
  path = try Path.resolve(given)
  if not File.stat(path).ok?
    try Dir.mkdir(Sandbox.parent(path))
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

def terminate(registry: Registry) -> Void
  for entry in registry.sessions
    for session in option_list(entry.session)
      _ = Actor.stop(session, CALL_MS)
    end
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
      found = registry.sessions.select { |entry| entry.summary.id == id }
      if found.empty?
        Actor.reply(reply, error("no session #{id}", kind: Protocol.KIND_SESSION_NOT_FOUND))
        return Actor.continue(registry)
      end

      case started(registry.options, found[0])
        ok(entry) ->
          Actor.reply(reply, entry.session.map { |session| session.address }.to_result("not started"))
          Actor.continue(registry.with(sessions: registry.sessions.map { |e| replaced(e, entry) }))
        error(e) ->
          message = "session #{id} cannot be loaded now: #{e.message}"
          IO.warn(message)
          Actor.reply(reply, error(message, kind: Protocol.KIND_SESSION_UNAVAILABLE))
          Actor.continue(registry)
      end

    Msg.Delete(id, reply) ->
      case delete_session(registry, id)
        ok(_) ->
          Actor.reply(reply, ok())
          Actor.continue(registry.with(sessions: registry.sessions.select { |entry| entry.summary.id != id }))
        error(e) ->
          Actor.reply(reply, error(e))
          Actor.continue(registry)
      end

    Msg.List(reply) ->
      Actor.reply(reply, Protocol.SessionList(sessions: registry.sessions.map { |entry| entry.summary }))
      Actor.continue(registry)
  end
end

def sessions_dir(options: Options) -> String = "#{options.data_dir}/#{SESSIONS_DIR}"

def open_session(registry: Registry, request: Protocol.NewSession) -> Result[Entry]
  options = registry.options
  ctx = case Tools.context(request.cwd, options.env, options.rules)
    ok(ctx) -> ok(ctx)
    error(e) -> error("cwd: #{e.message}", kind: Protocol.KIND_INVALID)
  end

  context = try ctx
  header = Store.Header(
    id: "s#{registry.sessions.size + 1}-#{OpenSSL.Random.hex(4)}",
    cwd: context.root,
    model: request.model.unwrap_or(options.model),
    created_ms: Time.now_ms,
    system: some(system_prompt(context.root)),
  )

  file = try Store.create(sessions_dir(options), header)
  ok(entry(options, header, context, file, none))
end

# A running session ends first, refused while a turn runs; then its file goes.
def delete_session(registry: Registry, id: String) -> Result[Void]
  found = registry.sessions.select { |entry| entry.summary.id == id }
  return error("no session #{id}", kind: Protocol.KIND_SESSION_NOT_FOUND) if found.empty?

  for session in option_list(found[0].session)
    try Session.end_session(session.address)
    _ = Task.await(session.task, CALL_MS)
  end

  Path.remove(found[0].file)
end

def replaced(entry: Entry, by: Entry) -> Entry
  return by if entry.summary.id == by.summary.id

  entry
end

# The entry with its session running: loaded from its file when it is not yet.
def started(options: Options, listed: Entry) -> Result[Entry]
  return ok(listed) if listed.session.some?

  info = try File.lstat(listed.file)
  return error("not a regular file") if info.kind != "file"

  saved = try Store.load(listed.file)
  if saved.skipped > 0
    IO.warn("session #{saved.header.id}: #{saved.skipped} records skipped")
  end

  context = try Tools.context(saved.header.cwd, options.env, options.rules)
  if saved.open_end
    try Store.reopen(listed.file)
  end

  ok(entry(options, saved.header, context, listed.file, some(saved)))
end

def entry(
  options: Options,
  header: Store.Header,
  context: Tools.Context,
  file: String,
  saved: Optional[Store.Saved],
) -> Entry
  setup = Session.Setup(
    id: header.id,
    cwd: context.root,
    model: header.model,
    provider: options.provider,
    system: header.system.unwrap_or(system_prompt(context.root)),
    ctx: context,
    keep_events: options.keep_events,
    approval_timeout_ms: options.approval_timeout_ms,
    file: file,
    window: options.context_window.unwrap_or(0),
    compact_model: options.compact_model,
    props_url: options.props_url,
    api_key: options.api_key,
  )

  Entry(summary: summary_of(header), header: header, file: file, session: some(Session.start(setup, saved)))
end

def summary_of(header: Store.Header) -> Protocol.SessionSummary
  Protocol.SessionSummary(id: header.id, cwd: header.cwd, model: header.model)
end

# In the order they were made, not loaded yet. A file whose first line is not a session is left out, with a warning.
def load_sessions(options: Options) -> List[Entry]
  dir = sessions_dir(options)
  names: List[String] = []
  case Dir.list(dir)
    ok(found) -> names = found.select { |name| name.end_with?(Store.EXTENSION) }
    error(e) -> IO.warn("sessions not listed: #{e.message}")
  end

  listed: List[Listed] = []
  for name in names
    file = "#{dir}/#{name}"
    case listed_session(file)
      ok(header) -> listed = listed.push(Listed(file: file, header: header))
      error(e) -> IO.warn("session #{name} not listed: #{e.message}")
    end
  end

  sorted = listed.sort_by { |one| one.header.id }.sort_by { |one| one.header.created_ms }
  sorted.map { |one| Entry(summary: summary_of(one.header), header: one.header, file: one.file, session: none) }
end

def listed_session(file: String) -> Result[Store.Header]
  info = try File.lstat(file)
  return error("not a regular file") if info.kind != "file"

  Store.header(file)
end

# `AGENTS.md` goes to the model only when it is a regular file inside the folder: a link out of it could be any file.
def system_prompt(root: String) -> String
  case project_instructions(root)
    ok(text) -> "#{SYSTEM_PROMPT}\n# AGENTS.md of the session folder\n\n#{text}"
    error(_) -> SYSTEM_PROMPT
  end
end

def project_instructions(root: String) -> Result[String]
  path = try Sandbox.resolve(root, "AGENTS.md")
  info = try File.stat(path)
  return error("not a regular file") if info.kind != "file"
  return error("larger than #{MAX_READ_BYTES} bytes") if info.size_bytes > MAX_READ_BYTES

  text = try File.read_text(path)
  return ok(text) if text.bytesize <= MAX_INSTRUCTIONS_BYTES

  kept = text.slice(0, MAX_INSTRUCTIONS_BYTES)
  if kept.bytesize > MAX_INSTRUCTIONS_BYTES
    kept = text.slice(0, MAX_INSTRUCTIONS_BYTES / 4)
  end

  ok("#{kept}\n[AGENTS.md cut: it has #{info.size_bytes} bytes]")
end

def route(token: String, registry: Address[Msg], request: HTTP.Request, body: HTTP.RequestBody) -> Result[HTTP.Answer]
  for refusal in option_list(refused(token, request))
    return ok(HTTP.Answer.Whole(refusal))
  end

  if request.method == "GET" and request.path == Protocol.HEALTH_PATH
    return whole(200, Protocol.encode_health(Protocol.Health(version: VERSION)))
  end

  prefix = Protocol.SESSIONS_PATH
  if request.path != prefix and not request.path.start_with?("#{prefix}/")
    return ok(HTTP.Answer.Whole(no_route(request.method, request.path)))
  end

  # The parts after /v1/sessions: an id, then a sub-resource.
  parts = request.path.slice(prefix.length, request.path.length - prefix.length).split("/").drop(1)
  return events(registry, request, parts[0]) if request.method == "GET" and parts.size == 2 and parts[1] == "events"

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
    "POST 0" ->
      request = try Protocol.decode_new_session(text)
      created: Result[Result[String]] = Actor.call(registry, CALL_MS) do |reply| Msg.Create(request, reply) end
      id = try try created
      response(201, Protocol.encode_session_created(Protocol.SessionCreated(id: id)))
    "GET 0" ->
      list: Result[Protocol.SessionList] = Actor.call(registry, CALL_MS) do |reply| Msg.List(reply) end
      response(200, Protocol.encode_session_list(try list))
    "DELETE 1" ->
      deleted: Result[Result[Void]] = Actor.call(registry, CALL_MS) do |reply| Msg.Delete(parts[0], reply) end
      try try deleted
      response(200, "{}")
    "GET 1" -> response(200, Protocol.encode_session(try Session.snapshot(try find(registry, parts[0]))))
    "POST 2" if parts[1] == "messages" ->
      message = try Protocol.decode_send_message(text)
      turn_id = try Session.send(try find(registry, parts[0]), message.text)
      response(202, Protocol.encode_message_accepted(Protocol.MessageAccepted(turn_id: turn_id)))
    "POST 2" if parts[1] == "stop" ->
      _ = try Session.stop(try find(registry, parts[0]))
      response(200, "{}")
    "POST 3" if parts[1] == "approvals" ->
      approve = try Protocol.decode_approve(text)
      try Session.answer(try find(registry, parts[0]), parts[2], approve.decision)
      response(200, "{}")
    _ -> ok(no_route(method, "#{Protocol.SESSIONS_PATH}/#{parts.join("/")}"))
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
  found: Result[Result[Address[Session.Msg]]] = Actor.call(registry, CALL_MS) do |reply| Msg.Find(id, reply) end
  ok(try try found)
end

def no_route(method: String, path: String) -> HTTP.Response
  failure_response(404, "not_found", "no route for #{method} #{path}")
end

def failure(e: Error) -> HTTP.Response = failure_response(status_of(e.kind), e.kind, e.message)

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
