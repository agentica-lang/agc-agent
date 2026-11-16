import LLM from "pkg/llm/llm"
import Cli from "../src/cli"
import Config from "../src/config"

def test_version_names_core_and_llm() -> Result[Void]
  try Test.eq(Cli.parse(["--version"]), ok(Cli.Command.Version))
  Test.eq(Cli.output(Cli.Command.Version), "Finn Agent core #{Cli.VERSION} (llm #{LLM.VERSION})")
end

def test_no_arguments_shows_help() -> Result[Void]
  try Test.eq(Cli.parse([]), ok(Cli.Command.Help))
  Test.eq(Cli.parse(["-h"]), ok(Cli.Command.Help))
end

def test_unknown_arguments_fail() -> Result[Void] = Test.error?(Cli.parse(["--nope"]))

def test_the_context_window_must_be_a_positive_number() -> Result[Void]
  for bad in ["0", "-5", "lots"]
    try Test.error?(Config.from_env(->(name) { env(name, bad) }))
  end

  options = try Config.from_env(->(name) { env(name, "32768") })
  try Test.eq(options.context_window, some(32768))
  Test.eq(options.props_url, "http://127.0.0.1:8080/props")
end

def test_the_model_api_is_chat_completions_responses_or_anthropic() -> Result[Void]
  for api in ["", "openai", "openai_responses"]
    try Config.from_env(->(name) { api_env(name, api) })
  end

  try Test.error?(Config.from_env(->(name) { api_env(name, "gemini") }))
  chat = try Config.from_env(->(name) { api_env(name, "") })
  try Test.eq(chat.api, "openai")
  responses = try Config.from_env(->(name) { api_env(name, "openai_responses") })
  try Test.eq(responses.api, "openai_responses")
  names = responses.apis.keys.map { |name| "#{name} #{responses.apis[name].provider.name}" }
  try Test.eq(names.sort, ["anthropic anthropic", "openai openai_chat", "openai_responses openai_responses"])
  try Test.eq(JSON.encode(JSON.object(responses.apis["openai"].extra)), "{}")
  stateless = responses.apis["openai_responses"].extra
  Test.eq(JSON.encode(JSON.object(stateless)), "{\"include\":[\"reasoning.encrypted_content\"],\"store\":false}")
end

# The Anthropic credential: `ANTHROPIC_API_KEY`, else `ANTHROPIC_AUTH_TOKEN`, else, only when `FINN_API` is
# `anthropic`, the token of `ant`; with none, `FINN_API=anthropic` is an error that does not show what `ant` printed.
# Anthropic never gets `FINN_API_KEY`, and its default model is Claude Opus 5.5.
def test_the_anthropic_credential_comes_in_its_order() -> Result[Void]
  both = {"FINN_API": "anthropic", "ANTHROPIC_API_KEY": "k", "ANTHROPIC_AUTH_TOKEN": "t", "FINN_API_KEY": "openai"}
  token = {"FINN_API": "anthropic", "ANTHROPIC_AUTH_TOKEN": "t"}
  bare = {"FINN_API": "anthropic", "FINN_API_KEY": "openai"}
  given: Fn[Result[String]] = -> { ok("from-ant") }
  refused: Fn[Result[String]] = -> { error("ant auth print-credentials failed: run ant auth login") }
  never: Fn[Result[String]] = -> { error("ant was asked") }
  try Test.eq(Config.anthropic_access(->(n) { from_map(both, n) }, true, never), ok(access(api_key: "k")))
  try Test.eq(Config.anthropic_access(->(n) { from_map(token, n) }, true, never), ok(access(auth_token: "t")))
  try Test.eq(Config.anthropic_access(->(n) { from_map(bare, n) }, true, given), ok(access(auth_token: "from-ant")))
  try Test.eq(Config.anthropic_access(->(n) { from_map(bare, n) }, false, never), ok(access()))
  failed = Config.from_env_with(->(n) { located(bare, n) }, refused)
  try Test.assert(not failed.ok? and failed.message.include?("ANTHROPIC_API_KEY"), failed.message)
  options = try Config.from_env_with(->(n) { located(token, n) }, never)
  try Test.eq([options.api, options.model], ["anthropic", LLM.ANTHROPIC_MODEL])
  Test.eq(options.apis["anthropic"].cache, true)
end

def access(api_key: String = "", auth_token: String = "") -> Config.AnthropicAccess
  Config.AnthropicAccess(url: LLM.ANTHROPIC_URL, api_key: api_key, auth_token: auth_token, inherit: false)
end

def located(values: Map[String, String], name: String) -> Result[String]
  return ok("/state") if name == "FINN_STATE_DIR"
  return ok("/data") if name == "FINN_DATA_DIR"

  from_map(values, name)
end

# The names of before Finn still work: `AGC_AGENT_` variables, and an `agc-agent` folder while no `finn` folder
# is there.
def test_the_names_before_finn_still_work() -> Result[Void]
  base = "#{System.env("TMPDIR").unwrap_or("/tmp")}/finn-config-#{Random.int(0, 999_999_999)}"
  try Dir.mkdir(base)
  try Dir.mkdir("#{base}/agc-agent")
  old = {
    "AGC_AGENT_API": "openai_responses",
    "AGC_AGENT_MODEL": "m",
    "FINN_MODEL": "",
    "XDG_STATE_HOME": base,
    "XDG_DATA_HOME": base,
  }

  options = try Config.from_env(->(name) { from_map(old, name) })
  try Test.eq(
    [options.api, options.model, options.state_dir, options.data_dir],
    ["openai_responses", "m", "#{base}/agc-agent", "#{base}/agc-agent"],
  )

  try Dir.mkdir("#{base}/finn")
  options = try Config.from_env(->(name) { from_map({"XDG_STATE_HOME": base, "XDG_DATA_HOME": base}, name) })
  try Test.eq([options.state_dir, options.data_dir], ["#{base}/finn", "#{base}/finn"])
  Path.remove(base)
end

private

def from_map(values: Map[String, String], name: String) -> Result[String]
  case values.get(name)
    some(value) -> ok(value)
    none -> error("not set")
  end
end

def api_env(name: String, api: String) -> Result[String]
  return ok(api) if name == "FINN_API"

  env(name, "")
end

def env(name: String, window: String) -> Result[String]
  case name
    "FINN_CONTEXT_WINDOW" -> ok(window)
    "FINN_STATE_DIR" -> ok("/state")
    "FINN_DATA_DIR" -> ok("/data")
    _ -> error("not set")
  end
end
