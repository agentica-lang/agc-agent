## A core server on port 0 in a fresh folder, against a fake LLM API, and an HTTP client for it: the requests of the
## protocol and the event stream read with the `sse` parser.

import HTTP from "std/http"
import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import SSE from "pkg/sse/sse"
import Config from "../../src/config"
import Server from "../../src/server"
import Tools from "../../src/tools"
import Fake from "fake_llm"

WAIT_MS = 10000

struct Harness
  server: Server.Server
  fake: Fake.Fake
  base: String
  work: String
  state_dir: String
  data_dir: String
  url: String
  token: String
  apis: Map[String, Server.ModelApi]
end

struct Answer
  status: Int
  text: String
end

## An event as a client saw it.
struct Seen
  id: String
  event: Protocol.Event
end

struct Sub
  stream: HTTP.Stream
  parser: SSE.Parser
  seen: List[Seen]
end

## The model answers with the fixtures `replies` in order (names under the folder of `api`; a `.json` one is a 200 JSON
## answer, `STATUS:name.json` one of that status).
struct Setup
  replies: List[String]
  keep_events: Int = 1000
  approval_timeout_ms: Int = 90000
  ## 0 asks the fake (`GET /models`), which takes a reply.
  context_window: Int = 1_000_000
  compact_model: String = ""
  ## The server asks the fake's `/props` for the window first.
  props: Bool = false
  before_load: Optional[Fn[String, Void]] = none
  ## The model API of the server, as `FINN_API` names it; the fixtures come from the folder of its format.
  api: String = "openai"
end

def fake_env(name: String) -> Result[String]
  case name
    "PATH" -> System.env("PATH")
    "OPENAI_API_KEY" -> ok("sk-secret-key")
    _ -> error("not set")
  end
end

## Runs `body` against a server of `setup`, and stops the server and the fake and removes the folder however it ends.
def using(setup: Setup, body: Fn[Harness, Result[Void]]) -> Result[Void]
  tmp = System.env("TMPDIR").unwrap_or("/tmp")
  base = "#{tmp}/agc-core-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(base)
  result = with_fake(setup, base, body)
  _ = Path.remove(base)
  result
end

def with_fake(setup: Setup, base: String, body: Fn[Harness, Result[Void]]) -> Result[Void]
  fake = try Fake.start(try fixtures(setup.replies, fixture_dir(setup.api)))
  started = start(setup, try Path.real(base), fake)
  result = case started
    ok(h) -> body.call(h)
    error(e) -> error(e)
  end

  case started
    ok(h) -> Server.stop(h.server)
    error(_) -> nil
  end

  _ = Fake.stop(fake)
  result
end

def start(setup: Setup, base: String, fake: Fake.Fake) -> Result[Harness]
  work = "#{base}/work"
  try Dir.mkdir(work)
  options = Server.Options(
    state_dir: "#{base}/state",
    data_dir: "#{base}/data",
    apis: Config.apis(fake.url, "test-key", LLM.Options(timeout_ms: 5000, retry_base_ms: 1)),
    api: setup.api,
    model: "qwen2.5-0.5b-instruct",
    env: &fake_env,
    rules: no_rules(),
    keep_events: setup.keep_events,
    approval_timeout_ms: setup.approval_timeout_ms,
    context_window: window(setup.context_window),
    compact_model: setup.compact_model,
    props_url: props_url(setup, fake),
    before_load: setup.before_load,
  )

  server = try Server.start(options)
  ok(
    Harness(
      server: server,
      fake: fake,
      base: base,
      work: work,
      state_dir: options.state_dir,
      data_dir: options.data_dir,
      url: "http://127.0.0.1:#{server.port}",
      token: server.token,
      apis: options.apis,
    ),
  )
end

## Stops the server and starts a new one on the same folders and fake; `body` gets it, and it stops after. `cut` is
## added to the end of every session file in between, as a write that a crash cut.
def restarted(h: Harness, setup: Setup, cut: String, body: Fn[Harness, Result[Void]]) -> Result[Void]
  Server.stop(h.server)
  if not cut.empty?
    for name in try Dir.list(sessions(h))
      try File.append_text("#{sessions(h)}/#{name}", cut)
    end
  end

  again = try start(setup, h.base, h.fake)
  result = body.call(again)
  Server.stop(again.server)
  result
end

def sessions(h: Harness) -> String = "#{h.data_dir}/sessions"

def session_file(h: Harness, id: String) -> String = "#{sessions(h)}/#{id}.jsonl"

## Runs a program and gives its exit code.
def run(program: String, args: List[String]) -> Result[Int]
  process = try Process.spawn(program, args)
  code = Process.wait(process, 5000)
  Process.close(process)
  code
end

def props_url(setup: Setup, fake: Fake.Fake) -> String
  return "" if not setup.props

  "#{fake.url.slice(0, fake.url.length - 3)}/props"
end

def window(tokens: Int) -> Optional[Int]
  return none if tokens == 0

  some(tokens)
end

def no_rules() -> Tools.Rules = Tools.Rules(allow: [], deny: [])

def fixtures(names: List[String], dir: String = "openai_chat") -> Result[List[Fake.Reply]]
  replies: List[Fake.Reply] = []
  for name in names
    parts = name.split(":")
    if name.include?("/")
      replies = replies.push(try Fake.sse(name))
    elsif parts.size == 2
      replies = replies.push(try Fake.json(try parts[0].to_i, "#{dir}/#{parts[1]}"))
    elsif name.end_with?(".json")
      replies = replies.push(try Fake.json(200, "#{dir}/#{name}"))
    else
      replies = replies.push(try Fake.sse("#{dir}/#{name}"))
    end
  end

  ok(replies)
end

def fixture_dir(api: String) -> String
  return "openai_chat" if api == "openai"

  api
end

def auth(h: Harness) -> List[HTTP.Header] = [HTTP.Header(name: "Authorization", value: "Bearer #{h.token}")]

def call(h: Harness, method: String, path: String, body: String, headers: List[HTTP.Header]) -> Result[Answer]
  client = try HTTP.client(HTTP.ClientOptions(timeout_ms: WAIT_MS))
  response = HTTP.request(client, method, "#{h.url}#{path}", body.bytes, headers)
  HTTP.close_client(client)
  got = try response
  ok(Answer(status: got.status, text: try String.from_bytes(got.body)))
end

def get(h: Harness, path: String) -> Result[Answer] = call(h, "GET", path, "", auth(h))

def post(h: Harness, path: String, body: String) -> Result[Answer] = call(h, "POST", path, body, auth(h))

def new_session(h: Harness) -> Result[String] = new_session_in(h, h.work)

def new_session_in(h: Harness, cwd: String, api: Optional[String] = none) -> Result[String]
  asked = Protocol.NewSession(cwd: cwd, model: none, api: api)
  answer = try post(h, Protocol.SESSIONS_PATH, Protocol.encode_new_session(asked))

  return error("POST /v1/sessions: #{answer.status} #{answer.text}") if answer.status != 201

  ok((try Protocol.decode_session_created(answer.text)).id)
end

def session(h: Harness, id: String) -> Result[Protocol.Session]
  Protocol.decode_session((try get(h, Protocol.session_path(id))).text)
end

def send(h: Harness, id: String, text: String) -> Result[Answer]
  post(h, Protocol.messages_path(id), Protocol.encode_send_message(Protocol.SendMessage(text: text)))
end

def approve(h: Harness, id: String, approval_id: String, decision: Protocol.Decision) -> Result[Answer]
  post(h, Protocol.approval_path(id, approval_id), Protocol.encode_approve(Protocol.Approve(decision: decision)))
end

def subscribe(h: Harness, id: String, last_event_id: Optional[Int] = none) -> Result[Sub]
  headers = auth(h)
  for last in option_list(last_event_id)
    headers = headers.push(HTTP.Header(name: Protocol.LAST_EVENT_ID_HEADER, value: Protocol.format_event_id(last)))
  end

  options = HTTP.ClientOptions(timeout_ms: WAIT_MS)
  stream = try HTTP.open("GET", "#{h.url}#{Protocol.events_path(id)}", "".bytes, headers, options)
  return error("events: #{stream.status}") if stream.status != 200

  ok(Sub(stream: stream, parser: SSE.parser(), seen: []))
end

## Reads the stream until an event of `kind`, and gives all it read so far.
def until(sub: Sub, kind: Protocol.EventKind) -> Result[Sub]
  at = sub.seen.size
  current = sub
  while true
    for seen in current.seen.drop(at)
      return ok(current) if Protocol.event_kind(seen.event) == kind
    end

    at = current.seen.size
    piece = try current.stream.body.recv(WAIT_MS)
    fed = try SSE.feed(current.parser, piece)
    events: List[Seen] = []
    for event in fed.events
      events = events.push(Seen(id: event.id, event: try Protocol.decode_event(event.name, event.data)))
    end

    current = current.with(parser: fed.parser, seen: current.seen + events)
  end

  ok(current)
end

def close(sub: Sub) -> Void
  sub.stream.body.close
  Task.cancel(sub.stream.done)
end

## Waits until no turn runs.
def idle(h: Harness, id: String) -> Result[Protocol.Session]
  for _i in 1..100
    snapshot = try session(h, id)
    return ok(snapshot) if snapshot.turn_id.none?

    Task.sleep(50)
  end

  error("the turn did not end")
end

def kinds(seen: List[Seen]) -> List[String] = seen.map { |s| Protocol.event_name(s.event) }

## The last approval request a client saw.
def approval(sub: Sub) -> Result[Protocol.ApprovalRequested]
  for seen in sub.seen.reverse
    case seen.event
      Protocol.Event.ApprovalRequested(request) -> return ok(request)
      _ -> nil
    end
  end

  error("no approval_requested")
end

def resolved_by(sub: Sub) -> List[String]
  sources: List[String] = []
  for seen in sub.seen
    case seen.event
      Protocol.Event.ApprovalResolved(r) ->
        sources = sources.push("#{Protocol.decision_name(r.decision)} #{Protocol.source_name(r.source)}")
      _ -> nil
    end
  end

  sources
end

def stop_reason(sub: Sub) -> String
  for seen in sub.seen.reverse
    case seen.event
      Protocol.Event.TurnFinished(finished) -> return Protocol.stop_reason_name(finished.stop_reason)
      _ -> nil
    end
  end

  ""
end

## The next request the fake got.
def next_request(h: Harness) -> Result[Fake.Seen] = Fake.next_request(h.fake)

## The messages of the `n`-th request the fake got (from 1).
def request_messages(h: Harness, n: Int) -> Result[List[JSON.Value]]
  seen = Fake.Seen(method: "", path: "", headers: [], body: "")
  for _i in 1..n
    seen = try Fake.next_request(h.fake)
  end

  JSON.list(try JSON.get(try JSON.parse(seen.body), "messages"))
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
