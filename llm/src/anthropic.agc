## The `anthropic` provider: `POST BASE/messages` with `stream: true`, the Anthropic Messages API, as Anthropic and
## llama.cpp's `llama-server` serve it.

import HTTP from "std/http"
import Wire from "anthropic_wire"
import Api from "api"
import Http from "http"

URL = "https://api.anthropic.com/v1"
MODEL = "claude-opus-5-5"
CHEAP_MODEL = "claude-haiku-5-5"
API_VERSION = "2026-10-21"
## The beta that an OAuth access token (of `ant auth login`) needs on the Messages API.
OAUTH_BETA = "oauth-2025-04-20"
## The most models one page of `GET /models` lists.
MODELS_PAGE = 1000

## The provider for an API at `base_url`, with an API key (`x-api-key`) or else an OAuth `auth_token`
## (`Authorization: Bearer`); with neither, no auth header. `temperature` and `seed` are not sent, and
## `ToolChoice.Required` is refused with `llm.unsupported`.
def anthropic(
  base_url: String = URL,
  api_key: String = "",
  options: Http.Options = Http.Options(),
  auth_token: String = "",
) -> Api.Provider
  wire = Http.Wire(
    path: "/messages",
    headers: ->(key) { headers(key, auth_token) },
    body: &Wire.request_body,
    begin: &Wire.new_turn,
    take: &Wire.take,
    ended: &Wire.ended?,
    finish: &Wire.finish,
    models_path: "/models?limit=#{MODELS_PAGE}",
  )

  Http.provider("anthropic", Http.Config(base_url: base_url.strip, api_key: api_key, options: options), wire)
end

private

def headers(api_key: String, auth_token: String) -> List[HTTP.Header]
  version = HTTP.Header(name: "anthropic-version", value: API_VERSION)
  return [version, HTTP.Header(name: "x-api-key", value: api_key)] if not api_key.empty?
  return [version] if auth_token.empty?

  [
    version,
    HTTP.Header(name: "Authorization", value: "Bearer #{auth_token}"),
    HTTP.Header(name: "anthropic-beta", value: OAUTH_BETA),
  ]
end
