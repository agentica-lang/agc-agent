## The `openai_chat` provider: `POST BASE/chat/completions` with `stream: true`, as llama.cpp's `llama-server`,
## Fireworks, OpenRouter and OpenAI serve it.

import Api from "api"
import Http from "http"
import Wire from "openai_chat_wire"

## The provider for an API at `base_url` (such as `http://127.0.0.1:8080/v1`). An empty `api_key` sends no
## `Authorization` header. A request for a model whose name starts with one of `reasoning_back` sends the thinking of
## each assistant message back as `reasoning_content` (what DeepSeek's models ask for).
def openai_chat(
  base_url: String,
  api_key: String = "",
  options: Http.Options = Http.Options(),
  reasoning_back: List[String] = [],
) -> Api.Provider
  wire = Http.Wire(
    path: "/chat/completions",
    headers: &Http.bearer,
    body: ->(request) { Wire.request_body_with(request, reasoning_back.any? { |p| request.model.start_with?(p) }) },
    begin: &Wire.new_turn,
    take: &Wire.take,
    ended: &Wire.ended?,
    finish: &Wire.finish,
  )

  Http.provider("openai_chat", Http.Config(base_url: base_url.strip, api_key: api_key, options: options), wire)
end
