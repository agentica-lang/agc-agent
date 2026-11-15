## A core server on port 0 in a fresh folder, against a fake LLM API, and an HTTP client for it: the requests of the
## protocol and the event stream read with the `sse` parser.

import HTTP from "std/http"
import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import SSE from "pkg/sse/sse"
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
  url: String
  token: String
  provider: LLM.Provider
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

def fake_env(name: String) -> Result[String]
  case name
    "PATH" -> System.env("PATH")
    "OPENAI_API_KEY" -> ok("sk-secret-key")
    _ -> error("not set")
  end
end

## A server whose model answers with the fixtures `replies` in order (names under `openai_chat/`).
def start(replies: List[String], keep_events: Int = 1000, approval_timeout_ms: Int = 90000) -> Result[Harness]
  fake = try Fake.start(try fixtures(replies))
  tmp = System.env("TMPDIR").unwrap_or("/tmp")
  base = "#{tmp}/agc-core-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(base)
  base = try Path.real(base)
  work = "#{base}/work"
  try Dir.mkdir(work)
  options = Server.Options(
    state_dir: "#{base}/state",
    provider: LLM.openai_chat(fake.url, "test-key", LLM.Options(timeout_ms: 5000, retry_base_ms: 1)),
    model: "qwen2.5-0.5b-instruct",
    env: &fake_env,
    rules: no_rules(),
    keep_events: keep_events,
    approval_timeout_ms: approval_timeout_ms,
  )

  server = try Server.start(options)
  ok(
    Harness(
      server: server,
      fake: fake,
      base: base,
      work: work,
      state_dir: options.state_dir,
      url: "http://127.0.0.1:#{server.port}",
      token: server.token,
      provider: options.provider,
    ),
  )
end

def no_rules() -> Tools.Rules = Tools.Rules(allow: [], deny: [])

def stop(h: Harness) -> Result[Void]
  Server.stop(h.server)
  try Fake.stop(h.fake)
  Path.remove(h.base)
end

def fixtures(names: List[String]) -> Result[List[Fake.Reply]]
  replies: List[Fake.Reply] = []
  for name in names
    replies = replies.push(try Fake.sse("openai_chat/#{name}"))
  end

  ok(replies)
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

def new_session(h: Harness) -> Result[String]
  answer = try post(
    h,
    Protocol.SESSIONS_PATH,
    Protocol.encode_new_session(Protocol.NewSession(cwd: h.work, model: none)),
  )

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

def stop_reason(sub: Sub) -> String
  for seen in sub.seen.reverse
    case seen.event
      Protocol.Event.TurnFinished(finished) -> return Protocol.stop_reason_name(finished.stop_reason)
      _ -> nil
    end
  end

  ""
end

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
