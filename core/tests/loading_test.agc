import HTTP from "std/http"
import Protocol from "pkg/protocol/protocol"

EVENTS = 100_000
WAIT_MS = 30_000
STARTED_MS = 200
CHUNK = 5000

struct Remote
  process: Process
  url: String
  token: String
  sessions: String
end

# A big session file loads in a task: while it loads, the list and a new session answer at once. Two requests for it
# get one session, whose cut turn ends once. A session deleted while it loads stays deleted, its file too.
def test_a_big_session_loads_without_blocking_the_others() -> Result[Void]
  base = try make_dir()
  result = loaded(base)
  _ = Path.remove(base)
  result
end

private

def loaded(base: String) -> Result[Void]
  work = "#{base}/work"
  sessions = "#{base}/data/sessions"
  try Dir.mkdir(work)
  try Dir.mkdir_private("#{base}/data")
  try Dir.mkdir_private(sessions)
  try write_session("#{sessions}/big.jsonl", "big", work, EVENTS, "\n")
  try write_session("#{sessions}/gone.jsonl", "gone", work, EVENTS, "")
  remote = try start(base, sessions)
  result = checked(remote, work)
  Process.close(remote.process)
  result
end

def checked(remote: Remote, work: String) -> Result[Void]
  done: Channel[Result[Int]] = Channel.new(2)
  started = Time.now_ms
  for _ in 1..2
    _ = Task.spawn do _ = done.send(timed(call(remote, "GET", Protocol.session_path("big"), ""), started), WAIT_MS) end
  end

  Task.sleep(STARTED_MS)
  asked = Time.now_ms
  listed = try call(remote, "GET", Protocol.SESSIONS_PATH, "")
  new_session = Protocol.encode_new_session(Protocol.NewSession(cwd: work, model: none))
  created = try call(remote, "POST", Protocol.SESSIONS_PATH, new_session)
  quick = Time.now_ms - asked
  try Test.eq([listed.status, created.status], [200, 201])
  loads = [try try done.recv(WAIT_MS), try try done.recv(WAIT_MS)]
  try Test.assert(quick * 4 < loads.min.unwrap!, "list and create took #{quick} ms, the loads #{loads} ms")
  ended = try File.foreach("#{remote.sessions}/big.jsonl").select { |line| line.include?("turn_finished") }.to_a
  try Test.eq(ended.size, 1)
  deleted_while_loading(remote, loads.max.unwrap!)
end

# The time from `started` of a request that answered 200.
def timed(response: Result[HTTP.Response], started: Int) -> Result[Int]
  return error("the session did not load: #{status(response)}") if status(response) != 200

  ok(Time.now_ms - started)
end

# `load_ms` is how long a file of this size takes to load.
def deleted_while_loading(remote: Remote, load_ms: Int) -> Result[Void]
  path = Protocol.session_path("gone")
  started = Time.now_ms
  loading = Task.spawn do status(call(remote, "GET", path, "")) end
  Task.sleep(STARTED_MS)
  case Task.await(loading, 1)
    Await.TimedOut -> nil
    Await.Done(code) -> return error("the load ended before the delete: #{code}")
  end

  try Test.eq(status(call(remote, "DELETE", path, "")), 200)
  try Test.eq(Task.await(loading), 404)
  # The load goes on after the delete; what it read never comes back.
  Task.sleep([load_ms - (Time.now_ms - started), 0].max.unwrap! + STARTED_MS)
  try Test.eq(File.stat("#{remote.sessions}/gone.jsonl").ok?, false)
  Test.eq(status(call(remote, "GET", path, "")), 404)
end

# A turn that a restart cut, with many saved events, and a last line that a crash cut, then `tail`.
def write_session(path: String, id: String, cwd: String, events: Int, tail: String) -> Result[Void]
  head = "{\"type\":\"session\",\"id\":\"#{id}\",\"cwd\":\"#{cwd}\",\"model\":\"m\",\"created_ms\":1}\n"
  user = "{\"type\":\"user\",\"text\":\"go\"}\n"
  started = "{\"type\":\"event\",\"id\":1,\"name\":\"turn_started\",\"data\":{\"turn_id\":\"turn-1\"}}\n"
  data = "{\"call_id\":\"c\",\"name\":\"bash\",\"summary\":\"make test\"}"
  tool = "{\"type\":\"event\",\"id\":2,\"name\":\"tool_started\",\"data\":#{data}}\n"
  try File.write_text(path, "#{head}#{user}#{started}")
  for _ in 1..(events / CHUNK)
    try File.append_text(path, tool * CHUNK)
  end

  File.append_text(path, "{\"type\":\"event\",\"id\":3#{tail}")
end

def start(base: String, sessions: String) -> Result[Remote]
  env = {"FINN_STATE_DIR": "#{base}/state", "FINN_DATA_DIR": "#{base}/data"}
  process = try Process.spawn_captured(binary(), ["main.agc", "serve"], Process.Options(env: env, timeout_ms: 60_000))
  line = try Process.read_line(process, WAIT_MS)
  return error("the server did not start: #{line}") if not line.include?("listening")

  info = try Protocol.decode_server_info(try File.read_text("#{base}/state/server.json"))
  ok(Remote(process: process, url: "http://127.0.0.1:#{info.port}", token: info.token, sessions: sessions))
end

def call(remote: Remote, method: String, path: String, body: String) -> Result[HTTP.Response]
  client = try HTTP.client(HTTP.ClientOptions(timeout_ms: WAIT_MS))
  headers = [HTTP.Header(name: "Authorization", value: "Bearer #{remote.token}")]
  response = HTTP.request(client, method, "#{remote.url}#{path}", body.bytes, headers)
  HTTP.close_client(client)
  response
end

def status(response: Result[HTTP.Response]) -> Int
  case response
    ok(answer) -> answer.status
    error(_) -> 0
  end
end

def binary() -> String
  case System.env("AGENTICA")
    ok(path) if path != "" -> path
    _ -> "agentica"
  end
end

def make_dir() -> Result[String]
  base = "#{System.env("TMPDIR").unwrap_or("/tmp")}/agc-load-#{Random.int(0, 999_999_999)}"
  try Dir.mkdir_private(base)
  Path.real(base)
end
