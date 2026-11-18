# The `opencode-go` preset: its key comes from `OPENCODE_API_KEY` or a stored login (the variable wins), and a chat
# call goes to its URL with that key as a Bearer token and the model asked for. The fake answers in place of the real
# URL; the preset's own base URL is checked as given.

import HTTP from "std/http"
import LLM from "pkg/llm/llm"
import Providers from "../src/providers/providers"
import Fake from "support/fake_llm"

MODEL = "deepseek-v4.1-flash"
REAL_URL = "https://opencode.ai/inference/go/v1"

def test_the_preset_takes_its_key_from_the_variable_or_a_login() -> Result[Void]
  preset = try opencode()
  try Test.eq([preset.base_url, preset.key_env, preset.api], [REAL_URL, "OPENCODE_API_KEY", "openai"])
  bare: Map[String, String] = {}
  set = {"OPENCODE_API_KEY": "sk-env"}
  stored = {"opencode-go": "sk-stored"}
  try Test.eq(offered([preset], bare, bare), [])
  try Test.eq(offered([preset], set, bare), ["opencode-go"])
  try Test.eq(offered([preset], bare, stored), ["opencode-go"])
  Test.eq(offered([preset], set, stored), ["opencode-go"])
end

def test_a_chat_call_sends_the_key_and_the_model_to_the_preset_url() -> Result[Void]
  fake = try Fake.start([try Fake.sse("openai_chat/text.sse")])
  origin = fake.url.replace("/v1", "")
  preset = (try opencode()).with(base_url: REAL_URL.replace("https://opencode.ai", origin))
  read = ->(name: String) { {"OPENCODE_API_KEY": "sk-env"}.get(name).to_result("not set") }
  keyed = Providers.offered([preset], read, LLM.Options(), {"opencode-go": "sk-stored"})
  provider = keyed["opencode-go"].apis["openai"].provider
  message = LLM.Message(role: LLM.Role.User, content: [LLM.Block.Text(LLM.TextPart(text: "Say hello."))])
  call = try LLM.stream(provider, LLM.Request(model: MODEL, system: "Be brief.", messages: [message]))
  _ = LLM.response(call)
  seen = try Fake.next_request(fake)
  try Fake.stop(fake)
  try Test.eq([seen.method, seen.path], ["POST", "/inference/go/v1/chat/completions"])
  try Test.eq(HTTP.header_values(seen.headers, "authorization"), ["Bearer sk-env"])
  Test.eq(JSON.get(try JSON.parse(seen.body), "model"), ok(JSON.from(MODEL)))
end

def opencode() -> Result[Providers.Custom]
  found = Providers.presets().select { |p| p.name == "opencode-go" }
  return error("no opencode-go preset") if found.empty?

  ok(found[0])
end

def offered(customs: List[Providers.Custom], env: Map[String, String], stored: Map[String, String]) -> List[String]
  read = ->(name: String) { env.get(name).to_result("not set") }
  Providers.offered(customs, read, LLM.Options(), stored).keys.sort
end
