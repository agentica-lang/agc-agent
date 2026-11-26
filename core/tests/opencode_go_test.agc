# The `opencode-go` preset: its key comes from `OPENCODE_API_KEY` or a stored login (the variable wins), its default
# model is `deepseek-v4.1-flash`, and a chat call goes to its URL with that key as a Bearer token and the model asked
# for. A session on it names itself in the headers. The fake answers in place of the real URL; the preset's own base
# URL is checked as given.

import HTTP from "std/http"
import LLM from "pkg/llm/llm"
import Config from "../src/config/config"
import Catalog from "../src/providers/catalog"
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

# Each model goes to the API its catalog entry names, at the preset's URL with its key: chat completions, the
# Responses API, or the Anthropic Messages API. One of an API Finn does not speak (Google's) is not offered.
def test_each_model_goes_to_the_api_the_catalog_gives_it() -> Result[Void]
  tmp = System.env("TMPDIR").unwrap_or("/tmp")
  dir = "#{tmp}/core-opencode-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  json = try Fake.fixture("models_dev/api.json")
  json_type = HTTP.Header(name: "Content-Type", value: "application/json")
  http = try HTTP.serve(
    "127.0.0.1",
    0,
    HTTP.app(->(_r: HTTP.Request) { ok(HTTP.Response(status: 200, headers: [json_type], body: json)) }),
  )

  url = "http://127.0.0.1:#{HTTP.local_port(http)}/api.json"
  catalog = Catalog.start(Catalog.Options(url: url, cache: "#{dir}/models.json"))
  loaded = Catalog.wait(catalog, 10_000)
  setup = H.Setup(
    replies: ["text.sse", "anthropic/text.sse", "openai_responses/text.sse"],
    presets: ["opencode-go"],
    approvals: false,
    catalog: some(catalog),
  )

  result = H.using(setup) do |h|
    try Test.assert(loaded, "the catalog did not load")
    served: List[String] = []
    for model in ["deepseek-v4.1-flash", "qwen3.8-max", "gpt-6-luna"]
      id = try H.new_session_in(h, h.work, provider: some("opencode-go"), model: some(model))
      _ = try H.send(h, id, "Hello.")
      _ = try H.idle(h, id)
      seen = try H.next_request(h)
      key = (
        HTTP.header_values(seen.headers, "x-api-key").join("") +
        HTTP.header_values(seen.headers, "authorization").join("")
      )

      try Test.eq(HTTP.header_values(seen.headers, "x-opencode-session"), [id])
      try Test.eq(JSON.get(try JSON.parse(seen.body), "model"), ok(JSON.from(model)))
      served = served.push("#{seen.path} #{key}")
    end

    try Test.eq(
      served,
      [
        "/opencode-go/chat/completions Bearer sk-opencode-go",
        "/opencode-go/messages sk-opencode-go",
        "/opencode-go/responses Bearer sk-opencode-go",
      ],
    )

    Test.eq(
      Catalog.models(catalog, "opencode-go", true),
      ["deepseek-v4.1-flash", "gpt-6-luna", "kimi-k3", "qwen3.8-max"],
    )
  end

  Catalog.stop(catalog)
  HTTP.close_server(http)
  _ = HTTP.wait(http)
  _ = Path.remove(dir)
  result
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
    other = try H.new_session_in(h, h.work, provider: some("local"))
    _ = try H.send(h, other, "Hello.")
    _ = try H.idle(h, other)
    plain = try H.next_request(h)
    named = ["x-opencode-session", "x-opencode-client"].map { |name| HTTP.header_values(plain.headers, name) }
    try Test.eq(named, [[], []])
    Test.eq(plain.path, "/v1/chat/completions")
  end
end

# The summary of a fold is a call of its own, and OpenCode refuses it without the session header too.
def test_the_summary_call_of_a_fold_names_the_session_too() -> Result[Void]
  replies = ["text.sse", "summary.sse", "text.sse"]
  setup = H.Setup(replies: replies, presets: ["opencode-go"], approvals: false, context_window: 27)
  H.using(setup) do |h|
    id = try H.new_session_in(h, h.work, provider: some("opencode-go"))
    _ = try H.send(h, id, "Hello.")
    _ = try H.idle(h, id)
    _ = try H.send(h, id, "Again.")
    _ = try H.idle(h, id)
    _ = try H.next_request(h)
    summary = try H.next_request(h)
    try Test.eq(JSON.get(try JSON.parse(summary.body), "tools").ok?, false)
    try Test.eq(HTTP.header_values(summary.headers, "x-opencode-session"), [id])
    Test.eq(HTTP.header_values(summary.headers, "x-opencode-client"), ["finn"])
  end
end

# A `providers` entry named `opencode-go` with another URL replaces the preset and keeps its default model and headers.
def test_a_config_entry_that_replaces_the_preset_keeps_its_model_and_headers() -> Result[Void]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/core-opencode-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  entry = "{\"name\": \"opencode-go\", \"base_url\": \"http://proxy/v1\", \"key_env\": \"OPENCODE_API_KEY\"}"
  try File.write_text("#{dir}/config.json", "{\"providers\": [#{entry}]}")
  env = {"OPENCODE_API_KEY": "sk-env", "FINN_CONFIG": "#{dir}/config.json", "FINN_PROVIDER": "opencode-go"}
  config = Config.from_env(->(n) { located(env, n) })
  _ = Path.remove(dir)
  given = try config
  api = given.providers["opencode-go"].apis["openai"]
  try Test.eq(given.model, MODEL)
  Test.eq(api.headers, (try opencode()).headers)
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
