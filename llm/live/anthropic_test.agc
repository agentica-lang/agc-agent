## Real calls to Anthropic on the cheap model, which cost money: only `make smoke-anthropic`, with the owner's yes,
## never in CI. They read `ANTHROPIC_API_KEY`, else `ANTHROPIC_AUTH_TOKEN`, and never print either.

import LLM from "../llm"

MAX_TOKENS = 256
# Over the 512 tokens that the cheap model caches at least.
RULES = 60
READ_FILE_SCHEMA = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}"

# Four calls on one cached prefix (the system prompt and the tool): a text turn, a tool call, its result sent back
# with the thinking of the call, then that last request again, which reads the prefix from the cache.
def test_anthropic_text_tool_round_and_cache() -> Result[Void]
  provider = try live_provider()
  base = LLM.Request(
    model: LLM.ANTHROPIC_CHEAP_MODEL,
    system: system_prompt(),
    messages: [],
    tools: [
      LLM.Tool(
        name: "read_file",
        description: "Read a file of the project.",
        input_schema: try JSON.parse(READ_FILE_SCHEMA),
      ),
    ],
    max_tokens: MAX_TOKENS,
    effort: some("low"),
    cache: true,
  )

  text = try call(provider, base.with(messages: [user("Say hello in one word. Do not use a tool.")]))
  try Test.assert(text.message.content.any? { |b| text?(b) }, "no text: #{text.stop_reason}")
  ask = user("Use read_file to read README.md.")
  first = try call(provider, base.with(messages: [ask]))
  try Test.eq(first.stop_reason, LLM.StopReason.ToolUse)
  results = first.message.content.select { |b| tool_use?(b) }.map { |b| result_of(b) }
  round = base.with(messages: [ask, first.message, LLM.Message(role: LLM.Role.User, content: results)])
  answer = try call(provider, round)
  try Test.assert(not answer.message.content.empty?, "no answer after the tool result")
  again = try call(provider, round)
  report("anthropic live: cache_read #{again.usage.cache_read}, cache_write #{again.usage.cache_write}\n")
  Test.assert(again.usage.cache_read > 0, "the second identical call read nothing from the cache: #{again.usage}")
end

private

# The runner drops the output of a passed test: the line goes to the file of `ANTHROPIC_LIVE_REPORT`, which the
# Makefile prints.
def report(line: String) -> Void
  case System.env("ANTHROPIC_LIVE_REPORT")
    ok(path) if not path.empty? -> _ = File.write_text(path, line)
    _ -> nil
  end
end

def live_provider() -> Result[LLM.Provider]
  key = System.env("ANTHROPIC_API_KEY").unwrap_or("")
  token = System.env("ANTHROPIC_AUTH_TOKEN").unwrap_or("")
  return error("set ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN") if key.empty? and token.empty?

  ok(LLM.anthropic(LLM.ANTHROPIC_URL, key, auth_token: token))
end

def system_prompt() -> String
  rules = (1..RULES).map { |n| "Rule #{n}: answer briefly, use a tool only when the user asks for one, never guess." }
  "You are a test assistant.\n" + rules.join("\n")
end

def call(provider: LLM.Provider, request: LLM.Request) -> Result[LLM.Response]
  LLM.response(try LLM.stream(provider, request))
end

def user(text: String) -> LLM.Message
  LLM.Message(role: LLM.Role.User, content: [LLM.Block.Text(LLM.TextPart(text: text))])
end

def text?(block: LLM.Block) -> Bool
  case block
    LLM.Block.Text(part) -> not part.text.strip.empty?
    _ -> false
  end
end

def tool_use?(block: LLM.Block) -> Bool
  case block
    LLM.Block.ToolUse(_) -> true
    _ -> false
  end
end

def result_of(block: LLM.Block) -> LLM.Block
  case block
    LLM.Block.ToolUse(tool_call) ->
      LLM.Block.ToolResult(LLM.ToolOutput(tool_use_id: tool_call.id, content: "# demo\nA small demo project."))
    _ -> block
  end
end
