# The `opencode-go` preset: its key comes from `OPENCODE_API_KEY` or a stored login (the variable wins), its default
# model is `deepseek-v4.1-flash`, and a chat call goes to its URL with that key as a Bearer token and the model asked
# for. A session on it names itself in the headers. The fake answers in place of the real URL; the preset's own base
# URL is checked as given.

import HTTP from "std/http"
import LLM from "pkg/llm/llm"
import Config from "../src/config/config"
import Providers from "../src/providers/providers"
import Fake from "support/fake_llm"
import H from "support/harness"

MODEL = "deepseek-v4.1-flash"
REAL_URL = "https://opencode.ai/inference/go/v1"

def test_the_preset_takes_its_key_from_the_variable_or_a_login() -> Result[Void]
  preset = try opencode()
  try Test.eq(
    [preset.base_url, preset.key_env, preset.api, preset.model],
    [REAL_URL, "OPENCODE_API_KEY", "openai", MODEL],
  )

  bare: Map[String, String] = {}
  set = {"OPENCODE_API_KEY": "sk-env"}
  stored = {"opencode-go": "sk-stored"}
  try Test.eq(offered([preset], bare, bare).keys, [])
  try Test.eq(offered([preset], set, bare).keys, ["opencode-go"])
  try Test.eq(offered([preset], bare, stored).keys, ["opencode-go"])
  both = offered([preset], set, stored)
  try Test.eq(both.keys, ["opencode-go"])
  Test.eq(both["opencode-go"].apis["openai"].model, MODEL)
end

# A session that names no provider model starts on the preset's own.
def test_a_session_on_the_preset_without_a_model_takes_the_default_model() -> Result[Void]
  config = try Config.from_env(->(n) { located({"OPENCODE_API_KEY": "sk-env", "FINN_PROVIDER": "opencode-go"}, n) })
  try Test.eq([config.provider, config.model], ["opencode-go", MODEL])
  other = try Config.from_env(->(n) { located({"OPENCODE_API_KEY": "sk-env", "FINN_MODEL": "kimi-k3"}, n) })
  Test.eq([other.provider, other.model], ["local", "kimi-k3"])
end

def test_a_chat_call_sends_the_key_and_the_model_to_the_preset_url() -> Result[Void]
  within_fake([try Fake.sse("openai_chat/text.sse")]) do |fake|
    origin = fake.url.replace("/v1", "")
    preset = (try opencode()).with(base_url: REAL_URL.replace("https://opencode.ai", origin))
    read = ->(name: String) { {"OPENCODE_API_KEY": "sk-env"}.get(name).to_result("not set") }
    keyed = Providers.offered([preset], read, LLM.Options(), {"opencode-go": "sk-stored"})
    provider = keyed["opencode-go"].apis["openai"].provider
    message = LLM.Message(role: LLM.Role.User, content: [LLM.Block.Text(LLM.TextPart(text: "Say hello."))])
    call = try LLM.stream(provider, LLM.Request(model: MODEL, system: "Be brief.", messages: [message]))
    _ = LLM.response(call)
    seen = try Fake.next_request(fake)
    try Test.eq([seen.method, seen.path], ["POST", "/inference/go/v1/chat/completions"])
    try Test.eq(HTTP.header_values(seen.headers, "authorization"), ["Bearer sk-env"])
    Test.eq(JSON.get(try JSON.parse(seen.body), "model"), ok(JSON.from(MODEL)))
  end
end

# The session id and the client go in the headers of each call of the preset, and of no other provider.
def test_a_session_on_the_preset_names_itself_in_the_headers() -> Result[Void]
  setup = H.Setup(replies: ["text.sse", "text.sse", "text.sse"], presets: ["opencode-go"], approvals: false)
  H.using(setup) do |h|
    id = try H.new_session_in(h, h.work, provider: some("opencode-go"))
    try Test.eq((try H.session(h, id)).model, MODEL)
    _ = try H.send(h, id, "Hello.")
    _ = try H.idle(h, id)
    _ = try H.send(h, id, "Again.")
    _ = try H.idle(h, id)
    first = try H.next_request(h)
    second = try H.next_request(h)
    try Test.eq([first.path, second.path], ["/opencode-go/chat/completions", "/opencode-go/chat/completions"])
    try Test.eq(HTTP.header_values(first.headers, "x-opencode-session"), [id])
    try Test.eq(HTTP.header_values(second.headers, "x-opencode-session"), [id])
    try Test.eq(HTTP.header_values(second.headers, "x-opencode-client"), ["finn"])
    try Test.eq(HTTP.header_values(first.headers, "authorization"), ["Bearer sk-opencode-go"])
    try Test.eq(JSON.get(try JSON.parse(second.body), "model"), ok(JSON.from(MODEL)))
    other = try H.new_session(h)
    _ = try H.send(h, other, "Hello.")
    _ = try H.idle(h, other)
    plain = try H.next_request(h)
    named = ["x-opencode-session", "x-opencode-client"].map { |name| HTTP.header_values(plain.headers, name) }
    try Test.eq(named, [[], []])
    Test.eq(plain.path, "/v1/chat/completions")
  end
end

def opencode() -> Result[Providers.Custom]
  found = Providers.presets().select { |p| p.name == "opencode-go" }
  return error("no opencode-go preset") if found.empty?

  ok(found[0])
end

def offered(
  customs: List[Providers.Custom],
  env: Map[String, String],
  stored: Map[String, String],
) -> Map[String, Providers.Provider]
  read = ->(name: String) { env.get(name).to_result("not set") }
  Providers.offered(customs, read, LLM.Options(), stored)
end

# The fake is stopped however `body` ends.
def within_fake(replies: List[Fake.Reply], body: Fn[Fake.Fake, Result[Void]]) -> Result[Void]
  fake = try Fake.start(replies)
  result = body.call(fake)
  _ = Fake.stop(fake)
  result
end

def located(values: Map[String, String], name: String) -> Result[String]
  return ok("/state") if name == "FINN_STATE_DIR"
  return ok("/data") if name == "FINN_DATA_DIR"

  values.get(name).to_result("not set")
end
