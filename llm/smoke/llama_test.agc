import LLM from "../llm"
import Llama from "support/llama"

READ_FILE_SCHEMA = (
  "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"limit\":{\"type\":\"integer\"}}," +
  "\"required\":[\"path\"]}"
)

# Small models are not reliable: these check shapes, not words, at temperature 0 with a seed (anthropic sends
# neither). Each test runs one provider against its own server, so a slow runner has the 30 s of a test for one
# provider and not for three.
def test_a_real_server_streams_text_on_openai_chat() -> Result[Void] = text_on("openai_chat")

def test_a_real_server_streams_text_on_openai_responses() -> Result[Void] = text_on("openai_responses")

def test_a_real_server_streams_text_on_anthropic() -> Result[Void] = text_on("anthropic")

def test_a_real_server_calls_a_tool_with_json_arguments_on_openai_chat() -> Result[Void] = tool_on("openai_chat")

def test_a_real_server_calls_a_tool_with_json_arguments_on_openai_responses() -> Result[Void]
  tool_on("openai_responses")
end

def test_a_real_server_calls_a_tool_with_json_arguments_on_anthropic() -> Result[Void] = tool_on("anthropic")

private

struct Answer
  response: LLM.Response
  deltas: Int
end

def text_on(name: String) -> Result[Void]
  request = LLM.Request(
    model: "qwen",
    system: "Answer in one short sentence.",
    messages: [user("Say hello.")],
    max_tokens: some(24),
    temperature: some(0.0),
    seed: some(1),
    # Anthropic's cache breakpoints, which llama-server takes and does not use.
    cache: true,
  )

  server = try Llama.start("text-#{name}")
  answer = call(provider_named(server, name), request)
  Llama.stop(server)
  check_text(try answer)
end

def tool_on(name: String) -> Result[Void]
  tool = LLM.Tool(
    name: "read_file",
    description: "Read a file of the project.",
    input_schema: try JSON.parse(READ_FILE_SCHEMA),
  )

  request = LLM.Request(
    model: "qwen",
    messages: [user("Read the first 10 lines of README.md.")],
    tools: [tool],
    tool_choice: LLM.ToolChoice.Required,
    max_tokens: some(128),
    temperature: some(0.0),
    seed: some(1),
  )

  server = try Llama.start("tool-#{name}")
  provider = provider_named(server, name)
  round = tool_round(provider, forced(provider, request))
  Llama.stop(server)
  round
end

def provider_named(server: Llama.Server, name: String) -> LLM.Provider
  case name
    "openai_chat" -> LLM.openai_chat(server.url, "")
    "openai_responses" -> LLM.openai_responses(server.url, "")
    _ -> LLM.anthropic(server.url, "")
  end
end

def check_text(answer: Answer) -> Result[Void]
  try Test.assert(texts(answer.response).strip.length > 0, "no text")
  try Test.assert(answer.deltas > 0, "no text delta")
  try Test.assert(
    [LLM.StopReason.EndTurn, LLM.StopReason.MaxTokens].include?(answer.response.stop_reason),
    "stop reason #{answer.response.stop_reason}",
  )

  usage = answer.response.usage
  Test.assert(usage.input + usage.cache_read > 0 and usage.output > 0, "usage #{usage}")
end

# The call, then its result sent back with the call as the model gave it: the real server takes both.
def tool_round(provider: LLM.Provider, request: LLM.Request) -> Result[Void]
  answer = try call(provider, request)
  try check_tool_call(answer)
  results = answer.response.message.content.select { |b| tool_use?(b) }.map { |b| result_of(b) }
  messages = request.messages + [answer.response.message, LLM.Message(role: LLM.Role.User, content: results)]
  again = try call(
    provider,
    request.with(messages: messages, tool_choice: LLM.ToolChoice.Auto, extra: {}, max_tokens: some(24)),
  )

  Test.assert(not again.response.message.content.empty?, "no answer after the tool result")
end

# anthropic refuses `Required` (the current Claude models do); llama-server takes `any`, sent as an extra field.
def forced(provider: LLM.Provider, request: LLM.Request) -> LLM.Request
  return request if provider.name != "anthropic"

  any = JSON.object({"type": JSON.from("any")})
  request.with(tool_choice: LLM.ToolChoice.Auto, extra: {"tool_choice": any})
end

def check_tool_call(answer: Answer) -> Result[Void]
  try Test.eq(answer.response.stop_reason, LLM.StopReason.ToolUse)
  calls = answer.response.message.content.select { |b| tool_use?(b) }
  try Test.assert(not calls.empty?, "no tool call: #{answer.response.message.content}")
  case calls[0]
    LLM.Block.ToolUse(tool_call) ->
      try Test.eq(tool_call.name, "read_file")
      try Test.eq(tool_call.input_error, none)
      Test.ok?(JSON.string(try JSON.get(tool_call.input, "path")))
    _ -> error("expected a tool call")
  end
end

def call(provider: LLM.Provider, request: LLM.Request) -> Result[Answer]
  stream = try LLM.stream(provider, request)
  deltas = 0
  while true
    case stream.events.recv(60_000)
      ok(event) -> deltas = deltas + delta_count(event)
      error(_) -> break
    end
  end

  ok(Answer(response: try LLM.response(stream), deltas: deltas))
end

def delta_count(event: LLM.Event) -> Int
  case event
    LLM.Event.TextDelta(_) -> 1
    _ -> 0
  end
end

def user(text: String) -> LLM.Message
  LLM.Message(role: LLM.Role.User, content: [LLM.Block.Text(LLM.TextPart(text: text))])
end

def texts(response: LLM.Response) -> String = response.message.content.map { |b| text_of(b) }.join("")

def text_of(block: LLM.Block) -> String
  case block
    LLM.Block.Text(part) -> part.text
    _ -> ""
  end
end

def result_of(block: LLM.Block) -> LLM.Block
  case block
    LLM.Block.ToolUse(tool_call) ->
      LLM.Block.ToolResult(LLM.ToolOutput(tool_use_id: tool_call.id, content: "# agc-agent\nA coding agent."))
    _ -> block
  end
end

def tool_use?(block: LLM.Block) -> Bool
  case block
    LLM.Block.ToolUse(_) -> true
    _ -> false
  end
end
