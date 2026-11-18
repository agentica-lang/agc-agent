## The options of `serve`, from the environment: `FINN_STATE_DIR` (else `$XDG_STATE_HOME/finn`, else
## `~/.local/state/finn`), `FINN_DATA_DIR` for the sessions (else `$XDG_DATA_HOME/finn`, else `~/.local/share/finn`),
## and the model API: `FINN_API` (`openai`, chat completions, by default, or `openai_responses`), `FINN_BASE_URL` (a
## local llama-server by default), `FINN_API_KEY` and `FINN_MODEL`; `FINN_MAX_TOKENS` (the most tokens of a reply; by
## default the model's own limit in the catalog, else the API's); `FINN_CONTEXT_WINDOW` and `FINN_COMPACT_MODEL` for
## compaction; `FINN_DRAIN_MS` (how long a stop waits for the turns, 60000); `FINN_MODELS_URL` (the models.dev catalog
## of prices and windows, `off` for none) and `FINN_MODELS_PROVIDER` (the provider of the model there).
## Code mode is on unless `FINN_CODE_MODE=0` (`--no-codemode`); its Monty worker is `FINN_MONTY` (a trusted Monty 1.6.0
## binary: its hash is not checked), else the pinned one fetched at the first script into `$XDG_CACHE_HOME/finn` (else
## `~/.cache/finn`, which must be private to the user). With neither for this platform, there is no code mode. Skills: those of the home folder always, those of a session folder only under a folder of
## `FINN_TRUSTED_DIRS` (separated by `:`). Approval rules: the user's config file (`FINN_CONFIG`, else
## `$XDG_CONFIG_HOME/finn/config.json`, else `~/.config/finn/config.json`) and the project file `.finn/config.json`
## (`Permissions`); the deny rules always count, and a call no rule allows asks only when `FINN_APPROVALS=1`, or the
## user's file has `"approvals": true` and `FINN_APPROVALS` is not `0`. The user's file alone (never a project's) may
## name the command that lists the files for `@`: `"files": {"command": ["rg", "--files"]}`. The names of before Finn still work:
## `AGC_AGENT_` in place of `FINN_`, and an `agc-agent` state or data folder while no `finn` folder is there; but an
## old config file, `AGC_AGENT_CONFIG` or `AGC_AGENT_MCP_CONFIG` stops the start, and an old `auth.json` is a warning
## (`left_behind`).
##
## The `anthropic` API is at `ANTHROPIC_BASE_URL` (else Anthropic's), with `ANTHROPIC_API_KEY`, else
## `ANTHROPIC_AUTH_TOKEN`, else the token that `ant auth print-credentials --access-token` prints: at start when
## `FINN_API` is `anthropic`, else at a session's first call, and again after a 401. Its default model is Claude Opus
## 5.5. A credential is never logged.

import LLM from "pkg/llm/llm"
import Monty from "pkg/monty/monty"
import Approval from "../approval/approval"
import Auth from "../providers/auth"
import Catalog from "../providers/catalog"
import Chatgpt from "../providers/chatgpt"
import CodeMode from "../tools/code_mode"
import Logins from "../providers/logins"
import Offered from "../providers/offered"
import Permissions from "../approval/permissions"
import Providers from "../providers/providers"
import Extensions from "registry"
import Tools from "../tools/tools"

export Providers.ModelApi
export Providers.Provider

STATE_DIR_ENV = "FINN_STATE_DIR"
DATA_DIR_ENV = "FINN_DATA_DIR"
## The provider and model last picked, in the state folder.
CHOICE_FILE = "choice.json"
PREFIX = "FINN_"
OLD_PREFIX = "AGC_AGENT_"
DEFAULT_BASE_URL = "http://127.0.0.1:8080/v1"
## The model of a session on an OpenAI API of a server whose own API has its own model (Anthropic).
DEFAULT_MODEL = "default"
## The names `FINN_API` takes: OpenAI chat completions, the OpenAI Responses format, and Anthropic Messages.
APIS = ["openai", "openai_responses", "anthropic"]
## What a failed fetch of the worker says: how to go on without code mode.
NO_CODE_MODE = "finn --no-codemode (or FINN_CODE_MODE=0) turns code mode off"
## How long a failed fetch of the worker is given again without a new try.
FAILED_FETCH_MS = 600_000

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
  ## The rules of the approval extension; none turns it off, and every tool call runs. `asking`: a call that no rule
  ## allows waits for an answer; off, only the deny rules count. They reach the sessions only through
  ## `registry.approver` (`Builtins.approvals`): `Server.start` without it has no approval.
  approvals: Optional[Approval.Rules] = none
  asking: Bool = false
  ## The tools after the built-in ones: those of the extensions (the MCP servers' come later, through `registry`).
  tools: List[Tools.Tool] = []
  ## What the extensions add (`Core.serve`), with the core's own (the skills, MCP and the approval).
  registry: Optional[Extensions.Served] = none
  ## The observers of the extensions' `Seen` handlers, which the sessions start (`Sessions.start`).
  observers: List[Extensions.Observer] = []
  ## A test seam: makes the diff of each tool call (see `Tools.Context.diff`).
  diff: Optional[Fn[String, JSON.Value, String]] = none
  port: Int = 0
  keep_events: Int = 1000
  approval_timeout_ms: Int = 90000
  ## How long a stop of the server waits for the running turns before it cancels them.
  drain_ms: Int = 60000
  ## The model's window in tokens; none asks the provider (`GET /models`).
  context_window: Optional[Int] = none
  ## The output limit of every call (`FINN_MAX_TOKENS`); none takes the model's from the catalog, else the API's.
  max_tokens: Optional[Int] = none
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
  ## Code mode is off because this machine has no Monty worker, not because `FINN_CODE_MODE=0` asked.
  no_worker: Bool = false
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
  ## The folder of Finn's own documentation pages, which the built-in skill `finn` reads in place; empty for none.
  docs: String = ""
  ## The folders whose sessions load the skills of their own folder: a project's skills are its instructions.
  trusted: List[String] = []
  ## The program and arguments that list the files for `@`, from the user's config only; empty for the built-in walk.
  files_command: List[String] = []
  ## `FINN_PROVIDER` and `FINN_MODEL` are set: they win over the provider and model last picked.
  provider_pinned: Bool = false
  model_pinned: Bool = false
end

def from_env(read: Fn[String, Result[String]]) -> Result[Options] = from_env_with(read, &Offered.ant_token)

## `ant` gives the OAuth token of `ant auth login` when no variable has a credential and `FINN_API` is `anthropic`.
def from_env_with(read: Fn[String, Result[String]], ant: Fn[Result[String]]) -> Result[Options]
  moved = try left_behind(read)
  env_url = set(read, "FINN_BASE_URL")
  base_url = env_url.unwrap_or(DEFAULT_BASE_URL)
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
  owner = Auth.owner(read)
  states = try state_dir(read)
  chatgpt = try Chatgpt.login(states, owner, read)
  stored = auth_path.map { |path| Auth.load(path, owner) }.unwrap_or(Auth.Stored())
  # A base URL a login stored serves `local` unless FINN_BASE_URL is set.
  server = Offered.Server(
    read: read,
    base_url: local_url(base_url, env_url, stored.urls),
    api_key: api_key,
    api: api,
    ant: ant,
  )

  claude_key = stored.keys.get(Providers.ANTHROPIC).unwrap_or("")
  # `ant` runs here only: a login or a logout later builds the providers without it.
  at_start = try Offered.anthropic_access(read, api == "anthropic", ant, claude_key)
  rebuild = ->(keys: Map[String, String], urls: Map[String, String]) {
    current = server.with(base_url: local_url(base_url, env_url, urls))
    built = Offered.all_providers(current, customs, keys, Offered.access_for(current, keys, claude_key, at_start))
    Chatgpt.added(built, chatgpt, LLM.Options())
  }

  providers = try rebuild.call(stored.keys, stored.urls)
  choice_path = "#{states}/#{CHOICE_FILE}"
  choice = Logins.load_choice(choice_path)
  stale: List[String] = []
  for found in option_list(choice)
    if not providers.has_key?(found.provider)
      stale = stale.push(
        "the provider of the last choice, #{found.provider}, is not offered (is its key set?): new sessions use the default",
      )

      choice = none
    end
  end

  anthropic_url = set(read, "ANTHROPIC_BASE_URL").unwrap_or(LLM.ANTHROPIC_URL)
  login = Logins.Setup(
    path: auth_path,
    owner: owner,
    stored: stored,
    entries: Offered.login_entries(customs, anthropic_url),
    read: read,
    rebuild: rebuild,
    local_url: base_url,
    local_env: set_name(read, "FINN_BASE_URL").unwrap_or(""),
    local_key: api_key,
    chosen: ["FINN_BASE_URL", "FINN_PROVIDER", "FINN_API"].any? { |name| set(read, name).some? },
    chatgpt: some(chatgpt),
    choice: choice,
    choice_file: some(choice_path),
  )

  provider = set(read, "FINN_PROVIDER").unwrap_or(Offered.default_provider(api))
  if not providers.has_key?(provider)
    return error(
      "FINN_PROVIDER #{provider.inspect} is not offered (is its key set?): one of #{providers.keys.join(", ")}",
    )
  end

  if provider != Offered.default_provider(api)
    model = DEFAULT_MODEL
    own = providers[provider].apis[providers[provider].api].model
    if not own.empty?
      model = own
    end
  end

  user = try Permissions.user_rules(read, try approvals_switch(read))
  ok(
    Options(
      state_dir: states,
      data_dir: try data_dir(read),
      providers: providers,
      provider: provider,
      key_envs: Providers.key_envs(customs),
      warnings: (
        Providers.shared_keys(customs) +
        [stored.refused].select { |w| not w.empty? } +
        option_list(Chatgpt.refusal(chatgpt)) +
        stale +
        moved
      ),
      login: some(login),
      model: set(read, "FINN_MODEL").unwrap_or(model),
      env: read,
      approvals: some(user.rules),
      asking: user.asking,
      context_window: try context_window(read),
      max_tokens: try tokens_of(read, "FINN_MAX_TOKENS"),
      drain_ms: try drain_ms(read),
      compact_model: set(read, "FINN_COMPACT_MODEL").unwrap_or(""),
      props_url: props_url(server.base_url),
      api_key: api_key,
      code_mode: try code_mode(read),
      no_worker: no_worker?(read, &Monty.platform),
      models_url: set(read, "FINN_MODELS_URL").unwrap_or(Catalog.URL),
      models_provider: set(read, "FINN_MODELS_PROVIDER").unwrap_or(""),
      home: set(read, "HOME").unwrap_or(""),
      docs: docs_folder(read),
      trusted: set(read, "FINN_TRUSTED_DIRS").unwrap_or("").split(":").select { |dir| dir != "" },
      files_command: try files_command(read),
      provider_pinned: set(read, "FINN_PROVIDER").some?,
      model_pinned: set(read, "FINN_MODEL").some?,
    ),
  )
end

## `options` with the providers the server offers now (a login or a logout changes them), and the `/props` of the
## base URL `local` uses now.
def now(options: Options) -> Options
  for holder in option_list(options.logins)
    case Logins.current(holder)
      ok(current) -> return picked(offered_now(options, current), current)
      error(_) -> nil
    end
  end

  options
end

## `now` without the last choice: the providers as they are listed, the server's own provider and model.
def listed(options: Options) -> Options
  for holder in option_list(options.logins)
    case Logins.current(holder)
      ok(current) -> return offered_now(options, current)
      error(_) -> nil
    end
  end

  options
end

def offered_now(options: Options, current: Logins.Current) -> Options
  return options.with(providers: current.providers) if current.local_url.empty?

  options.with(providers: current.providers, props_url: props_url(current.local_url))
end

# The provider and model last picked are those of new sessions, unless `FINN_PROVIDER` is set (and `FINN_MODEL` for the
# model) or the provider is not offered any more.
def picked(options: Options, current: Logins.Current) -> Options
  for choice in option_list(current.choice)
    return options if options.provider_pinned or not options.providers.has_key?(choice.provider)

    found = options.providers[choice.provider]
    model = choice.model
    if options.model_pinned
      model = options.model
    elsif model.empty?
      model = found.apis[found.api].model
    end

    if model.empty?
      model = DEFAULT_MODEL
    end

    return options.with(provider: choice.provider, model: model)
  end

  options
end

## `FINN_APPROVALS`: `1` turns the approval extension on, `0` off; unset leaves it to the config file.
def approvals_switch(read: Fn[String, Result[String]]) -> Result[Optional[Bool]]
  case set(read, "FINN_APPROVALS")
    some("1") -> ok(some(true))
    some("0") -> ok(some(false))
    some(other) -> error("FINN_APPROVALS must be 0 or 1, not #{other.inspect}")
    none -> ok(none)
  end
end

## `files.command` of the user's config file: a program and its arguments, which the file must name with a program.
def files_command(read: Fn[String, Result[String]]) -> Result[List[String]]
  for path in option_list(Permissions.config_path(read))
    case JSON.decode(try File.read_text(path), FilesFile)
      ok(file) ->
        command = file.files.map { |files| files.command }.unwrap_or([])
        if file.files.some? and (command.empty? or command[0] == "")
          return error("#{path}: files.command must name a program")
        end

        return ok(command)
      error(e) -> return error("#{path}: files: #{e.message}")
    end
  end

  ok([])
end

## Code mode unless `FINN_CODE_MODE` is `0`, when there is a worker for this machine: `FINN_MONTY`, or a pinned wheel
## for `platform` (`Monty.platform`), which is fetched only when the first script runs.
def code_mode(read: Fn[String, Result[String]]) -> Result[Optional[CodeMode.Settings]]
  code_mode_on(read, &Monty.platform)
end

## Whether code mode, unless `FINN_CODE_MODE=0`, finds no worker on a machine whose platform `platform` says.
def no_worker?(read: Fn[String, Result[String]], platform: Fn[Result[String]]) -> Bool
  return false if set(read, "FINN_CODE_MODE") == some("0") or set(read, "FINN_MONTY").some?

  case platform.call()
    ok(found) -> not Monty.wheel(found).ok?
    error(_) -> true
  end
end

## `code_mode` on a machine whose platform `platform` says.
def code_mode_on(read: Fn[String, Result[String]], platform: Fn[Result[String]]) -> Result[Optional[CodeMode.Settings]]
  switch = set(read, "FINN_CODE_MODE").unwrap_or("1")
  return ok(none) if switch == "0"
  return error("FINN_CODE_MODE must be 0 or 1, not #{switch.inspect}") if switch != "1"

  binary = set(read, "FINN_MONTY")
  if binary.none?
    case platform.call()
      ok(found) if Monty.wheel(found).ok? -> nil
      _ -> return ok(none)
    end
  end

  worker = remembered(-> { worker_command(binary, read) }, FAILED_FETCH_MS, &Time.monotonic_ms)
  ok(some(CodeMode.Settings(worker: worker, limits: Monty.Limits())))
end

## `worker`, whose failure is given again for `keep_ms` (by the clock `now_ms`) without trying again: a script cannot
## start a new download on each call.
def remembered(worker: Fn[Result[List[String]]], keep_ms: Int, now_ms: Fn[Int]) -> Fn[Result[List[String]]]
  failed: ATS[String, String] = ATS.new()
  -> { worker_or_failure(worker, keep_ms, now_ms, failed) }
end

def worker_or_failure(
  worker: Fn[Result[List[String]]],
  keep_ms: Int,
  now_ms: Fn[Int],
  failed: ATS[String, String],
) -> Result[List[String]]
  case failed.get("until")
    ok(until) if now_ms.call() < until.to_i.unwrap_or(0) ->
      return error(failed.get("message").unwrap_or(""), kind: failed.get("kind").unwrap_or(""))
    _ -> nil
  end

  case worker.call()
    ok(words) -> ok(words)
    error(e) ->
      failed.put("message", e.message)
      failed.put("kind", e.kind)
      failed.put("until", (now_ms.call() + keep_ms).to_s)
      error(e.message, kind: e.kind)
  end
end

def worker_command(binary: Optional[String], read: Fn[String, Result[String]]) -> Result[List[String]]
  for path in option_list(binary)
    return ok(Monty.command(path))
  end

  case fetched_worker(read)
    ok(command) -> ok(command)
    error(e) -> error("#{e.message}; #{NO_CODE_MODE}", kind: e.kind)
  end
end

def fetched_worker(read: Fn[String, Result[String]]) -> Result[List[String]]
  cache = try cache_dir(read)
  wheel = try Monty.wheel(try Monty.platform())
  ok(Monty.command(try Monty.binary(cache, wheel)))
end

def state_dir(read: Fn[String, Result[String]]) -> Result[String]
  folder(read, STATE_DIR_ENV, "XDG_STATE_HOME", "state")
end

def data_dir(read: Fn[String, Result[String]]) -> Result[String] = folder(read, DATA_DIR_ENV, "XDG_DATA_HOME", "share")

private

struct FilesFile
  files: Optional[FilesKey] = none
end

struct FilesKey
  command: List[String]
end

def local_url(fallback: String, env_url: Optional[String], urls: Map[String, String]) -> String
  env_url.unwrap_or(urls.get(Providers.LOCAL).unwrap_or(fallback))
end

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

# What Finn read before its rename and does not read now: an error that says where to move it, so its deny rules and
# MCP servers are not lost without a word; the stored keys, which hold no rule, only warn.
def left_behind(read: Fn[String, Result[String]]) -> Result[List[String]]
  given = ->(name: String) { not read.call(name).unwrap_or("").empty? }
  for name in ["FINN_CONFIG", "FINN_MCP_CONFIG"]
    old = "#{OLD_PREFIX}#{name.slice(PREFIX.length, name.length - PREFIX.length)}"
    return error("#{old} is not read any more: set #{name} in its place") if given.call(old) and not given.call(name)
  end

  base = read.call("XDG_CONFIG_HOME").unwrap_or("")
  if base.empty?
    home = read.call("HOME").unwrap_or("")
    return ok([]) if home.empty?

    base = "#{home}/.config"
  end

  left = ->(file: String) { File.stat("#{base}/agc-agent/#{file}").ok? and not File.stat("#{base}/finn/#{file}").ok? }
  moving = ->(file: String) { "#{base}/agc-agent/#{file} is not read any more: move it to #{base}/finn/#{file}" }
  return error(moving.call("config.json")) if not given.call("FINN_CONFIG") and left.call("config.json")

  ok(["auth.json"].select { |file| left.call(file) }.map { |file| moving.call(file) })
end

# The pages of `docs/content` in the install `FINN_HOME` names (`bin/finn` sets it); none without it.
def docs_folder(read: Fn[String, Result[String]]) -> String
  case set(read, "FINN_HOME")
    some(home) if home != "" -> "#{home}/docs/content"
    _ -> ""
  end
end

def set(read: Fn[String, Result[String]], name: String) -> Optional[String]
  set_name(read, name).map { |each| read.call(each).unwrap_or("") }
end

# Which of `name` and its old name is set, in that order.
def set_name(read: Fn[String, Result[String]], name: String) -> Optional[String]
  names = [name]
  if name.start_with?(PREFIX)
    names = [name, "#{OLD_PREFIX}#{name.slice(PREFIX.length, name.length - PREFIX.length)}"]
  end

  for each in names
    return some(each) if read.call(each).unwrap_or("") != ""
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

def context_window(read: Fn[String, Result[String]]) -> Result[Optional[Int]] = tokens_of(read, "FINN_CONTEXT_WINDOW")

def tokens_of(read: Fn[String, Result[String]], name: String) -> Result[Optional[Int]]
  for text in option_list(set(read, name))
    case text.to_i
      ok(tokens) if tokens > 0 -> return ok(some(tokens))
      _ -> return error("#{name} must be a number of tokens over 0, not #{text.inspect}")
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
