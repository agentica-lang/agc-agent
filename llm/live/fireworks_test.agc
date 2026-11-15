## A real call to Fireworks, which costs money: only `make live-fireworks`, with the owner's yes, never in CI. It reads
## `FIREWORKS_API_KEY` and `FIREWORKS_MODEL`, and never prints the key.

import LLM from "../llm"

BASE_URL = "https://api.fireworks.ai/inference/v1"

def test_fireworks_streams_text() -> Result[Void]
  key = try System.env("FIREWORKS_API_KEY")
  model = try System.env("FIREWORKS_MODEL")
  message = LLM.Message(role: LLM.Role.User, content: [LLM.Block.Text(LLM.TextPart(text: "Say hello in one word."))])
  stream = try LLM.stream(
    LLM.openai_chat(BASE_URL, key),
    LLM.Request(model: model, messages: [message], max_tokens: 64),
  )

  response = try LLM.response(stream)
  try Test.assert(not response.message.content.empty?, "no content")
  Test.assert(response.usage.output > 0, "no output tokens")
end
