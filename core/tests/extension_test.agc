## The example extension of `examples/extension`, served by its own program as a user's would be: the model calls its
## tool (which never asks), its wrapper times the call, and its service starts before the server listens and stops after
## it on SIGTERM.

import HTTP from "std/http"
import Protocol from "pkg/protocol/protocol"
import Fake from "support/fake_llm"

EXAMPLE = "../examples/extension/main.agc"
WAIT_MS = 10_000

def test_the_example_extension_adds_a_tool_and_wraps_it() -> Result[Void]
  fake = try Fake.start([try Fake.sse("openai_chat/word_count.sse"), try Fake.sse("openai_chat/text.sse")])
  base = "#{System.env("TMPDIR").unwrap_or("/tmp")}/core-ext-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(base)
  result = served(fake, try Path.real(base))
  try Fake.stop(fake)
  _ = Path.remove(base)
  result
end

def served(fake: Fake.Fake, base: String) -> Result[Void]
  options = Process.Options(env: env(fake, base), chdir: base)
  program = try program_words()
  server = try Process.spawn_captured(program[0], program.drop(1), options)
  result = run(server, base)
  _ = Process.signal(server, System.Signal.Term)
  _ = Process.wait(server, WAIT_MS)
  Process.close(server)
  result
end

def run(server: Process, base: String) -> Result[Void]
  try Test.eq(try lines_until(server, "listening on"), ["greeter started", "Finn Agent core listening on"])
  try turn(base)
  try Process.signal(server, System.Signal.Term)
  Test.eq(try lines_until(server, "core stopped"), ["greeter stopped", "Finn Agent core stopped"])
end

# The bytecode `make unit` compiled once (EXTENSION_BYTECODE), else the source.
def program_words() -> Result[List[String]]
  agentica = System.env("AGENTICA").unwrap_or("agentica")
  case System.env("EXTENSION_BYTECODE")
    ok(bytecode) if bytecode != "" -> ok([agentica, "run", "--", bytecode])
    _ -> ok([agentica, try Path.resolve(EXAMPLE)])
  end
end

# The lines of the output up to the one that has `marker`, each cut after the marker.
def lines_until(server: Process, marker: String) -> Result[List[String]]
  lines: List[String] = []
  while true
    line = (try Process.read_line(server, WAIT_MS)).strip
    return ok(lines.push(line.slice(0, line.index_of(marker).unwrap_or(0) + marker.length))) if line.include?(marker)

    lines = lines.push(line)
  end

  ok(lines)
end

def turn(base: String) -> Result[Void]
  info = try server_info("#{base}/state/server.json")
  url = "http://127.0.0.1:#{info.port}"
  headers = [HTTP.Header(name: "Authorization", value: "Bearer #{info.token}")]
  asked = Protocol.encode_new_session(Protocol.NewSession(cwd: base, model: none, api: none, provider: none))
  created = try call("#{url}#{Protocol.SESSIONS_PATH}", asked, headers)
  id = (try Protocol.decode_session_created(created)).id
  options = HTTP.ClientOptions(timeout_ms: WAIT_MS)
  stream = try HTTP.open("GET", "#{url}#{Protocol.events_path(id)}", "".bytes, headers, options)
  sent = Protocol.encode_send_message(Protocol.SendMessage(text: "Count the words of one two three."))
  _ = try call("#{url}#{Protocol.messages_path(id)}", sent, headers)
  ended = finished(stream)
  stream.body.close
  Task.cancel(stream.done)
  try ended
  text = try File.read_text("#{base}/data/sessions/#{id}.jsonl")
  try Test.assert(text.include?("3 words"), "the tool ran: #{text}")
  Test.assert(text.include?("(word_count took "), "the wrapper timed it: #{text}")
end

def env(fake: Fake.Fake, base: String) -> Map[String, String]
  {
    "PATH": System.env("PATH").unwrap_or("/usr/bin:/bin"),
    "HOME": base,
    "XDG_CONFIG_HOME": "#{base}/config",
    "XDG_CACHE_HOME": "#{base}/cache",
    "FINN_STATE_DIR": "#{base}/state",
    "FINN_DATA_DIR": "#{base}/data",
    "FINN_BASE_URL": fake.url,
    "FINN_MODEL": "m",
    "FINN_MODELS_URL": "off",
    "FINN_CONTEXT_WINDOW": "100000",
    "FINN_APPROVALS": "1",
  }
end

# Written before the line that says it listens.
def server_info(path: String) -> Result[Protocol.ServerInfo] = Protocol.decode_server_info(try File.read_text(path))

def call(url: String, body: String, headers: List[HTTP.Header]) -> Result[String]
  client = try HTTP.client(HTTP.ClientOptions(timeout_ms: WAIT_MS))
  answer = HTTP.request(client, "POST", url, body.bytes, headers)
  HTTP.close_client(client)
  response = try answer
  text = try String.from_bytes(response.body)
  return error("POST #{url}: #{response.status} #{text}") if response.status >= 300

  ok(text)
end

# Reads the events of the session until its turn has ended.
def finished(stream: HTTP.Stream) -> Result[Void]
  seen = ""
  while not seen.include?("turn_finished")
    seen = "#{seen}#{try String.from_bytes(try stream.body.recv(WAIT_MS))}"
  end

  ok()
end
