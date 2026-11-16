## The options of `serve`, from the environment: `FINN_STATE_DIR` (else `$XDG_STATE_HOME/finn`, else
## `~/.local/state/finn`), `FINN_DATA_DIR` for the sessions (else `$XDG_DATA_HOME/finn`, else
## `~/.local/share/finn`), and the model API: `FINN_API` (`openai`, chat completions, by default, or
## `openai_responses`), `FINN_BASE_URL` (a local llama-server by default), `FINN_API_KEY` and
## `FINN_MODEL`; `FINN_CONTEXT_WINDOW` and `FINN_COMPACT_MODEL` for compaction; `FINN_DRAIN_MS` (how long a stop waits for the turns,
## 60000); `FINN_MODELS_URL` (the models.dev
## catalog of prices and windows, `off` for none) and `FINN_MODELS_PROVIDER` (the provider of the model there).
## `FINN_CODE_MODE=1` adds code mode, whose Monty worker is `FINN_MONTY` (a trusted Monty 1.6.0 binary: its hash is
## not checked), else the pinned one fetched on first use into `$XDG_CACHE_HOME/finn` (else `~/.cache/finn`, which must be private to the user). Skills:
## those of the home folder always, those of a session folder only under a folder of `FINN_TRUSTED_DIRS` (separated by
## `:`). Approval rules: the user's config file (`FINN_CONFIG`, else `$XDG_CONFIG_HOME/finn/config.json`, else
## `~/.config/finn/config.json`) and the project file `.finn/config.json` (`Permissions`). The names of before Finn
## still work: `AGC_AGENT_` in place of `FINN_`, and an `agc-agent` folder while no `finn` folder is there.
##
## The `anthropic` API is at `ANTHROPIC_BASE_URL` (else Anthropic's), with `ANTHROPIC_API_KEY`, else
## `ANTHROPIC_AUTH_TOKEN`, else the token that `ant auth print-credentials --access-token` prints: at start when
## `FINN_API` is `anthropic`, else at a session's first call, and again after a 401. Its default model is Claude Opus
## 5.5. A credential is never logged.

import LLM from "pkg/llm/llm"
import Monty from "pkg/monty/monty"
import Approval from "../approval/approval"
import Auth from "auth"
import Catalog from "../agent/catalog"
import CodeMode from "../tools/code_mode"
import Logins from "logins"
import Permissions from "../approval/permissions"
import Providers from "providers"
import Tools from "../tools/tools"

export Providers.ModelApi
export Providers.Provider

STATE_DIR_ENV = "FINN_STATE_DIR"
DATA_DIR_ENV = "FINN_DATA_DIR"
PREFIX = "FINN_"
OLD_PREFIX = "AGC_AGENT_"
DEFAULT_BASE_URL = "http://127.0.0.1:8080/v1"
## The model of a session on an OpenAI API of a server whose own API has its own model (Anthropic).
DEFAULT_MODEL = "default"
## The names `FINN_API` takes: OpenAI chat completions, the OpenAI Responses format, and Anthropic Messages.
APIS = ["openai", "openai_responses", "anthropic"]
ANT_MS = 15000
## The check of a key at a login waits at most this long.
PROBE_MS = 10_000

struct Options
  state_dir: String
  data_dir: String
  ## The providers by name (`Providers`), the one of a session that names none, and its model.
  providers: Map[String, Providers.Provider]
  provider: String
  model: String
  ## The key variable of each provider that has one, offered or not, for the hint of a session on one not offered.
  key_envs: Map[String, String] = {}
  ## What the server warns about when it starts.
  warnings: List[String] = []
  ## What a login needs; none turns logins off. The holder of the providers once the server runs (`now`).
  login: Optional[Logins.Setup] = none
  logins: Optional[Logins.Holder] = none
  env: Fn[String, Result[String]]
  ## The rules of the approval extension; none turns it off, and every tool call runs without asking.
  approvals: Optional[Approval.Rules] = none
  ## The tools of the MCP servers, and those of the servers that list them after the start.
  tools: List[Tools.Tool] = []
  late_tools: Optional[Fn[List[Tools.Tool]]] = none
  port: Int = 0
  keep_events: Int = 1000
  approval_timeout_ms: Int = 90000
  ## How long a stop of the server waits for the running turns before it cancels them.
  drain_ms: Int = 60000
  ## The model's window in tokens; none asks the provider (`GET /models`).
  context_window: Optional[Int] = none
  ## The model that writes the summary of a compaction; empty is the session's model.
  compact_model: String = ""
  ## llama-server's `/props`, asked for the window before `GET /models`; empty for another API.
  props_url: String = ""
  ## The key `/props` takes, as the provider's.
  api_key: String = ""
  ## Runs in the task that loads a session, with its id, before the file is read: a seam for the tests.
  before_load: Optional[Fn[String, Void]] = none
  ## Runs in that task once what it read is on its way to the registry: a seam for the tests.
  after_load: Optional[Fn[String, Void]] = none
  ## Code mode: the model may also call the tools from a Python script (`run_script`).
  code_mode: Optional[CodeMode.Settings] = none
  ## The models.dev catalog (`main.agc` starts it from `models_url`), for the cost of the calls and the window.
  catalog: Optional[Catalog.Catalog] = none
  models_url: String = Catalog.URL
  ## The provider of the model in the catalog; empty is `anthropic` for that API and `openai` for the others.
  models_provider: String = ""
  ## How long a turn waits for the messages queued for it (tests shorten it).
  take_ms: Int = 5000
  ## How long a turn waits for a catalog that still loads (tests shorten it).
  catalog_wait_ms: Int = 1500
  ## The home folder, whose skills every session has; empty for none.
  home: String = ""
  ## The folders whose sessions load the skills of their own folder: a project's skills are its instructions.
  trusted: List[String] = []
end

## What the providers of a server are built from: its environment and its own model API.
struct Server
  read: Fn[String, Result[String]]
  base_url: String
  api_key: String
  api: String
  ant: Fn[Result[String]]
end

## Where the `anthropic` API is and how a request proves who sends it: an API key, else an OAuth token.
struct AnthropicAccess
  url: String = ""
  api_key: String = ""
  auth_token: String = ""
  ## With no key and no token, use the OpenAI ones (`base_url`, `api_key`): for a local server that serves both.
  inherit: Bool = true
  ## Fetches the token of `ant` again after a 401 (an expired token), or first when no variable has a credential.
  ant: Optional[Fn[Result[String]]] = none
end

def from_env(read: Fn[String, Result[String]]) -> Result[Options] = from_env_with(read, &ant_token)

## `ant` gives the OAuth token of `ant auth login` when no variable has a credential and `FINN_API` is `anthropic`.
def from_env_with(read: Fn[String, Result[String]], ant: Fn[Result[String]]) -> Result[Options]
  base_url = set(read, "FINN_BASE_URL").unwrap_or(DEFAULT_BASE_URL)
  api_key = set(read, "FINN_API_KEY").unwrap_or("")
  api = set(read, "FINN_API").unwrap_or(APIS[0])
  return error("FINN_API must be one of #{APIS.join(", ")}, not #{api.inspect}") if not APIS.include?(api)

  model = DEFAULT_MODEL
  if api == "anthropic"
    model = LLM.ANTHROPIC_MODEL
  end

  customs = Providers.presets()
  for path in option_list(Permissions.config_path(read))
    customs = customs + try Providers.from_file(path)
  end

  auth_path = Auth.path(read)
  stored = auth_path.map { |path| Auth.load(path, Auth.owner(read)) }.unwrap_or(Auth.Stored())
  rebuild = ->(keys: Map[String, String]) {
    all_providers(Server(read: read, base_url: base_url, api_key: api_key, api: api, ant: ant), customs, keys)
  }

  providers = try rebuild.call(stored.keys)
  anthropic_url = set(read, "ANTHROPIC_BASE_URL").unwrap_or(LLM.ANTHROPIC_URL)
  login = Logins.Setup(
    path: auth_path,
    stored: stored,
    entries: login_entries(customs, anthropic_url),
    read: read,
    rebuild: rebuild,
    probe: ->(name: String, key: String) { probe(customs, anthropic_url, name, key) },
    chosen: ["FINN_BASE_URL", "FINN_PROVIDER", "FINN_API"].any? { |name| set(read, name).some? },
  )

  provider = set(read, "FINN_PROVIDER").unwrap_or(default_provider(api))
  if not providers.has_key?(provider)
    return error(
      "FINN_PROVIDER #{provider.inspect} is not offered (is its key set?): one of #{providers.keys.join(", ")}",
    )
  end

  if provider != default_provider(api)
    model = DEFAULT_MODEL
  end

  ok(
    Options(
      state_dir: try state_dir(read),
      data_dir: try data_dir(read),
      providers: providers,
      provider: provider,
      key_envs: Providers.key_envs(customs),
      warnings: Providers.shared_keys(customs) + [stored.refused].select { |w| not w.empty? },
      login: some(login),
      model: set(read, "FINN_MODEL").unwrap_or(model),
      env: read,
      approvals: some(try Permissions.user_rules(read)),
      context_window: try context_window(read),
      drain_ms: try drain_ms(read),
      compact_model: set(read, "FINN_COMPACT_MODEL").unwrap_or(""),
      props_url: props_url(base_url),
      api_key: api_key,
      code_mode: try code_mode(read),
      models_url: set(read, "FINN_MODELS_URL").unwrap_or(Catalog.URL),
      models_provider: set(read, "FINN_MODELS_PROVIDER").unwrap_or(""),
      home: set(read, "HOME").unwrap_or(""),
      trusted: set(read, "FINN_TRUSTED_DIRS").unwrap_or("").split(":").select { |dir| dir != "" },
    ),
  )
end

## `options` with the providers the server offers now (a login or a logout changes them).
def now(options: Options) -> Options
  for holder in option_list(options.logins)
    case Logins.providers(holder)
      ok(providers) -> return options.with(providers: providers)
      error(_) -> nil
    end
  end

  options
end

## Every provider of a server whose env is `server`, with the keys a login stored: the built-in ones, then those of
## `customs` that have a key; a variable wins over a stored key.
def all_providers(
  server: Server,
  customs: List[Providers.Custom],
  keys: Map[String, String],
) -> Result[Map[String, Providers.Provider]]
  stored = keys.get(Providers.ANTHROPIC).unwrap_or("")
  access = try anthropic_access(server.read, server.api == "anthropic", server.ant, stored)
  providers = builtin(apis(server.base_url, server.api_key, LLM.Options(), access), server.api)
  offered = Providers.offered(customs, server.read, LLM.Options(), keys)
  for name in offered.keys
    providers = providers.put(name, offered[name])
  end

  ok(providers)
end

## The providers a key logs in to: `anthropic`, then those of `customs` with a key variable (a later one of a name
## replaces an earlier one).
def login_entries(customs: List[Providers.Custom], anthropic_url: String) -> List[Providers.Custom]
  claude = Providers.Custom(
    name: Providers.ANTHROPIC,
    api: "anthropic",
    base_url: anthropic_url,
    key_env: "ANTHROPIC_API_KEY",
  )

  out = [claude]
  for custom in (customs.select { |c| not c.key_env.empty? })
    out = out.select { |e| e.name != custom.name }.push(custom)
  end

  out
end

## The provider `name` at its own base URL with `key`, for the check of a login: one try, a short wait.
def probe(customs: List[Providers.Custom], anthropic_url: String, name: String, key: String) -> Result[LLM.Provider]
  options = LLM.Options(timeout_ms: PROBE_MS, tries: 1)
  return ok(LLM.anthropic(anthropic_url, key, options)) if name == Providers.ANTHROPIC

  found = customs.select { |c| c.name == name }
  return error("no provider #{name}") if found.empty?

  ok(LLM.openai_chat(found[found.size - 1].base_url, key, options))
end

## Code mode when `FINN_CODE_MODE` is `1`: the worker is found when the first script runs.
def code_mode(read: Fn[String, Result[String]]) -> Result[Optional[CodeMode.Settings]]
  switch = set(read, "FINN_CODE_MODE").unwrap_or("0")
  return ok(none) if switch == "0"
  return error("FINN_CODE_MODE must be 0 or 1, not #{switch.inspect}") if switch != "1"

  binary = set(read, "FINN_MONTY")
  cache = try cache_dir(read)
  worker = -> { worker_command(binary, cache) }
  ok(some(CodeMode.Settings(worker: worker, limits: Monty.Limits())))
end

def worker_command(binary: Optional[String], cache: String) -> Result[List[String]]
  for path in option_list(binary)
    return ok(Monty.command(path))
  end

  wheel = try Monty.wheel(try Monty.platform())
  ok(Monty.command(try Monty.binary(cache, wheel)))
end

## Every model API by its `FINN_API` name: the OpenAI ones at `base_url`, Anthropic as `anthropic` says (at
## `base_url` with `api_key` when it inherits them, as in tests). On the Responses format the API keeps nothing (`store: false`): the
## session file has the history, and the reasoning comes back in its encrypted content. On Anthropic the prompt cache
## is asked for: the system prompt and the tools, and the conversation so far.
def apis(
  base_url: String,
  api_key: String,
  options: LLM.Options = LLM.Options(),
  anthropic: AnthropicAccess = AnthropicAccess(),
) -> Map[String, Providers.ModelApi]
  access = anthropic
  if access.inherit
    access = access.with(url: base_url, api_key: api_key)
  end

  claude = LLM.anthropic(access.url, access.api_key, options, access.auth_token)
  refresh: Optional[Fn[Result[LLM.Provider]]] = none
  for ant in option_list(access.ant)
    url = access.url
    refresh = some(-> { ok(LLM.anthropic(url, "", options, try ant.call())) })
  end

  {
    "openai": Providers.ModelApi(provider: LLM.openai_chat(base_url, api_key, options)),
    "openai_responses": Providers.ModelApi(
      provider: LLM.openai_responses(base_url, api_key, options),
      extra: Providers.stateless(),
    ),
    "anthropic": Providers.ModelApi(
      provider: claude,
      model: LLM.ANTHROPIC_MODEL,
      cache: true,
      local: false,
      refresh: refresh,
    ),
  }
end

## The built-in providers of a server whose own model APIs are `apis` (`Config.apis`): `local` has the OpenAI ones,
## with `api` as its own when it is one, and `anthropic` the other.
def builtin(apis: Map[String, Providers.ModelApi], api: String) -> Map[String, Providers.Provider]
  openai = {"openai": apis["openai"], "openai_responses": apis["openai_responses"]}
  local_api = "openai"
  if openai.has_key?(api)
    local_api = api
  end

  {
    Providers.LOCAL: Providers.Provider(apis: openai, api: local_api),
    Providers.ANTHROPIC: Providers.Provider(apis: {"anthropic": apis["anthropic"]}, api: "anthropic"),
  }
end

## The provider of a server that names none: the one of its `FINN_API`.
def default_provider(api: String) -> String
  return Providers.ANTHROPIC if api == "anthropic"

  Providers.LOCAL
end

## The token of `ant auth login`, from `ant auth print-credentials --access-token`. Its output is never shown: a
## failure says only how `ant` ended.
def ant_token() -> Result[String] = ant_token_with("ant")

## `ant_token` with `program` in place of `ant`.
def ant_token_with(program: String) -> Result[String]
  failed = "ant auth print-credentials failed: run ant auth login"
  process = try Process.spawn_captured(program, ["auth", "print-credentials", "--access-token"])
  out = Process.output(process, ANT_MS)
  code = Process.wait(process, 5000)
  Process.close(process)
  return error(failed) if not out.ok? or code != ok(0)

  text = out.unwrap!.stdout.strip
  return error(failed) if text.empty?

  ok(text)
end

## `stored` is the key a login stored; the variables win over it, and it over `ant`.
def anthropic_access(
  read: Fn[String, Result[String]],
  default: Bool,
  ant: Fn[Result[String]],
  stored: String = "",
) -> Result[AnthropicAccess]
  url = read.call("ANTHROPIC_BASE_URL").unwrap_or("")
  if url == ""
    url = LLM.ANTHROPIC_URL
  end

  key = read.call("ANTHROPIC_API_KEY").unwrap_or("")
  return ok(AnthropicAccess(url: url, api_key: key, inherit: false)) if key != ""

  token = read.call("ANTHROPIC_AUTH_TOKEN").unwrap_or("")
  return ok(AnthropicAccess(url: url, auth_token: token, inherit: false)) if token != ""
  return ok(AnthropicAccess(url: url, api_key: stored, inherit: false)) if stored != ""
  # A session that picks Anthropic on a server of another API fetches the token at its first call (a 401).
  return ok(AnthropicAccess(url: url, inherit: false, ant: some(ant))) if not default

  case ant.call()
    ok(found) -> ok(AnthropicAccess(url: url, auth_token: found, inherit: false, ant: some(ant)))
    error(e) -> error("FINN_API is anthropic and there is no credential: set ANTHROPIC_API_KEY, or #{e.message}")
  end
end

def state_dir(read: Fn[String, Result[String]]) -> Result[String]
  folder(read, STATE_DIR_ENV, "XDG_STATE_HOME", "state")
end

def data_dir(read: Fn[String, Result[String]]) -> Result[String] = folder(read, DATA_DIR_ENV, "XDG_DATA_HOME", "share")

private

def folder(read: Fn[String, Result[String]], own: String, xdg: String, under_local: String) -> Result[String]
  for dir in option_list(set(read, own))
    return ok(dir)
  end

  for base in option_list(set(read, xdg))
    return named_folder(base)
  end

  named_folder(try Path.join([try read.call("HOME"), ".local", under_local]))
end

def named_folder(base: String) -> Result[String]
  dir = try Path.join([base, "finn"])
  old = try Path.join([base, "agc-agent"])
  return ok(old) if not File.stat(dir).ok? and File.stat(old).ok?

  ok(dir)
end

def set(read: Fn[String, Result[String]], name: String) -> Optional[String]
  names = [name]
  if name.start_with?(PREFIX)
    names = [name, "#{OLD_PREFIX}#{name.slice(PREFIX.length, name.length - PREFIX.length)}"]
  end

  for each in names
    value = read.call(each).unwrap_or("")
    return some(value) if value != ""
  end

  none
end

def drain_ms(read: Fn[String, Result[String]]) -> Result[Int]
  for text in option_list(set(read, "FINN_DRAIN_MS"))
    case text.to_i
      ok(ms) if ms >= 0 -> return ok(ms)
      _ -> return error("FINN_DRAIN_MS must be a number of milliseconds, not #{text.inspect}")
    end
  end

  ok(60000)
end

def context_window(read: Fn[String, Result[String]]) -> Result[Optional[Int]]
  for text in option_list(set(read, "FINN_CONTEXT_WINDOW"))
    case text.to_i
      ok(tokens) if tokens > 0 -> return ok(some(tokens))
      _ -> return error("FINN_CONTEXT_WINDOW must be a number of tokens over 0, not #{text.inspect}")
    end
  end

  ok(none)
end

# llama-server serves `/props` next to `/v1`.
def props_url(base_url: String) -> String
  base = base_url
  if base.end_with?("/")
    base = base.slice(0, base.length - 1)
  end

  return "" if not base.end_with?("/v1")

  "#{base.slice(0, base.length - 3)}/props"
end

def cache_dir(read: Fn[String, Result[String]]) -> Result[String]
  for base in option_list(set(read, "XDG_CACHE_HOME"))
    return Path.join([base, "finn"])
  end

  Path.join([try read.call("HOME"), ".cache", "finn"])
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
