## The model providers a server offers, by name. Built in: `local` (the OpenAI APIs at `FINN_BASE_URL` with
## `FINN_API_KEY`, a llama-server by default), `anthropic` (`ANTHROPIC_*`), and the presets below, each offered only
## when its key variable is set. The user's config file adds or replaces providers under `providers`:
## `[{"name", "api", "base_url", "key_env", "models"}]`, where `api` is `openai` (the default) or `openai_responses`,
## and a provider with a `key_env` is offered only when that variable is set, or when a login stored its key
## (`Auth`); the variable wins.

import LLM from "pkg/llm/llm"

LOCAL = "local"
ANTHROPIC = "anthropic"

## A model API a session can use: its provider, and the fields every request to it carries.
struct ModelApi
  provider: LLM.Provider
  extra: Map[String, JSON.Value] = {}
  ## The model of a session that picks this API without a model, when it is not the server's API; empty for the
  ## server's model.
  model: String = ""
  ## Ask for the prompt cache (Anthropic).
  cache: Bool = false
  ## A local server whose `/props` may give the window (llama-server), and which may get `FINN_API_KEY` there.
  local: Bool = true
  ## A provider with a fresh token, after a 401 (the token of `ant`).
  refresh: Optional[Fn[Result[LLM.Provider]]] = none
end

## A provider: its model APIs by name, and `api`, the one of a session that names none.
struct Provider
  apis: Map[String, ModelApi]
  api: String
  ## Its id in the models.dev catalog; empty for the server's (`FINN_MODELS_PROVIDER`, else by the API).
  catalog: String = ""
  ## The models it names in the config file, for a client to offer.
  models: List[String] = []
end

## A provider of the config file.
struct Custom
  name: String
  api: String = "openai"
  base_url: String
  key_env: String = ""
  models: List[String] = []
end

## A provider a login will offer, with no flow yet (a subscription): its name and what it is.
struct Coming
  name: String
  label: String
end

## The presets that need a key: name, API, base URL, key variable and models.dev id.
def presets() -> List[Custom]
  [
    Custom(name: "openai", api: "openai_responses", base_url: "https://api.openai.com/v1", key_env: "OPENAI_API_KEY"),
    Custom(name: "fireworks", base_url: "https://api.fireworks.ai/inference/v1", key_env: "FIREWORKS_API_KEY"),
    Custom(name: "openrouter", base_url: "https://openrouter.ai/api/v1", key_env: "OPENROUTER_API_KEY"),
    Custom(name: "groq", base_url: "https://api.groq.com/openai/v1", key_env: "GROQ_API_KEY"),
    Custom(name: "deepseek", base_url: "https://api.deepseek.com/v1", key_env: "DEEPSEEK_API_KEY"),
  ]
end

def coming() -> List[Coming]
  [Coming(name: "claude", label: "Claude Pro/Max"), Coming(name: "chatgpt", label: "ChatGPT and Codex")]
end

## The custom providers of the config file at `path`; none when it has no `providers`.
def from_file(path: String) -> Result[List[Custom]]
  text = try File.read_text(path)
  case JSON.decode(text, ProvidersFile)
    ok(file) -> checked(path, file.providers.unwrap_or([]).map(&custom_of))
    error(e) -> error("#{path}: #{e.message}")
  end
end

## The providers of `customs` whose key is set or stored (`stored`, by provider) or that need none, with their model
## APIs. `options` are those of every client.
def offered(
  customs: List[Custom],
  read: Fn[String, Result[String]],
  options: LLM.Options,
  stored: Map[String, String] = {},
) -> Map[String, Provider]
  out: Map[String, Provider] = {}
  for custom in customs
    key = ""
    if not custom.key_env.empty?
      key = read.call(custom.key_env).unwrap_or("")
      if key.empty?
        key = stored.get(custom.name).unwrap_or("")
      end
    end

    if custom.key_env.empty? or not key.empty?
      out = out.put(custom.name, provider_of(custom, key, options))
    end
  end

  out
end

## The key variable of each provider that has one, offered or not.
def key_envs(customs: List[Custom]) -> Map[String, String]
  out: Map[String, String] = {}
  for custom in (customs.select { |c| not c.key_env.empty? })
    out = out.put(custom.name, custom.key_env)
  end

  out
end

## A warning for each provider whose key variable is the key of another one: that key would go to its URL too.
def shared_keys(customs: List[Custom]) -> List[String]
  owners = key_envs(customs)
  names = owners.keys.sort
  warnings: List[String] = []
  for at in 0...names.size
    name = names[at]
    for other in (names.take(at).select { |n| owners[n] == owners[name] })
      warnings = warnings.push("providers #{other} and #{name} both take #{owners[name]}")
    end
  end

  warnings
end

## The fields of every Responses request: the API keeps nothing, and the reasoning comes back encrypted.
def stateless() -> Map[String, JSON.Value]
  {"store": JSON.from(false), "include": JSON.from(["reasoning.encrypted_content"])}
end

private

## The catalog id of a preset, where it differs from its name.
CATALOG = {"fireworks": "fireworks-ai"}

# Every field but the name and the URL may be left out (Optional: a default does not make a field optional in JSON).
struct ProvidersFile
  providers: Optional[List[CustomWire]] = none
end

struct CustomWire
  name: String
  api: Optional[String] = none
  base_url: String
  key_env: Optional[String] = none
  models: Optional[List[String]] = none
end

def custom_of(wire: CustomWire) -> Custom
  Custom(
    name: wire.name,
    api: wire.api.unwrap_or("openai"),
    base_url: wire.base_url,
    key_env: wire.key_env.unwrap_or(""),
    models: wire.models.unwrap_or([]),
  )
end

def checked(path: String, customs: List[Custom]) -> Result[List[Custom]]
  for custom in customs
    return error("#{path}: a provider has no name") if custom.name.empty?
    return error("#{path}: provider #{custom.name.inspect}: a name cannot have a /") if custom.name.include?("/")
    if not ["openai", "openai_responses"].include?(custom.api)
      return error(
        "#{path}: provider #{custom.name}: api must be openai or openai_responses, not #{custom.api.inspect}",
      )
    end

    return error("#{path}: provider #{custom.name} has no base_url") if custom.base_url.empty?
  end

  ok(customs)
end

def provider_of(custom: Custom, key: String, options: LLM.Options) -> Provider
  chat = ModelApi(provider: LLM.openai_chat(custom.base_url, key, options), local: false)
  responses = ModelApi(provider: LLM.openai_responses(custom.base_url, key, options), extra: stateless(), local: false)
  apis = {"openai": chat}
  if custom.api == "openai_responses"
    apis = {"openai_responses": responses, "openai": chat}
  end

  catalog = custom.name
  if CATALOG.has_key?(custom.name)
    catalog = CATALOG[custom.name]
  end

  Provider(apis: apis, api: custom.api, catalog: catalog, models: custom.models)
end
