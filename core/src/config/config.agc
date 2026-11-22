## The options of `serve`, from the environment: `FINN_STATE_DIR` (else `$XDG_STATE_HOME/finn`, else
## `~/.local/state/finn`), `FINN_DATA_DIR` for the sessions (else `$XDG_DATA_HOME/finn`, else `~/.local/share/finn`),
## and the model API: `FINN_API` (`openai`, chat completions, by default, or `openai_responses`), `FINN_BASE_URL` (a
## local llama-server by default), `FINN_API_KEY` and `FINN_MODEL`; `FINN_MAX_TOKENS` (the most tokens of a reply; by
## default the model's own limit in the catalog, else the API's); `FINN_CONTEXT_WINDOW` and `FINN_COMPACT_MODEL` for
## compaction; `FINN_DRAIN_MS` (how long a stop waits for the turns, 60000); `FINN_MODELS_URL` (the models.dev catalog
## of prices and windows, `off` for none) and `FINN_MODELS_PROVIDER` (the provider of the model there); `FINN_HTTP2`
## (`0` keeps HTTP/1.1 to the providers).
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
import Protocol from "pkg/protocol/protocol"
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
import Sandbox from "../tools/sandbox"
import Tools from "../tools/tools"

export Providers.ModelApi
export Providers.Provider

STATE_DIR_ENV = "FINN_STATE_DIR"
DATA_DIR_ENV = "FINN_DATA_DIR"
## The provider and model last picked, in the state folder.
CHOICE_FILE = "choice.json"
## The key of the settings of the config file in the table that `reload` changes.
LIVE_KEY = "settings"
## The variables that name the provider: one of them set wins over the last choice.
PROVIDER_PINS = ["FINN_BASE_URL", "FINN_PROVIDER", "FINN_API"]
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
  skill_user: List[String] = []
  skill_project: List[String] = []
  ## The folder of Finn's own documentation pages, which the built-in skill `finn` reads in place; empty for none.
  docs: String = ""
  ## The folders whose sessions load the skills of their own folder: a project's skills are its instructions.
  trusted: List[String] = []
  ## The program and arguments that list the files for `@`, from the user's config only; empty for the built-in walk.
  files_command: List[String] = []
  ## The file tools of new sessions reach only the session folder (`FINN_CONFINE_FILES=1`, `confine_files` of the user's
  ## config file).
  confine_files: Bool = false
  ## The full screen turns the mouse on: `"mouse": false` of the user's config file turns it off.
  mouse: Bool = true
  ## How the full screen copies a selection: `"clipboard"` and `"clipboard_command"` of the user's config file.
  clipboard: String = "auto"
  clipboard_command: List[String] = []
  ## The `keys` of the user's config file as written, an action and its key each: the full screen checks them.
  keys: Map[String, String] = {}
  ## The `status_line` of the user's config file: the segments of the full screen's status row, none for its default.
  status_line: Optional[Protocol.StatusLine] = none
  ## The provider is set (`FINN_PROVIDER`, `FINN_API` or `FINN_BASE_URL`) and `FINN_MODEL` is: they win over the provider and
  ## model last picked.
  provider_pinned: Bool = false
  model_pinned: Bool = false
  ## The model of `picked` is none the user named: the provider has no model of its own, so the first of its list.
  model_unset: Bool = false
  ## The settings of the config file that a reload changes while the server runs.
  live: Optional[Live] = none
  ## What else a reload reads again (the MCP servers), each giving what it did, empty for nothing.
  reloads: List[Fn[Result[String]]] = []
  ## What the end of the server stops after its sessions (the MCP servers, which run in their own process groups).
  stops: List[Fn[Void]] = []
  ## How long a reload waits for another one that runs (tests shorten it).
  reload_wait_ms: Int = 150_000
  ## The MCP servers for `GET /v1/mcp`; none without any.
  mcp: Optional[McpControl] = none
end

## What the server asks of its MCP servers: the state of those of the user and of the project servers of a folder, and a
## new start of one of them by name (the folder is the one of the session whose project servers are meant).
struct McpControl
  status: Fn[String, Result[List[Protocol.McpServer]]]
  reconnect: Fn[String, String, Result[Protocol.McpServer]]
  ## The last lines of the log of a server: the folder, the name and how many.
  log: Fn[String, String, Int, Result[List[String]]]
end

## `provider` is `auto`, `osc52`, `tmux` or `command`; `command` is the program that `command` runs.
struct Clipboard
  provider: String = "auto"
  command: List[String] = []
end

## What the user's config file sets that `reload` reads again: the rules and the asking, the program that lists the
## files, the mouse, and the providers it adds.
struct Settings
  approvals: Approval.Rules
  ## How many rules of the user's file and project defaults (the denies for Finn's own files are not counted).
  rules: Int
  asking: Bool
  files_command: List[String]
  mouse: Bool
  clipboard: Clipboard
  keys: Map[String, String]
  status_line: Optional[Protocol.StatusLine]
  skill_user: List[String] = []
  skill_project: List[String] = []
  ## What in the file was not taken and does not stop the server: it keeps its default.
  notes: List[String]
  customs: List[Providers.Custom]
end

## The settings now, and how to build the providers for a list of customs.
struct Live
  cell: ATS[String, Settings]
  providers: Fn[List[Providers.Custom], Logins.Replacement]
end

## What a reload did to the config.
struct Reloaded
  ## `reloaded`, `unchanged`, or `kept` with the reason the file was not taken.
  config: String
  changed: Bool = false
  ## What now applies: the rules of the user and whether calls that no rule allows ask.
  rules: Int = 0
  asking: Bool = false
end

def from_env(read: Fn[String, Result[String]], llm: LLM.Options = LLM.Options()) -> Result[Options]
  from_env_with(read, &Offered.ant_token, llm)
end

## `ant` gives the OAuth token of `ant auth login` when no variable has a credential and `FINN_API` is `anthropic`.
def from_env_with(
  read: Fn[String, Result[String]],
  ant: Fn[Result[String]],
  llm: LLM.Options = LLM.Options(),
) -> Result[Options]
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

  first = try settings_of(read)
  customs = first.customs
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
  # `FINN_HTTP2=0` keeps HTTP/1.1 to every provider.
  llm = llm.with(http2: http2_on(read))
  # `ant` runs here only: a login or a logout later builds the providers without it.
  at_start = try Offered.anthropic_access(read, api == "anthropic", ant, claude_key)
  rebuilding = ->(more: List[Providers.Custom]) {
    ->(keys: Map[String, String], urls: Map[String, String]) {
      current = server.with(base_url: local_url(base_url, env_url, urls))
      access = Offered.access_for(current, keys, claude_key, at_start)
      built = Offered.all_providers(current, more, keys, access, llm)
      Chatgpt.added(built, chatgpt, llm)
    }
  }

  rebuild = rebuilding.call(customs)
  providers = try rebuild.call(stored.keys, stored.urls)
  choice_path = "#{states}/#{CHOICE_FILE}"
  choice = Logins.load_choice(choice_path)
  stale: List[String] = []
  for found in option_list(choice)
    listed = (
      providers.has_key?(found.provider) and
      not found.model.empty? and
      not providers[found.provider].models.empty?
    )

    if listed and set(read, "FINN_MODELS_URL").unwrap_or(Catalog.URL) == "off"
      if not providers[found.provider].models.include?(found.model)
        stale = stale.push(
          "the model of the last choice, #{found.model}, is not in the models of #{found.provider}: new sessions still use it",
        )
      end
    end

    if not providers.has_key?(found.provider)
      stale = stale.push(
        "the provider of the last choice, #{found.provider}, is not offered (is its key set?): new sessions use the default",
      )

      choice = none
    end
  end

  anthropic_url = set(read, "ANTHROPIC_BASE_URL").unwrap_or(LLM.ANTHROPIC_URL)
  live = live_with(
    first,
    ->(more: List[Providers.Custom]) {
      Logins.Replacement(entries: Offered.login_entries(more, anthropic_url), rebuild: rebuilding.call(more))
    },
  )

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
    chosen: provider_pinned?(read),
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

  user_file = try settings(read)
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
        moved +
        first.notes
      ),
      login: some(login),
      model: set(read, "FINN_MODEL").unwrap_or(model),
      env: read,
      approvals: some(first.approvals),
      asking: first.asking,
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
      skill_user: first.skill_user,
      skill_project: first.skill_project,
      docs: docs_folder(read),
      trusted: set(read, "FINN_TRUSTED_DIRS").unwrap_or("").split(":").select { |dir| dir != "" },
      files_command: first.files_command,
      confine_files: try confine_files(read, user_file),
      mouse: first.mouse,
      clipboard: first.clipboard.provider,
      clipboard_command: first.clipboard.command,
      keys: first.keys,
      status_line: first.status_line,
      live: some(live),
      provider_pinned: provider_pinned?(read),
      model_pinned: set(read, "FINN_MODEL").some?,
    ),
  )
end

## `options` with the providers the server offers now (a login or a logout changes them), and the `/props` of the
## base URL `local` uses now.
def now(options: Options) -> Options = lived(logged_in(options))

## The settings `first` as what a reload changes, with how to build the providers of a list of customs.
def live_with(first: Settings, providers: Fn[List[Providers.Custom], Logins.Replacement]) -> Live
  cell: ATS[String, Settings] = ATS.new()
  cell.put(LIVE_KEY, first)
  Live(cell: cell, providers: providers)
end

## The settings of the config file `read` names, as what a reload changes: a seam for the tests of the server.
def live_from(
  read: Fn[String, Result[String]],
  providers: Fn[List[Providers.Custom], Logins.Replacement],
) -> Result[Live]
  ok(live_with(try settings_of(read), providers))
end

## The settings of the last read of the config file.
def current(live: Live) -> Optional[Settings]
  case live.cell.get(LIVE_KEY)
    ok(found) -> some(found)
    error(_) -> none
  end
end

## Reads the user's config file again: the rules and the asking, the files program, the mouse and the providers it
## adds apply from the next request and the next turn. A file that does not read keeps the settings of the last
## read, with the reason.
def reload(options: Options) -> Reloaded
  for live in option_list(options.live)
    case settings_of(options.env)
      error(e) -> return stated(live, Reloaded(config: "kept: #{e.message}"))
      ok(fresh) ->
        old = live.cell.get(LIVE_KEY)
        return stated(live, Reloaded(config: "unchanged")) if old == ok(fresh)

        before = fresh.customs
        for kept in option_list(current(live))
          before = kept.customs
        end

        for holder in option_list(options.logins)
          next if before == fresh.customs

          case Logins.replace(holder, live.providers.call(fresh.customs))
            ok(_) -> nil
            error(e) -> return stated(live, Reloaded(config: "kept: #{e.message}"))
          end
        end

        live.cell.put(LIVE_KEY, fresh)
        return stated(live, Reloaded(config: "reloaded", changed: true))
    end
  end

  Reloaded(config: "unchanged")
end

## `options` with the settings the last reload took (the options of the start when there was none).
def applied(options: Options) -> Options = lived(options)

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
      if model.empty? and not found.models.empty?
        model = found.models[0]
      end
    end

    unset = model.empty?
    if unset
      model = DEFAULT_MODEL
    end

    return options.with(provider: choice.provider, model: model, model_unset: unset)
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

## `FINN_HTTP2=0` (or `off`) keeps HTTP/1.1 to every provider; by default an `https://` API is reached over HTTP/2.
def http2_on(read: Fn[String, Result[String]]) -> Bool
  case set(read, "FINN_HTTP2")
    some(value) -> not ["0", "off"].include?(value)
    none -> true
  end
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

CLIPBOARDS = ["auto", "osc52", "tmux", "command"]

# The user's config file, read once: each setting takes its own key, so a bad value stops only its own setting.
struct UserFile
  path: String
  root: Optional[JSON.Value] = none
end

def settings(read: Fn[String, Result[String]]) -> Result[UserFile]
  for path in option_list(Permissions.config_path(read))
    case JSON.parse(try File.read_text(path))
      ok(root) -> return ok(UserFile(path: path, root: some(root)))
      error(e) -> return error("#{path}: #{e.message}")
    end
  end

  ok(UserFile(path: ""))
end

# The value of a key of the file, none when it is not there or is null.
def setting(found: UserFile, key: String) -> Optional[JSON.Value]
  for root in option_list(found.root)
    case JSON.get(root, key)
      ok(value) if not JSON.null?(value) -> return some(value)
      _ -> nil
    end
  end

  none
end

def skill_paths(found: UserFile, side: String) -> Result[List[String]]
  for skills in option_list(setting(found, "skills"))
    case JSON.node(skills)
      JSON.Node.Object(_) -> nil
      _ -> return error("#{found.path}: skills must be an object")
    end

    case JSON.get(skills, side)
      error(_) -> return ok([])
      ok(value) ->
        listed = JSON.list(value)
        return error("#{found.path}: skills.#{side} must be a list of paths") if not listed.ok?

        paths: List[String] = []
        for item in try listed
          name = JSON.string(item)
          return error("#{found.path}: skills.#{side} must be a list of paths") if not name.ok?

          path = try name
          if path.empty? or (side == "project" and (path.start_with?("/") or path.split("/").include?("..")))
            return error("#{found.path}: invalid skills.#{side} path #{path.inspect}")
          end

          paths = paths.push(path)
        end

        return ok(paths)
    end
  end

  ok([])
end

# `files.command` of the user's config file: a program and its arguments, which the file must name with a program.
def files_command(found: UserFile) -> Result[List[String]]
  for files in option_list(setting(found, "files"))
    case program(files)
      ok(command) -> return ok(command)
      error(_) -> return error("#{found.path}: files.command must name a program")
    end
  end

  ok([])
end

def program(files: JSON.Value) -> Result[List[String]] = program_of(try JSON.get(files, "command"))

# `FINN_CONFINE_FILES` (0 or 1), else `confine_files` of the user's config file, else off.
def confine_files(read: Fn[String, Result[String]], found: UserFile) -> Result[Bool]
  case set(read, "FINN_CONFINE_FILES")
    some("1") -> ok(true)
    some("0") -> ok(false)
    some(other) -> error("FINN_CONFINE_FILES must be 0 or 1, not #{other.inspect}")
    none -> flag(found, "confine_files", false)
  end
end

# `mouse` of the user's config file: `false` leaves the mouse to the terminal; no key, or no file, is on.
def mouse_setting(found: UserFile) -> Result[Bool] = flag(found, "mouse", true)

# `clipboard` and `clipboard_command` of the user's config file: one of CLIPBOARDS (`auto` when there is none) and the
# program that `command` runs. A `clipboard_command` with no `clipboard` means `command`.
def clipboard_setting(found: UserFile) -> Result[Clipboard]
  command: List[String] = []
  for value in option_list(setting(found, "clipboard_command"))
    case program_of(value)
      ok(listed) -> command = listed
      error(_) -> return error("#{found.path}: clipboard_command must name a program")
    end
  end

  provider = "auto"
  if not command.empty?
    provider = "command"
  end

  for value in option_list(setting(found, "clipboard"))
    case JSON.string(value)
      ok(named) if CLIPBOARDS.include?(named) -> provider = named
      _ -> return error("#{found.path}: clipboard must be auto, osc52, tmux or command")
    end
  end

  if provider == "command" and command.empty?
    return error("#{found.path}: clipboard \"command\" needs clipboard_command")
  end

  ok(Clipboard(provider: provider, command: command))
end

# `keys` of the user's config file: an object from the name of an action to the name of a key. The full screen checks
# the names, and keeps its default for each that it does not know.
def keys_setting(found: UserFile) -> Result[Map[String, String]]
  keys: Map[String, String] = {}
  for value in option_list(setting(found, "keys"))
    case JSON.node(value)
      JSON.Node.Object(given) ->
        for action in given.keys.sort
          case JSON.string(given[action])
            ok(key) -> keys = keys.put(action, key)
            error(_) -> return error("#{found.path}: keys: #{action.inspect} must name a key")
          end
        end

      _ -> return error("#{found.path}: keys must be an object from an action to a key")
    end
  end

  ok(keys)
end

# `status_line` of the user's config file: `{"left": [...], "right": [...]}`, the names of the segments of each side.
# The full screen skips a name it does not know. A value of another shape is an error that `settings_of` turns into a
# warning, so the default row stays.
def status_line_setting(found: UserFile) -> Result[Optional[Protocol.StatusLine]]
  for value in option_list(setting(found, "status_line"))
    case JSON.node(value)
      JSON.Node.Object(_) -> nil
      _ -> return error("#{found.path}: status_line must be an object with left and right lists of segment names")
    end

    left = try segment_names(found, value, "left")
    right = try segment_names(found, value, "right")
    return ok(some(Protocol.StatusLine(left: left, right: right)))
  end

  ok(none)
end

def segment_names(found: UserFile, value: JSON.Value, side: String) -> Result[List[String]]
  return ok([]) if not JSON.get(value, side).ok?

  names: List[String] = []
  listed = JSON.list(try JSON.get(value, side))
  return error("#{found.path}: status_line.#{side} must list segment names") if not listed.ok?

  for item in try listed
    case JSON.string(item)
      ok(name) -> names = names.push(name)
      error(_) -> return error("#{found.path}: status_line.#{side} must list segment names")
    end
  end

  ok(names)
end

def status_note(read: Result[Optional[Protocol.StatusLine]]) -> List[String]
  case read
    ok(_) -> []
    error(e) -> [e.message]
  end
end

def program_of(value: JSON.Value) -> Result[List[String]]
  command: List[String] = []
  for item in try JSON.list(value)
    command = command.push(try JSON.string(item))
  end

  return error("no program") if command.empty? or command[0] == ""

  ok(command)
end

def flag(found: UserFile, key: String, fallback: Bool) -> Result[Bool]
  for value in option_list(setting(found, key))
    case JSON.bool(value)
      ok(on) -> return ok(on)
      error(_) -> return error("#{found.path}: #{key} must be true or false")
    end
  end

  ok(fallback)
end

def provider_pinned?(read: Fn[String, Result[String]]) -> Bool = PROVIDER_PINS.any? { |name| set(read, name).some? }

def logged_in(options: Options) -> Options
  for holder in option_list(options.logins)
    case Logins.current(holder)
      ok(current) -> return picked(offered_now(options, current), current)
      error(_) -> nil
    end
  end

  options
end

def stated(live: Live, done: Reloaded) -> Reloaded
  for found in option_list(current(live))
    return done.with(rules: found.rules, asking: found.asking)
  end

  done
end

def settings_of(read: Fn[String, Result[String]]) -> Result[Settings]
  user = try Permissions.user_rules(read, try approvals_switch(read))
  file = try settings(read)
  customs = Providers.presets()
  for path in option_list(Permissions.config_path(read))
    customs = customs + try Providers.from_file(path)
  end

  folders = (
    [try state_dir(read), try data_dir(read)] +
    Auth.path(read).map { |path| [Sandbox.parent(path)] }.unwrap_or([])
  )

  status_line = status_line_setting(file)
  denies = Approval.finn_denies(folders, option_list(Permissions.config_path(read)))
  ok(
    Settings(
      approvals: Approval.Rules(all: denies + user.rules.all),
      rules: user.rules.all.size,
      asking: user.asking,
      files_command: try files_command(file),
      mouse: try mouse_setting(file),
      clipboard: try clipboard_setting(file),
      keys: try keys_setting(file),
      status_line: status_line.unwrap_or(none),
      skill_user: try skill_paths(file, "user"),
      skill_project: try skill_paths(file, "project"),
      notes: status_note(status_line),
      customs: customs,
    ),
  )
end

# The settings of the last read of the config file over the ones the options were made with.
def lived(options: Options) -> Options
  for live in option_list(options.live)
    case live.cell.get(LIVE_KEY)
      ok(found) ->
        return options.with(
          approvals: some(found.approvals),
          asking: found.asking,
          files_command: found.files_command,
          mouse: found.mouse,
          clipboard: found.clipboard.provider,
          clipboard_command: found.clipboard.command,
          keys: found.keys,
          status_line: found.status_line,
          skill_user: found.skill_user,
          skill_project: found.skill_project,
        )
      error(_) -> nil
    end
  end

  options
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
