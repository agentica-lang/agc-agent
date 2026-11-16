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

# The Anthropic credential: `ANTHROPIC_API_KEY`, else `ANTHROPIC_AUTH_TOKEN`, else the token of `ant`: at start when
# `FINN_API` is `anthropic` (with none, an error that does not show what `ant` printed), else at the first call. A
# token of `ant` is fetched again after a 401. Anthropic never gets `FINN_API_KEY`, and its default model is Claude
# Opus 5.5.
def test_the_anthropic_credential_comes_in_its_order() -> Result[Void]
  both = {"FINN_API": "anthropic", "ANTHROPIC_API_KEY": "k", "ANTHROPIC_AUTH_TOKEN": "t", "FINN_API_KEY": "openai"}
  token = {"FINN_API": "anthropic", "ANTHROPIC_AUTH_TOKEN": "t"}
  bare = {"FINN_API": "anthropic", "FINN_API_KEY": "openai"}
  given: Fn[Result[String]] = -> { ok("from-ant") }
  refused: Fn[Result[String]] = -> { error("ant auth print-credentials failed: run ant auth login") }
  never: Fn[Result[String]] = -> { error("ant was asked") }
  try Test.eq(shown(Config.anthropic_access(->(n) { from_map(both, n) }, true, never)), "k  false")
  try Test.eq(shown(Config.anthropic_access(->(n) { from_map(token, n) }, true, never)), " t false")
  try Test.eq(shown(Config.anthropic_access(->(n) { from_map(bare, n) }, true, given)), " from-ant true")
  try Test.eq(shown(Config.anthropic_access(->(n) { from_map(bare, n) }, false, never)), "  true")
  failed = Config.from_env_with(->(n) { located(bare, n) }, refused)
  try Test.assert(not failed.ok? and failed.message.include?("ANTHROPIC_API_KEY"), failed.message)
  options = try Config.from_env_with(->(n) { located(token, n) }, never)
  try Test.eq([options.api, options.model], ["anthropic", LLM.ANTHROPIC_MODEL])
  try Test.eq([options.apis["anthropic"].cache, options.apis["anthropic"].refresh.some?], [true, false])
  from_ant = try Config.from_env_with(->(n) { located(bare, n) }, given)
  try Test.eq(from_ant.apis["anthropic"].refresh.some?, true)
  on_openai = try Config.from_env_with(->(n) { located({"FINN_API_KEY": "openai"}, n) }, never)
  try Test.eq(on_openai.apis["anthropic"].refresh.some?, true)
  Test.eq(on_openai.apis.keys.select { |name| on_openai.apis[name].local }.sort, ["openai", "openai_responses"])
end

# The token is what `ant` prints, stripped; empty output or a failed `ant` is an error that does not show the output.
def test_the_ant_token_is_its_output() -> Result[Void]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/finn-ant-#{Random.int(0, 999_999_999)}"
  try Dir.mkdir(dir)
  results = ["printf ' tok\\n'", "printf '   \\n'", "echo secret; exit 1"].map { |body| fake_ant(dir, body) }

  _ = Path.remove(dir)
  try Test.eq(results[0], ok("tok"))
  try Test.error?(results[1])
  Test.assert(not results[2].ok? and not results[2].message.include?("secret"), results[2].message)
end

def fake_ant(dir: String, body: String) -> Result[String]
  path = "#{dir}/ant-#{body.length}"
  try File.write_text(path, "#!/bin/sh\n#{body}\n")
  try Process.output(try Process.spawn_captured("chmod", ["700", path]), 5000)
  Config.ant_token_with(path)
end

def shown(access: Result[Config.AnthropicAccess]) -> String
  case access
    ok(a) -> "#{a.api_key} #{a.auth_token} #{a.ant.some?}"
    error(e) -> "error #{e.message}"
  end
end

def located(values: Map[String, String], name: String) -> Result[String]
  return ok("/state") if name == "FINN_STATE_DIR"
  return ok("/data") if name == "FINN_DATA_DIR"

  from_map(values, name)
end

# No trusted folder when `FINN_TRUSTED_DIRS` is unset or empty; empty parts are skipped.
def test_the_trusted_folders_come_from_finn_trusted_dirs() -> Result[Void]
  for value in ["", ":"]
    unset = try Config.from_env(->(name) { trusted_env(name, value) })
    try Test.eq(unset.trusted.size, 0)
  end

  set = try Config.from_env(->(name) { trusted_env(name, "/a/b::/c") })
  try Test.eq(set.trusted, ["/a/b", "/c"])
  Test.eq(set.home, "/home/me")
end

def trusted_env(name: String, dirs: String) -> Result[String]
  return ok(dirs) if name == "FINN_TRUSTED_DIRS"
  return ok("/home/me") if name == "HOME"

  env(name, "")
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
