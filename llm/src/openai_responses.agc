## The `openai_responses` provider: `POST BASE/responses` with `stream: true`, the OpenAI Responses format, as OpenAI,
## llama.cpp's `llama-server` and Fireworks serve it. Codex speaks it too, with its own login.

import HTTP from "std/http"
import Api from "api"
import Http from "http"
import Types from "types"
import Wire from "openai_responses_wire"

## What Codex is told of the client that calls it: the `originator` header, and the version its model list is for.
CODEX_ORIGINATOR = "llm-async-codex"
CODEX_CLIENT_VERSION = "0.160.0"

## The provider for an API at `base_url` (such as `https://api.openai.com/v1`). An empty `api_key` sends no
## `Authorization` header. Fields such as `store: false` and `include: ["reasoning.encrypted_content"]` go in
## `Request.extra`. A reasoning item goes back in the next request when it has `encrypted_content` or the API keeps
## the items (no `store: false`). Otherwise it is dropped, with the item ids of the other items of its turn.
def openai_responses(base_url: String, api_key: String = "", options: Http.Options = Http.Options()) -> Api.Provider
  wire = Http.Wire(
    path: "/responses",
    headers: &Http.bearer,
    body: &Wire.request_body,
    begin: &Wire.new_turn,
    take: &Wire.take,
    ended: &Wire.ended?,
    finish: &Wire.finish,
  )

  Http.provider("openai_responses", Http.Config(base_url: base_url.strip, api_key: api_key, options: options), wire)
end

## The provider of a ChatGPT subscription: the Responses API of Codex at `base_url` (such as
## `https://chatgpt.com/backend-api/codex`) with the access token of a ChatGPT login and its account. Codex takes no
## `max_output_tokens`, and lists its models as `{"models": [{"slug", "context_window"}]}`.
def codex(base_url: String, token: String, account_id: String, options: Http.Options = Http.Options()) -> Api.Provider
  wire = Http.Wire(
    path: "/responses",
    headers: ->(key: String) { Http.bearer(key) + codex_headers(account_id) },
    body: &Wire.codex_body,
    begin: &Wire.new_turn,
    take: &Wire.take,
    ended: &Wire.ended?,
    finish: &Wire.finish,
    models_path: "/models?client_version=#{CODEX_CLIENT_VERSION}",
    models_of: some(&codex_models),
  )

  Http.provider("openai_responses", Http.Config(base_url: base_url.strip, api_key: token, options: options), wire)
end

private

struct CodexModels
  models: List[CodexModel]
end

struct CodexModel
  slug: String
  context_window: Optional[Int]
end

def codex_headers(account_id: String) -> List[HTTP.Header]
  origin = [HTTP.Header(name: "originator", value: CODEX_ORIGINATOR)]
  return origin if account_id.empty?

  origin.push(HTTP.Header(name: "ChatGPT-Account-Id", value: account_id))
end

def codex_models(body: String) -> Result[List[Types.Model]]
  case JSON.decode(body, CodexModels)
    ok(list) -> ok(list.models.map { |m| Types.Model(id: m.slug, context: m.context_window) })
    error(e) -> error("llm: bad JSON from the API: #{e.message}", kind: "llm.protocol", cause: e)
  end
end
