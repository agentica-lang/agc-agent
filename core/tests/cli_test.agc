import LLM from "pkg/llm/llm"
import Cli from "../src/config/cli"
import Config from "../src/config/config"

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
  try Test.eq([chat.provider, chat.providers[chat.provider].api], ["local", "openai"])
  responses = try Config.from_env(->(name) { api_env(name, "openai_responses") })
  try Test.eq(responses.providers["local"].api, "openai_responses")
  apis = responses.providers["local"].apis
  names = apis.keys.map { |name| "#{name} #{apis[name].provider.name}" }
  try Test.eq(names.sort, ["openai openai_chat", "openai_responses openai_responses"])
  try Test.eq(JSON.encode(JSON.object(apis["openai"].extra)), "{}")
  stateless = apis["openai_responses"].extra
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
  claude = ->(o: Config.Options) { o.providers["anthropic"].apis["anthropic"] }
  try Test.eq([options.provider, options.model], ["anthropic", LLM.ANTHROPIC_MODEL])
  try Test.eq([claude.call(options).cache, claude.call(options).refresh.some?], [true, false])
  from_ant = try Config.from_env_with(->(n) { located(bare, n) }, given)
  try Test.eq(claude.call(from_ant).refresh.some?, true)
  on_openai = try Config.from_env_with(->(n) { located({"FINN_API_KEY": "openai"}, n) }, never)
  try Test.eq(claude.call(on_openai).refresh.some?, true)
  local = on_openai.providers["local"].apis
  try Test.eq(claude.call(on_openai).local, false)
  Test.eq(local.keys.select { |name| local[name].local }.sort, ["openai", "openai_responses"])
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

# A preset is offered when its key is set; the config file adds providers (one with a key variable only when it is
# set) and refuses a bad one; FINN_PROVIDER picks the default among those offered.
def test_providers_come_from_presets_with_a_key_and_the_config_file() -> Result[Void]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/core-providers-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  custom = "{\"name\": \"box\", \"base_url\": \"http://box/v1\", \"models\": [\"q\"]}"
  keyed = "{\"name\": \"paid\", \"base_url\": \"http://paid/v1\", \"key_env\": \"PAID_KEY\"}"
  shared = "{\"name\": \"proxy\", \"base_url\": \"http://proxy/v1\", \"key_env\": \"FIREWORKS_API_KEY\"}"
  try File.write_text("#{dir}/config.json", "{\"providers\": [#{custom}, #{keyed}, #{shared}]}")
  try File.write_text("#{dir}/bad.json", "{\"providers\": [{\"name\": \"x\", \"base_url\": \"\"}]}")
  try File.write_text("#{dir}/slash.json", "{\"providers\": [{\"name\": \"a/b\", \"base_url\": \"http://a/v1\"}]}")
  bare = try Config.from_env(->(n) { located({}, n) })
  keys = {
    "FIREWORKS_API_KEY": "fw",
    "FINN_CONFIG": "#{dir}/config.json",
    "FINN_PROVIDER": "fireworks",
    "FINN_MODEL": "k",
  }

  given = try Config.from_env(->(n) { located(keys, n) })
  missing = Config.from_env(->(n) { located({"FINN_PROVIDER": "fireworks"}, n) })
  broken = Config.from_env(->(n) { located({"FINN_CONFIG": "#{dir}/bad.json"}, n) })
  slash = Config.from_env(->(n) { located({"FINN_CONFIG": "#{dir}/slash.json"}, n) })
  _ = Path.remove(dir)
  try Test.eq(bare.providers.keys.sort, ["anthropic", "local"])
  try Test.eq(given.providers.keys.sort, ["anthropic", "box", "fireworks", "local", "proxy"])
  try Test.eq([given.key_envs["paid"], given.key_envs["groq"]], ["PAID_KEY", "GROQ_API_KEY"])
  try Test.eq(given.warnings, ["providers fireworks and proxy both take FIREWORKS_API_KEY"])
  try Test.eq([given.provider, given.model, given.providers["fireworks"].catalog], ["fireworks", "k", "fireworks-ai"])
  try Test.eq(given.providers["box"].models, ["q"])
  Test.eq([missing.ok?, broken.ok?, slash.ok?], [false, false, false])
end

# A key a login stored offers its provider; a key file that others may read is not used, with a warning. The login
# entries are `anthropic` and the presets.
def test_a_stored_key_offers_its_provider_unless_the_file_is_open() -> Result[Void]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/core-auth-#{Random.int(0, 999999999)}"
  try Dir.mkdir("#{dir}/finn")
  file = "#{dir}/finn/auth.json"
  try File.write_text(file, "{\"keys\": {\"groq\": \"sk-g\"}}")
  try chmod("600", file)
  private = try Config.from_env(->(n) { located({"XDG_CONFIG_HOME": dir}, n) })
  try chmod("644", file)
  open = try Config.from_env(->(n) { located({"XDG_CONFIG_HOME": dir}, n) })
  _ = Path.remove(dir)
  try Test.eq([private.providers.has_key?("groq"), open.providers.has_key?("groq")], [true, false])
  try Test.eq([private.warnings.size, open.warnings.size], [0, 1])
  chosen = try Config.from_env(->(n) { located({"XDG_CONFIG_HOME": dir, "FINN_BASE_URL": "http://box/v1"}, n) })
  try Test.eq([private.login.map { |l| l.chosen }, chosen.login.map { |l| l.chosen }], [some(false), some(true)])
  names = private.login.map { |l| l.entries.map { |e| e.name } }.unwrap_or([])
  Test.eq(names, ["anthropic", "openai", "fireworks", "openrouter", "groq", "deepseek"])
end

def chmod(mode: String, path: String) -> Result[Void]
  process = try Process.spawn("chmod", [mode, path])
  code = Process.wait(process, 5000)
  Process.close(process)
  return error("chmod failed") if code != ok(0)

  ok()
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
    [options.providers[options.provider].api, options.model, options.state_dir, options.data_dir],
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
