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

def test_the_model_api_is_chat_completions_or_responses() -> Result[Void]
  for api in ["", "openai", "openai_responses"]
    try Config.from_env(->(name) { api_env(name, api) })
  end

  try Test.error?(Config.from_env(->(name) { api_env(name, "anthropic") }))
  chat = try Config.from_env(->(name) { api_env(name, "") })
  try Test.eq(chat.api, "openai")
  responses = try Config.from_env(->(name) { api_env(name, "openai_responses") })
  try Test.eq(responses.api, "openai_responses")
  names = responses.apis.keys.map { |name| "#{name} #{responses.apis[name].provider.name}" }
  try Test.eq(names.sort, ["openai openai_chat", "openai_responses openai_responses"])
  try Test.eq(JSON.encode(JSON.object(responses.apis["openai"].extra)), "{}")
  stateless = responses.apis["openai_responses"].extra
  Test.eq(JSON.encode(JSON.object(stateless)), "{\"include\":[\"reasoning.encrypted_content\"],\"store\":false}")
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
