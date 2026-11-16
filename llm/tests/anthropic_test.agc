import HTTP from "std/http"
import LLM from "../llm"
import Ev from "support/events"
import Fake from "support/fake_api"

KEY = "test-key"
READ_FILE_SCHEMA = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}"

def test_streams_text_and_sends_the_request() -> Result[Void]
  fake = try Fake.start([try Fake.sse("anthropic/text.sse")])
  request = LLM.Request(
    model: LLM.ANTHROPIC_MODEL,
    system: "Be short.",
    messages: [Ev.user("Say hello."), assistant([Ev.text_block("")]), Ev.user("Again.")],
    tools: [read_file()],
    max_tokens: 32,
    effort: some("high"),
    cache: true,
  )

  call = try LLM.stream(provider(fake), request)
  events = Ev.collect(call)
  response = try LLM.response(call)
  seen = try Fake.next_request(fake)
  try Fake.stop(fake)
  text = "Hello! How can I assist you today?"
  try Test.eq(Ev.texts(events), text)
  try Test.eq(events[0], LLM.Event.TextDelta(LLM.Piece(index: 0, text: "Hello")))
  try Test.eq(events.last, LLM.Event.Stop(LLM.StopReason.EndTurn))
  try Test.eq(response.message.content, [Ev.text_block(text)])
  try Test.eq(response.usage, LLM.Usage(input: 19, output: 10))
  try Test.eq(response.id, "chatcmpl-Fui7JVlvG3ngdJmjUp7ZhjM1f1wVeNqT")
  try Test.eq([seen.method, seen.path], ["POST", "/v1/messages"])
  try Test.eq(HTTP.header_values(seen.headers, "x-api-key"), [KEY])
  try Test.eq(HTTP.header_values(seen.headers, "anthropic-version"), ["2026-10-21"])
  try Test.eq(HTTP.header_values(seen.headers, "authorization"), [])
  # The empty assistant message is not sent; the breakpoint is on the system prompt, which ends the prefix.
  expected = <<~JSON
    {"model": "claude-opus-5-5", "max_tokens": 32, "stream": true,
     "thinking": {"type": "adaptive", "display": "summarized"}, "output_config": {"effort": "high"},
     "cache_control": {"type": "ephemeral"},
     "system": [{"type": "text", "text": "Be short.", "cache_control": {"type": "ephemeral"}}],
     "tools": [{"name": "read_file", "description": "Read a file of the project.",
                "input_schema": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}],
     "tool_choice": {"type": "auto"},
     "messages": [{"role": "user", "content": [{"type": "text", "text": "Say hello."}]},
                  {"role": "user", "content": [{"type": "text", "text": "Again."}]}]}
  JSON
  Test.eq(JSON.parse(seen.body), JSON.parse(expected))
end

# Thinking goes back unchanged with its signature, redacted thinking with its data, the call with its input.
def test_thinking_and_a_tool_call_round_trip() -> Result[Void]
  replies = [try Fake.sse("anthropic/thinking_tool_use.sse", piece_bytes: 5), try Fake.sse("anthropic/text.sse")]

  fake = try Fake.start(replies)
  ask = Ev.user("Read README.md.")
  request = LLM.Request(model: LLM.ANTHROPIC_MODEL, messages: [ask], tools: [read_file()], cache: true)
  call = try LLM.stream(provider(fake), request)
  events = Ev.collect(call)
  response = try LLM.response(call)
  try Test.eq(events.map { |e| Ev.thinking_of(e) }.join(""), "Need the README first.")
  try Test.eq(Ev.starts(events), [3])
  try Test.eq(Ev.input_pieces(events), ["{\"path\": \"READ", "ME.md\"}"])
  try Test.eq(response.stop_reason, LLM.StopReason.ToolUse)
  try Test.eq(response.usage, LLM.Usage(input: 12, output: 45, cache_read: 2000, cache_write: 300))
  try Test.eq(response.message.content.size, 4)
  try Test.eq(Ev.path_of(response.message.content[3]), "README.md")
  result = LLM.Block.ToolResult(LLM.ToolOutput(tool_use_id: "toolu_hand_1", content: "no such file", is_error: true))
  again = request.with(messages: [ask, response.message, LLM.Message(role: LLM.Role.User, content: [result])])
  _ = try LLM.response(try LLM.stream(provider(fake), again))
  first = try JSON.parse((try Fake.next_request(fake)).body)
  second = try JSON.parse((try Fake.next_request(fake)).body)
  try Fake.stop(fake)
  # No system prompt: the breakpoint of the prefix is on the last tool.
  tools = <<~JSON
    [{"name": "read_file", "description": "Read a file of the project.", "cache_control": {"type": "ephemeral"},
      "input_schema": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}]
  JSON
  try Test.eq(JSON.get(first, "tools"), JSON.parse(tools))
  expected = <<~JSON
    [{"role": "user", "content": [{"type": "text", "text": "Read README.md."}]},
     {"role": "assistant", "content": [
       {"type": "thinking", "thinking": "Need the README first.", "signature": "EqQBCkYIBxgCKkBhandMadeSignature=="},
       {"type": "redacted_thinking", "data": "EmwKAhandMadeRedacted=="},
       {"type": "text", "text": "Reading it."},
       {"type": "tool_use", "id": "toolu_hand_1", "name": "read_file", "input": {"path": "README.md"}}]},
     {"role": "user", "content": [
       {"type": "tool_result", "tool_use_id": "toolu_hand_1", "content": "no such file", "is_error": true}]}]
  JSON
  Test.eq(JSON.get(second, "messages"), JSON.parse(expected))
end

# A required tool is `any`; the thinking of another provider is not sent.
def test_a_required_tool_call_streams_in_pieces() -> Result[Void]
  fake = try Fake.start([try Fake.sse("anthropic/tool_call.sse", piece_bytes: 3)])
  other = LLM.Block.Thinking(LLM.ThinkingPart(text: "x", replay: some(JSON.object({"type": JSON.from("reasoning")}))))
  messages = [Ev.user("Hi."), assistant([other, Ev.text_block("Hello.")]), Ev.user("Read README.md.")]
  request = LLM.Request(
    model: LLM.ANTHROPIC_MODEL,
    messages: messages,
    tools: [read_file()],
    tool_choice: LLM.ToolChoice.Required,
  )

  call = try LLM.stream(provider(fake), request)
  events = Ev.collect(call)
  response = try LLM.response(call)
  body = try JSON.parse((try Fake.next_request(fake)).body)
  try Fake.stop(fake)
  try Test.eq(
    events[0],
    LLM.Event.ToolUseStart(LLM.ToolStart(index: 0, id: "jsA9T2Jk1XfH3UVF3krAhvEQHIpTPtvx", name: "read_file")),
  )

  try Test.eq(response.stop_reason, LLM.StopReason.ToolUse)
  try Test.eq(Ev.path_of(response.message.content[0]), "README.md")
  try Test.eq(JSON.get(body, "tool_choice"), JSON.parse("{\"type\": \"any\"}"))
  sent: List[JSON.Value] = try JSON.list(try JSON.get(body, "messages"))
  Test.eq(
    ok(sent[1]),
    JSON.parse("{\"role\": \"assistant\", \"content\": [{\"type\": \"text\", \"text\": \"Hello.\"}]}"),
  )
end

def test_an_error_in_the_stream_is_llm_api() -> Result[Void]
  fake = try Fake.start([try Fake.sse("anthropic/stream_error.sse")])
  call = try LLM.stream(provider(fake), LLM.Request(model: LLM.ANTHROPIC_MODEL, messages: [Ev.user("Say hello.")]))
  result = LLM.response(call)
  try Fake.stop(fake)
  case result
    ok(_) -> error("expected llm.api")
    error(e) -> Test.eq([e.kind, e.details.get("type").unwrap_or("")], ["llm.api", "overloaded_error"])
  end
end

def test_a_529_is_tried_again_and_a_401_is_llm_auth() -> Result[Void]
  fake = try Fake.start([
    try Fake.json(529, "anthropic/overloaded.json"),
    try Fake.sse("anthropic/text.sse"),
    try Fake.json(401, "anthropic/unauthorized.json"),
    try Fake.sse("anthropic/text.sse"),
  ])

  request = LLM.Request(model: LLM.ANTHROPIC_MODEL, messages: [Ev.user("Say hello.")])
  first = LLM.response(try LLM.stream(provider(fake), request))
  second = LLM.stream(provider(fake), request)
  try Fake.stop(fake)
  try Test.eq(Ev.kind(first), "ok")
  case second
    ok(_) -> error("expected llm.auth")
    error(e) -> Test.eq([e.kind, e.message], ["llm.auth", "llm: HTTP 401: invalid x-api-key"])
  end
end

def test_a_cut_stream_is_llm_protocol() -> Result[Void]
  body = try Fake.fixture("anthropic/text.sse")
  fake = try Fake.start([Fake.Reply(status: 200, body: body.take(body.size / 2), piece_bytes: 100, cut: true)])
  call = try LLM.stream(provider(fake), LLM.Request(model: LLM.ANTHROPIC_MODEL, messages: [Ev.user("Say hello.")]))
  result = LLM.response(call)
  try Fake.stop(fake)
  Test.eq(Ev.kind(result), "llm.protocol")
end

def test_a_custom_tool_is_refused_before_sending() -> Result[Void]
  fake = try Fake.start([try Fake.sse("anthropic/text.sse")])
  patch = LLM.Tool(name: "apply_patch", description: "Edit.", input_schema: JSON.object({}), kind: LLM.ToolKind.Custom)
  request = LLM.Request(model: LLM.ANTHROPIC_MODEL, messages: [Ev.user("Fix it.")], tools: [patch])
  result = LLM.stream(provider(fake), request)
  try Fake.stop(fake)
  try Test.assert(fake.seen.empty?, "the request was sent")
  case result
    ok(_) -> error("expected llm.unsupported")
    error(e) -> Test.eq(e.kind, "llm.unsupported")
  end
end

def test_lists_the_models_with_their_context() -> Result[Void]
  fake = try Fake.start([try Fake.json(200, "anthropic/models.json")])
  models = LLM.models(provider(fake))
  seen = try Fake.next_request(fake)
  try Fake.stop(fake)
  try Test.eq([seen.method, seen.target], ["GET", "/v1/models?limit=1000"])
  try Test.eq(HTTP.header_values(seen.headers, "x-api-key"), [KEY])
  try Test.eq(HTTP.header_values(seen.headers, "anthropic-version"), ["2026-10-21"])
  expected = [
    LLM.Model(id: LLM.ANTHROPIC_MODEL, context: some(1_000_000)),
    LLM.Model(id: LLM.ANTHROPIC_CHEAP_MODEL, context: some(1_000_000)),
  ]

  Test.eq(models, ok(expected))
end

private

def provider(fake: Fake.Fake) -> LLM.Provider
  LLM.anthropic(fake.url, KEY, LLM.Options(timeout_ms: 5000, retry_base_ms: 1))
end

def read_file() -> LLM.Tool
  LLM.Tool(
    name: "read_file",
    description: "Read a file of the project.",
    input_schema: JSON.parse(READ_FILE_SCHEMA).unwrap!,
  )
end

def assistant(content: List[LLM.Block]) -> LLM.Message = LLM.Message(role: LLM.Role.Assistant, content: content)
