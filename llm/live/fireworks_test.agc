## Real calls to Fireworks, which cost money: only `make live-fireworks`, with the owner's yes, never in CI. They read
## `FIREWORKS_API_KEY` and `FIREWORKS_MODEL`, and never print the key.

import LLM from "../llm"

BASE_URL = "https://api.fireworks.ai/inference/v1"

def test_fireworks_chat_streams_text() -> Result[Void]
  key = try System.env("FIREWORKS_API_KEY")
  check(LLM.openai_chat(BASE_URL, key))
end

def test_fireworks_responses_streams_text() -> Result[Void]
  key = try System.env("FIREWORKS_API_KEY")
  check(LLM.openai_responses(BASE_URL, key))
end

private

def check(provider: LLM.Provider) -> Result[Void]
  model = try System.env("FIREWORKS_MODEL")
  message = LLM.Message(role: LLM.Role.User, content: [LLM.Block.Text(LLM.TextPart(text: "Say hello in one word."))])
  response = try LLM.response(
    try LLM.stream(provider, LLM.Request(model: model, messages: [message], max_tokens: some(64))),
  )

  try Test.assert(not response.message.content.empty?, "no content")
  Test.assert(response.usage.output > 0, "no output tokens")
end
