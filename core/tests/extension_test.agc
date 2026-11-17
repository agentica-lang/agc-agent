## The example extension of `examples/extension`, served by its own program as a user's would be: the model calls its
## tool, and its wrapper times the call.

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
  agentica = System.env("AGENTICA").unwrap_or("agentica")
  options = Process.Options(env: env(fake, base), chdir: base)
  server = try Process.spawn_captured(agentica, [try Path.resolve(EXAMPLE)], options)
  result = turn(base)
  _ = Process.signal(server, System.Signal.Term)
  _ = Process.wait(server, WAIT_MS)
  Process.close(server)
  result
end

def turn(base: String) -> Result[Void]
  info = try server_info("#{base}/state/server.json")
  url = "http://127.0.0.1:#{info.port}"
  headers = [HTTP.Header(name: "Authorization", value: "Bearer #{info.token}")]
  asked = Protocol.encode_new_session(Protocol.NewSession(cwd: base, model: none, api: none, provider: none))
  created = try call("#{url}#{Protocol.SESSIONS_PATH}", asked, headers)
  id = (try Protocol.decode_session_created(created)).id
  sent = Protocol.encode_send_message(Protocol.SendMessage(text: "Count the words of one two three."))
  _ = try call("#{url}#{Protocol.messages_path(id)}", sent, headers)
  text = try saved("#{base}/data/sessions/#{id}.jsonl")
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
  }
end

def server_info(path: String) -> Result[Protocol.ServerInfo]
  for _i in 1..200
    case File.read_text(path)
      ok(text) -> return Protocol.decode_server_info(text)
      error(_) -> Task.sleep(50)
    end
  end

  error("the example server did not start")
end

def call(url: String, body: String, headers: List[HTTP.Header]) -> Result[String]
  client = try HTTP.client(HTTP.ClientOptions(timeout_ms: WAIT_MS))
  answer = HTTP.request(client, "POST", url, body.bytes, headers)
  HTTP.close_client(client)
  response = try answer
  text = try String.from_bytes(response.body)
  return error("POST #{url}: #{response.status} #{text}") if response.status >= 300

  ok(text)
end

# The session file once the turn has ended.
def saved(path: String) -> Result[String]
  for _i in 1..200
    case File.read_text(path)
      ok(text) if text.include?("turn_finished") -> return ok(text)
      _ -> Task.sleep(50)
    end
  end

  File.read_text(path)
end
