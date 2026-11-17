import Mcp from "../mcp"

PEERS = ["tests/fixtures/http_peer.py", "mcp/tests/fixtures/http_peer.py"]
TOKEN = "peer-secret-token"

# Against an independent server in Python: a JSON answer, an SSE answer with a notification and a request of the
# server on the way, a stream cut and resumed, and a session that the server ends and that starts again for the same
# call.
def test_lists_and_calls_tools_over_http() -> Result[Void]
  within_peer do |peer|
    client = Mcp.start(server(peer, TOKEN))
    names = (try Mcp.tools(client)).map { |t| t.name }
    echo = Mcp.call(client, "echo", JSON.object({"text": JSON.from("hello")}))
    resumed = Mcp.call(client, "cut", JSON.object({}))
    expired = Mcp.call(client, "expire", JSON.object({}))
    again = Mcp.call(client, "echo", JSON.object({"text": JSON.from("again")}))
    Mcp.stop(client)
    try Test.eq(names, ["echo", "cut", "big", "hang", "expire"])
    try Test.eq(echo, ok(Mcp.Output(text: "hello", is_error: false)))
    try Test.eq(resumed, ok(Mcp.Output(text: "resumed", is_error: false)))
    try Test.eq(expired, ok(Mcp.Output(text: "expired", is_error: false)))
    try Test.eq(again, ok(Mcp.Output(text: "again", is_error: false)))
    seen = try requests(peer)
    try Test.eq(
      seen.map { |r| "#{r.verb} #{r.method} #{r.session}" },
      [
        "POST initialize ",
        "POST notifications/initialized session-1",
        "POST tools/list session-1",
        "POST  session-1",
        "POST tools/call session-1",
        "POST tools/call session-1",
        "GET  session-1",
        "POST tools/call session-1",
        "POST tools/call session-1",
        "POST initialize ",
        "POST notifications/initialized session-2",
        "POST tools/call session-2",
        "DELETE  session-2",
      ],
    )

    try Test.eq(ok(seen[3].body), JSON.parse("{\"jsonrpc\": \"2.0\", \"id\": \"srv-1\", \"result\": {}}"))
    try Test.eq(seen[6].last_event_id, "session-1-cut-1")
    try Test.eq(seen.select { |r| r.method != "initialize" }.all? { |r| r.version == "2025-06-18" }, true)
    Test.eq(seen[0].version, "")
  end
end

# An answer over the size limit, a server that answers nothing in time, and a refused token are each
# `mcp.unavailable`; the token is in no error, and the next use starts a new session.
def test_limits_and_refusals_over_http() -> Result[Void]
  within_peer do |peer|
    client = Mcp.start(server(peer, TOKEN), Mcp.Options(timeout_ms: 1000, max_message_bytes: 65_536))
    big = Mcp.call(client, "big", JSON.object({}))
    began = Time.monotonic_ms()
    hung = Mcp.call(client, "hang", JSON.object({}))
    took = Time.monotonic_ms() - began
    again = Mcp.call(client, "echo", JSON.object({"text": JSON.from("back")}))
    Mcp.stop(client)
    refused_client = Mcp.start(server(peer, "wrong-#{TOKEN}"))
    refused = Mcp.tools(refused_client)
    Mcp.stop(refused_client)
    try Test.eq(
      [kind_of(big), kind_of(hung), kind_of(refused)],
      ["mcp.unavailable", "mcp.unavailable", "mcp.unavailable"],
    )

    try Test.assert(took < 4000, "the hung call took #{took} ms")
    try Test.eq(again, ok(Mcp.Output(text: "back", is_error: false)))
    try Test.assert(refused.message.include?("401"), refused.message)
    Test.assert(not refused.message.include?(TOKEN), "the token is in the error")
  end
end

private

struct Peer
  process: Process
  url: String
  log: String
end

struct Seen
  verb: String
  method: String
  session: String
  version: String
  last_event_id: String
  body: JSON.Value
end

def server(peer: Peer, token: String) -> Mcp.Server
  Mcp.Server(name: "web", url: peer.url, headers: {"Authorization": "Bearer #{token}"})
end

def within_peer(body: Fn[Peer, Result[Void]]) -> Result[Void]
  tmp = System.env("TMPDIR").unwrap_or("/tmp")
  dir = "#{tmp}/mcp-http-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  result = with_peer(dir, body)
  _ = Path.remove(dir)
  result
end

def with_peer(dir: String, body: Fn[Peer, Result[Void]]) -> Result[Void]
  script = try Path.resolve(try existing(PEERS))
  log = "#{dir}/requests.jsonl"
  process = try Process.spawn("python3", [script, log], Process.Options(env: {"PEER_TOKEN": TOKEN}))
  port = Process.read_line(process, 10_000)
  result = case port
    ok(line) -> body.call(Peer(process: process, url: "http://127.0.0.1:#{line.strip}/mcp", log: log))
    error(e) -> error("the peer did not start: #{e.message}")
  end

  Process.close(process)
  result
end

def requests(peer: Peer) -> Result[List[Seen]]
  lines = (try File.read_text(peer.log)).split("\n").select { |l| not l.empty? }
  seen: List[Seen] = []
  for line in lines
    json = try JSON.parse(line)
    message = JSON.get(json, "body").unwrap_or(JSON.object({}))
    seen = seen.push(
      Seen(
        verb: text(json, "verb"),
        method: text(message, "method"),
        session: text(json, "session"),
        version: text(json, "version"),
        last_event_id: text(json, "last_event_id"),
        body: message,
      ),
    )
  end

  ok(seen)
end

def text(json: JSON.Value, key: String) -> String
  case JSON.get(json, key)
    ok(value) -> JSON.string(value).unwrap_or("")
    error(_) -> ""
  end
end

def kind_of[T](result: Result[T]) -> String
  case result
    ok(_) -> "ok"
    error(e) -> e.kind
  end
end

def existing(paths: List[String]) -> Result[String]
  case (paths.find { |path| File.stat(path).ok? })
    ok(path) -> ok(path)
    error(_) -> error("none of #{paths.join(", ")} exists")
  end
end
