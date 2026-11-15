import HTTP from "std/http"
import LLM from "../llm"
import Ev from "support/events"
import Fake from "support/fake_api"

MODEL = "qwen2.5-0.5b-instruct"
KEY = "test-key"
READ_FILE_SCHEMA = (
  "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"limit\":{\"type\":\"integer\"}}," +
  "\"required\":[\"path\"]}"
)
TOOL_ID = "kCTtkXcKcYcFeTlsauQ3UorEfEvfwSZp"

def test_streams_text_and_sends_the_request() -> Result[Void]
  fake = try Fake.start([try Fake.sse("openai_chat/text.sse")])
  request = LLM.Request(
    model: MODEL,
    system: "Answer in one short sentence.",
    messages: [Ev.user("Say hello.")],
    max_tokens: 32,
    temperature: some(0.0),
    seed: some(1),
    extra: {"top_k": JSON.from(1), "seed": JSON.from(2)},
    headers: {"X-Trace": "t1", "authorization": "Bearer caller"},
  )

  call = try LLM.stream(provider(fake), request)
  events = Ev.collect(call)
  response = try LLM.response(call)
  seen = try Fake.next_request(fake)
  try Fake.stop(fake)
  text = "Hello! It's a pleasure to meet you."
  try Test.eq(Ev.texts(events), text)
  try Test.eq(events.last, LLM.Event.Stop(LLM.StopReason.EndTurn))
  try Test.eq(events[0], LLM.Event.TextDelta(LLM.Piece(index: 0, text: "Hello")))
  try Test.eq(response.message, LLM.Message(role: LLM.Role.Assistant, content: [Ev.text_block(text)]))
  try Test.eq(response.id, "chatcmpl-DePvU1zpJk9KrvulQ4vibjpWXDk02mbb")
  try Test.eq(response.usage, LLM.Usage(input: 22, output: 11))
  try Test.eq([seen.method, seen.path], ["POST", "/v1/chat/completions"])
  try Test.eq(HTTP.header_values(seen.headers, "authorization"), ["Bearer caller"])
  try Test.eq(HTTP.header_values(seen.headers, "x-trace"), ["t1"])
  expected = <<~JSON
    {"model": "qwen2.5-0.5b-instruct", "max_tokens": 32, "stream": true, "stream_options": {"include_usage": true},
     "temperature": 0.0, "seed": 2, "top_k": 1,
     "messages": [{"role": "system", "content": "Answer in one short sentence."},
                  {"role": "user", "content": "Say hello."}]}
  JSON
  Test.eq(JSON.parse(seen.body), JSON.parse(expected))
end

# The tool call of the answer, sent back with its result, is the next request: what the read gives is written back.
def test_streams_a_tool_call_in_pieces_and_sends_it_back() -> Result[Void]
  fake = try Fake.start([
    try Fake.sse("openai_chat/tool_call.sse", piece_bytes: 3),
    try Fake.sse("openai_chat/text.sse"),
  ])

  tool = LLM.Tool(
    name: "read_file",
    description: "Read a file of the project.",
    input_schema: try JSON.parse(READ_FILE_SCHEMA),
  )

  ask = Ev.user("Read the first 10 lines of README.md.")
  request = LLM.Request(model: MODEL, messages: [ask], tools: [tool], tool_choice: LLM.ToolChoice.Required)
  call = try LLM.stream(provider(fake), request)
  events = Ev.collect(call)
  response = try LLM.response(call)
  first = try Fake.next_request(fake)
  arguments = "{\"path\": \"README.md\", \"limit\": 10}"
  try Test.eq(events.first, LLM.Event.ToolUseStart(LLM.ToolStart(index: 0, id: TOOL_ID, name: "read_file")))
  try Test.eq(Ev.input_pieces(events).join(""), arguments)
  try Test.eq(Ev.input_pieces(events).size > 1, true)
  try Test.eq(response.stop_reason, LLM.StopReason.ToolUse)
  input = try JSON.parse(arguments)
  call_block = LLM.ToolCall(id: TOOL_ID, name: "read_file", arguments: arguments, input: input)
  try Test.eq(response.message.content, [LLM.Block.ToolUse(call_block)])

  try Test.eq(JSON.get(JSON.parse(first.body).unwrap!, "tool_choice"), ok(JSON.from("required")))
  try Test.eq(
    JSON.get(JSON.parse(first.body).unwrap!, "tools"),
    JSON.parse(
      "[{\"type\": \"function\", \"function\": {\"name\": \"read_file\", " +
      "\"description\": \"Read a file of the project.\", \"parameters\": #{READ_FILE_SCHEMA}}}]",
    ),
  )

  result = LLM.Block.ToolResult(LLM.ToolOutput(tool_use_id: TOOL_ID, content: "no such file", is_error: true))
  again = request.with(messages: [ask, response.message, LLM.Message(role: LLM.Role.User, content: [result])])
  _ = try LLM.response(try LLM.stream(provider(fake), again))
  second = try Fake.next_request(fake)
  try Fake.stop(fake)
  expected = <<~JSON
    [{"role": "user", "content": "Read the first 10 lines of README.md."},
     {"role": "assistant", "content": null,
      "tool_calls": [{"id": "kCTtkXcKcYcFeTlsauQ3UorEfEvfwSZp", "type": "function",
      "function": {"name": "read_file", "arguments": "{\\"path\\": \\"README.md\\", \\"limit\\": 10}"}}]},
     {"role": "tool", "tool_call_id": "kCTtkXcKcYcFeTlsauQ3UorEfEvfwSZp", "content": "Error: no such file"}]
  JSON
  Test.eq(JSON.get(JSON.parse(second.body).unwrap!, "messages"), JSON.parse(expected))
end

def test_streams_reasoning_content_as_thinking() -> Result[Void]
  fake = try Fake.start([try Fake.sse("openai_chat/reasoning.sse", piece_bytes: 64)])
  call = try LLM.stream(provider(fake), LLM.Request(model: "qwen3-0.6b", messages: [Ev.user("What is 2 + 3?")]))
  events = Ev.collect(call)
  response = try LLM.response(call)
  try Fake.stop(fake)
  thinking = events.map { |e| Ev.thinking_of(e) }.join("")
  try Test.eq(thinking.size > 100, true)
  thought = LLM.Block.Thinking(LLM.ThinkingPart(text: thinking))
  try Test.eq(response.message.content, [thought, Ev.text_block("2 + 3 = 5")])
  try Test.eq(events[0], LLM.Event.ThinkingDelta(LLM.Piece(index: 0, text: "Okay")))
  Test.eq(response.usage, LLM.Usage(input: 21, output: 182))
end

def test_length_is_max_tokens() -> Result[Void]
  fake = try Fake.start([try Fake.sse("openai_chat/length.sse")])
  response = try LLM.response(try LLM.stream(provider(fake), LLM.Request(model: MODEL, messages: [Ev.user("Count.")])))
  try Fake.stop(fake)
  try Test.eq(response.stop_reason, LLM.StopReason.MaxTokens)
  Test.eq(response.message.content, [Ev.text_block("Sure, here are")])
end

def test_an_error_inside_the_stream_is_llm_api() -> Result[Void]
  fake = try Fake.start([try Fake.sse("openai_chat/stream_error.sse")])
  call = try LLM.stream(provider(fake), LLM.Request(model: MODEL, messages: [Ev.user("Say hello.")]))
  events = Ev.collect(call)
  result = LLM.response(call)
  try Fake.stop(fake)
  try Test.eq(Ev.texts(events), "Hello!")
  Test.eq(Ev.kind(result), "llm.api")
end

def test_a_429_is_tried_again_after_retry_after() -> Result[Void]
  wait = [HTTP.Header(name: "Retry-After", value: "0")]
  fake = try Fake.start([
    try Fake.json(429, "openai_chat/rate_limited.json", headers: wait),
    try Fake.sse("openai_chat/text.sse"),
  ])

  response = try LLM.response(
    try LLM.stream(provider(fake), LLM.Request(model: MODEL, messages: [Ev.user("Say hello.")])),
  )

  first = try Fake.next_request(fake)
  second = try Fake.next_request(fake)
  try Fake.stop(fake)
  try Test.eq(response.stop_reason, LLM.StopReason.EndTurn)
  Test.eq(second.body, first.body)
end

def test_a_retry_after_past_the_limit_fails_at_once() -> Result[Void]
  wait = [HTTP.Header(name: "Retry-After", value: "3600")]
  fake = try Fake.start([
    try Fake.json(429, "openai_chat/rate_limited.json", headers: wait),
    try Fake.sse("openai_chat/text.sse"),
  ])

  result = LLM.stream(provider(fake), LLM.Request(model: MODEL, messages: [Ev.user("Say hello.")]))
  try Fake.stop(fake)
  case result
    ok(_) -> error("expected llm.rate_limit")
    error(e) ->
      try Test.eq(e.kind, "llm.rate_limit")
      Test.eq(e.details, {"retry_after_ms": "3600000"})
  end
end

def test_parallel_tool_calls_stay_apart() -> Result[Void]
  for name in ["openai_chat/parallel_tool_calls.sse", "openai_chat/tool_calls_no_index.sse"]
    fake = try Fake.start([try Fake.sse(name, piece_bytes: 5)])
    call = try LLM.stream(
      provider(fake),
      LLM.Request(model: MODEL, messages: [Ev.user("Read README.md and AGENTS.md.")]),
    )

    events = Ev.collect(call)
    response = try LLM.response(call)
    try Fake.stop(fake)
    paths = response.message.content.map { |b| Ev.path_of(b) }
    try Test.eq(paths, ["README.md", "AGENTS.md"])
    try Test.eq(Ev.starts(events), [0, 1])
  end

  ok()
end

def test_arguments_that_do_not_parse_are_kept_and_marked() -> Result[Void]
  fake = try Fake.start([try Fake.sse("openai_chat/bad_arguments.sse")])
  response = try LLM.response(
    try LLM.stream(provider(fake), LLM.Request(model: MODEL, messages: [Ev.user("Read it.")])),
  )

  try Fake.stop(fake)
  try Test.eq(response.message.content.size, 1)
  case response.message.content[0]
    LLM.Block.ToolUse(call) ->
      try Test.eq(call.arguments, "{\"path\": README.md")
      try Test.eq(call.input, JSON.object({}))
      Test.eq(call.input_error.some?, true)
    _ -> error("expected a tool call")
  end
end

def test_a_custom_tool_is_refused_before_sending() -> Result[Void]
  fake = try Fake.start([try Fake.sse("openai_chat/text.sse")])
  patch = LLM.Tool(
    name: "apply_patch",
    description: "Edit files.",
    input_schema: JSON.object({}),
    kind: LLM.ToolKind.Custom,
  )

  result = LLM.stream(provider(fake), LLM.Request(model: MODEL, messages: [Ev.user("Fix it.")], tools: [patch]))
  try Fake.stop(fake)
  try Test.assert(fake.seen.empty?, "the request was sent")
  case result
    ok(_) -> error("expected llm.unsupported")
    error(e) -> Test.eq(e.kind, "llm.unsupported")
  end
end

# Events nobody reads fill their channel; the call then fails instead of waiting for ever.
def test_events_not_read_in_time_are_llm_slow_reader() -> Result[Void]
  fake = try Fake.start([try Fake.sse("openai_chat/reasoning.sse", piece_bytes: 4096)])
  slow = LLM.openai_chat(fake.url, KEY, LLM.Options(timeout_ms: 300))
  call = try LLM.stream(slow, LLM.Request(model: MODEL, messages: [Ev.user("What is 2 + 3?")]))
  result = Task.await(call.done)
  try Fake.stop(fake)
  Test.eq(Ev.kind(result), "llm.slow_reader")
end

def test_a_401_is_llm_auth_and_not_tried_again() -> Result[Void]
  fake = try Fake.start([try Fake.json(401, "openai_chat/unauthorized.json"), try Fake.sse("openai_chat/text.sse")])
  result = LLM.stream(provider(fake), LLM.Request(model: MODEL, messages: [Ev.user("Say hello.")]))
  try Fake.stop(fake)
  case result
    ok(_) -> error("expected llm.auth")
    error(e) ->
      try Test.eq([e.kind, e.message], ["llm.auth", "llm: HTTP 401: Invalid API Key"])
      Test.eq(e.code, some(401))
  end
end

def test_a_cut_stream_is_llm_protocol() -> Result[Void]
  body = try Fake.fixture("openai_chat/text.sse")
  cut = Fake.Reply(status: 200, body: body.take(body.size / 2), piece_bytes: 100, cut: true)
  fake = try Fake.start([cut])
  call = try LLM.stream(provider(fake), LLM.Request(model: MODEL, messages: [Ev.user("Say hello.")]))
  result = LLM.response(call)
  try Fake.stop(fake)
  Test.eq(Ev.kind(result), "llm.protocol")
end

def test_cancel_stops_the_stream() -> Result[Void]
  fake = try Fake.start([try Fake.sse("openai_chat/reasoning.sse", piece_bytes: 1)])
  call = try LLM.stream(provider(fake), LLM.Request(model: MODEL, messages: [Ev.user("What is 2 + 3?")]))
  _ = call.events.recv(5000)
  LLM.cancel(call)
  result = LLM.response(call)
  left = fake.left.recv(5000)
  try Fake.stop(fake)
  try Test.eq(left, ok(true))
  Test.eq(Ev.kind(result), "llm.cancelled")
end

def test_lists_the_models_with_their_context() -> Result[Void]
  fake = try Fake.start([try Fake.json(200, "openai_chat/models.json")])
  models = LLM.models(provider(fake))
  seen = try Fake.next_request(fake)
  try Fake.stop(fake)
  try Test.eq([seen.method, seen.path], ["GET", "/v1/models"])
  try Test.eq(HTTP.header_values(seen.headers, "authorization"), ["Bearer #{KEY}"])
  Test.eq(models, ok([LLM.Model(id: MODEL, context: some(4096))]))
end

private

def provider(fake: Fake.Fake) -> LLM.Provider
  LLM.openai_chat(fake.url, KEY, LLM.Options(timeout_ms: 5000, retry_base_ms: 1))
end
