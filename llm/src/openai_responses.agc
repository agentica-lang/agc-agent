## The `openai_responses` provider: `POST BASE/responses` with `stream: true`, the OpenAI Responses format, as OpenAI,
## llama.cpp's `llama-server` and Fireworks serve it. Codex speaks it too, with its own login.

import Api from "api"
import Http from "openai_http"
import Wire from "openai_responses_wire"

## The provider for an API at `base_url` (such as `https://api.openai.com/v1`). An empty `api_key` sends no
## `Authorization` header. Fields such as `store: false` and `include: ["reasoning.encrypted_content"]` go in
## `Request.extra`.
def openai_responses(base_url: String, api_key: String = "", options: Http.Options = Http.Options()) -> Api.Provider
  wire = Http.Wire(
    path: "/responses",
    body: &Wire.request_body,
    begin: &Wire.new_turn,
    take: &Wire.take,
    ended: &Wire.ended?,
    finish: &Wire.finish,
  )

  Http.provider("openai_responses", Http.Config(base_url: base_url.strip, api_key: api_key, options: options), wire)
end
