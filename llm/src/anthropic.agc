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
## The most models one page of `GET /models` lists.
MODELS_PAGE = 1000

## The provider for an API at `base_url`. An empty `api_key` sends no `x-api-key` header. `temperature` and `seed`
## are not sent, and `ToolChoice.Required` is refused with `llm.unsupported`.
def anthropic(base_url: String = URL, api_key: String = "", options: Http.Options = Http.Options()) -> Api.Provider
  wire = Http.Wire(
    path: "/messages",
    headers: &headers,
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

def headers(api_key: String) -> List[HTTP.Header]
  version = HTTP.Header(name: "anthropic-version", value: API_VERSION)
  return [version] if api_key.empty?

  [version, HTTP.Header(name: "x-api-key", value: api_key)]
end
