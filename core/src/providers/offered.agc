## The providers a server offers from its environment: `local` (the OpenAI APIs at `FINN_BASE_URL`), `anthropic` (its
## access: a key, a token or `ant`), then the presets and the user's providers that have a key (`Providers`).

import LLM from "pkg/llm/llm"
import Providers from "providers"

ANT_MS = 15000

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

## Every provider of a server whose env is `server`, with the keys a login stored: the built-in ones, then those of
## `customs` that have a key; a variable wins over a stored key.
def all_providers(
  server: Server,
  customs: List[Providers.Custom],
  keys: Map[String, String],
  access: AnthropicAccess,
  options: LLM.Options = LLM.Options(),
) -> Result[Map[String, Providers.Provider]]
  providers = builtin(apis(server.base_url, server.api_key, options, access), server.api)
  offered = Providers.offered(customs, server.read, options, keys)
  for name in offered.keys
    providers = providers.put(name, offered[name])
  end

  ok(providers)
end

## The access of `anthropic` with the stored `keys`: the one of the start while its stored key is the same, else one
## that fetches the token of `ant` only after a 401, so building the providers calls nothing.
def access_for(
  server: Server,
  keys: Map[String, String],
  at_start_key: String,
  at_start: AnthropicAccess,
) -> AnthropicAccess
  key = keys.get(Providers.ANTHROPIC).unwrap_or("")
  return at_start if key == at_start_key

  anthropic_access(server.read, false, server.ant, key).unwrap_or(at_start)
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
  for custom in customs.select { |c| not c.key_env.empty? }
    out = out.select { |e| e.name != custom.name }.push(custom)
  end

  out
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
  url = access.url
  refresh = access.ant.map { |ant| refreshed(url, options, ant) }

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

## The built-in providers of a server whose own model APIs are `apis`: `local` has the OpenAI ones,
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

private

# A new Anthropic provider with a fresh token of `ant login`.
def refreshed(url: String, options: LLM.Options, ant: Fn[Result[String]]) -> Fn[Result[LLM.Provider]]
  -> { ok(LLM.anthropic(url, "", options, try ant.call())) }
end
