## The options of `serve`, from the environment: `FINN_STATE_DIR` (else `$XDG_STATE_HOME/finn`, else
## `~/.local/state/finn`), `FINN_DATA_DIR` for the sessions (else `$XDG_DATA_HOME/finn`, else
## `~/.local/share/finn`), and the model API: `FINN_API` (`openai`, chat completions, by default, or
## `openai_responses`), `FINN_BASE_URL` (a local llama-server by default), `FINN_API_KEY` and
## `FINN_MODEL`; `FINN_CONTEXT_WINDOW` and `FINN_COMPACT_MODEL` for compaction. `FINN_CODE_MODE=1` adds code mode,
## whose Monty worker is `FINN_MONTY` (a trusted Monty 1.6.0 binary: its hash is not checked), else the pinned one
## fetched on first use into `$XDG_CACHE_HOME/finn` (else `~/.cache/finn`, which must be private to the user). The
## names of before Finn still work: `AGC_AGENT_` in place of `FINN_`, and an `agc-agent` folder while no `finn` folder
## is there.
##
## The `anthropic` API is at `ANTHROPIC_BASE_URL` (else Anthropic's), with `ANTHROPIC_API_KEY`, else
## `ANTHROPIC_AUTH_TOKEN`, else the token that `ant auth print-credentials --access-token` prints: at start when
## `FINN_API` is `anthropic`, else at a session's first call, and again after a 401. Its default model is Claude Opus
## 5.5. A credential is never logged.

import LLM from "pkg/llm/llm"
import Monty from "pkg/monty/monty"
import CodeMode from "code_mode"
import Server from "server"
import Tools from "tools"

STATE_DIR_ENV = "FINN_STATE_DIR"
DATA_DIR_ENV = "FINN_DATA_DIR"
PREFIX = "FINN_"
OLD_PREFIX = "AGC_AGENT_"
DEFAULT_BASE_URL = "http://127.0.0.1:8080/v1"
DEFAULT_MODEL = Server.DEFAULT_MODEL
## The names `FINN_API` takes: OpenAI chat completions, the OpenAI Responses format, and Anthropic Messages.
APIS = ["openai", "openai_responses", "anthropic"]
ANT_MS = 15000

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

def from_env(read: Fn[String, Result[String]]) -> Result[Server.Options] = from_env_with(read, &ant_token)

## `ant` gives the OAuth token of `ant auth login` when no variable has a credential and `FINN_API` is `anthropic`.
def from_env_with(read: Fn[String, Result[String]], ant: Fn[Result[String]]) -> Result[Server.Options]
  base_url = set(read, "FINN_BASE_URL").unwrap_or(DEFAULT_BASE_URL)
  api_key = set(read, "FINN_API_KEY").unwrap_or("")
  api = set(read, "FINN_API").unwrap_or(APIS[0])
  return error("FINN_API must be one of #{APIS.join(", ")}, not #{api.inspect}") if not APIS.include?(api)

  access = try anthropic_access(read, api == "anthropic", ant)
  model = DEFAULT_MODEL
  if api == "anthropic"
    model = LLM.ANTHROPIC_MODEL
  end

  ok(
    Server.Options(
      state_dir: try state_dir(read),
      data_dir: try data_dir(read),
      apis: apis(base_url, api_key, LLM.Options(), access),
      api: api,
      model: set(read, "FINN_MODEL").unwrap_or(model),
      env: read,
      rules: Tools.Rules(allow: [], deny: []),
      context_window: try context_window(read),
      compact_model: set(read, "FINN_COMPACT_MODEL").unwrap_or(""),
      props_url: props_url(base_url),
      api_key: api_key,
      code_mode: try code_mode(read),
    ),
  )
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
) -> Map[String, Server.ModelApi]
  stateless = {"store": JSON.from(false), "include": JSON.from(["reasoning.encrypted_content"])}
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
    "openai": Server.ModelApi(provider: LLM.openai_chat(base_url, api_key, options)),
    "openai_responses": Server.ModelApi(provider: LLM.openai_responses(base_url, api_key, options), extra: stateless),
    "anthropic": Server.ModelApi(
      provider: claude,
      model: LLM.ANTHROPIC_MODEL,
      cache: true,
      local: false,
      refresh: refresh,
    ),
  }
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

def anthropic_access(
  read: Fn[String, Result[String]],
  default: Bool,
  ant: Fn[Result[String]],
) -> Result[AnthropicAccess]
  url = read.call("ANTHROPIC_BASE_URL").unwrap_or("")
  if url == ""
    url = LLM.ANTHROPIC_URL
  end

  key = read.call("ANTHROPIC_API_KEY").unwrap_or("")
  return ok(AnthropicAccess(url: url, api_key: key, inherit: false)) if key != ""

  token = read.call("ANTHROPIC_AUTH_TOKEN").unwrap_or("")
  return ok(AnthropicAccess(url: url, auth_token: token, inherit: false)) if token != ""
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
