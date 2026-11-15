import HTTP from "std/http"
import LLM from "../llm"
import Fake from "support/fake_api"

MODEL = "qwen2.5-0.5b-instruct"
KEY = "test-key"
READ_FILE_SCHEMA = (
  "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"limit\":{\"type\":\"integer\"}}," +
  "\"required\":[\"path\"]}"
)
TOOL_ID = "kCTtkXcKcYcFeTlsauQ3UorEfEvfwSZp"

def test_streams_text_and_sends_the_request() -> Result[Void]
  fake = try Fake.start([try Fake.sse("text.sse")])
  request = LLM.Request(
    model: MODEL,
    system: "Answer in one short sentence.",
    messages: [user("Say hello.")],
    max_tokens: 32,
    temperature: some(0.0),
    seed: some(1),
  )

  call = try LLM.stream(provider(fake), request)
  events = collect(call)
  response = try LLM.response(call)
  seen = try Fake.next_request(fake)
  try Fake.stop(fake)
  text = "Hello! It's a pleasure to meet you."
  try Test.eq(texts(events), text)
  try Test.eq(events.last, LLM.Event.Stop(LLM.StopReason.EndTurn))
  try Test.eq(response.message, LLM.Message(role: LLM.Role.Assistant, content: [LLM.Block.Text(text)]))
  try Test.eq(response.usage, LLM.Usage(input: 22, output: 11))
  try Test.eq([seen.method, seen.path], ["POST", "/v1/chat/completions"])
  try Test.eq(HTTP.header_values(seen.headers, "authorization"), ["Bearer #{KEY}"])
  expected = <<~JSON
    {"model": "qwen2.5-0.5b-instruct", "max_tokens": 32, "stream": true, "stream_options": {"include_usage": true},
     "temperature": 0.0, "seed": 1,
     "messages": [{"role": "system", "content": "Answer in one short sentence."},
                  {"role": "user", "content": "Say hello."}]}
  JSON
  Test.eq(JSON.parse(seen.body), JSON.parse(expected))
end

# The tool call of the answer, sent back with its result, is the next request: what the read gives is written back.
def test_streams_a_tool_call_in_pieces_and_sends_it_back() -> Result[Void]
  fake = try Fake.start([try Fake.sse("tool_call.sse", piece_bytes: 3), try Fake.sse("text.sse")])
  tool = LLM.Tool(
    name: "read_file",
    description: "Read a file of the project.",
    input_schema: try JSON.parse(READ_FILE_SCHEMA),
  )

  ask = user("Read the first 10 lines of README.md.")
  request = LLM.Request(model: MODEL, messages: [ask], tools: [tool], tool_choice: LLM.ToolChoice.Required)
  call = try LLM.stream(provider(fake), request)
  events = collect(call)
  response = try LLM.response(call)
  first = try Fake.next_request(fake)
  arguments = "{\"path\": \"README.md\", \"limit\": 10}"
  try Test.eq(events.first, LLM.Event.ToolUseStart(TOOL_ID, "read_file"))
  try Test.eq(input_pieces(events).join(""), arguments)
  try Test.eq(input_pieces(events).size > 1, true)
  try Test.eq(response.stop_reason, LLM.StopReason.ToolUse)
  input = try JSON.parse(arguments)
  try Test.eq(
    response.message.content,
    [LLM.Block.ToolUse(LLM.ToolCall(id: TOOL_ID, name: "read_file", input: input))],
  )

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
      "function": {"name": "read_file", "arguments": "{\\"limit\\":10,\\"path\\":\\"README.md\\"}"}}]},
     {"role": "tool", "tool_call_id": "kCTtkXcKcYcFeTlsauQ3UorEfEvfwSZp", "content": "Error: no such file"}]
  JSON
  Test.eq(JSON.get(JSON.parse(second.body).unwrap!, "messages"), JSON.parse(expected))
end

def test_streams_reasoning_content_as_thinking() -> Result[Void]
  fake = try Fake.start([try Fake.sse("reasoning.sse", piece_bytes: 64)])
  call = try LLM.stream(provider(fake), LLM.Request(model: "qwen3-0.6b", messages: [user("What is 2 + 3?")]))
  events = collect(call)
  response = try LLM.response(call)
  try Fake.stop(fake)
  thinking = events.map { |e| thinking_of(e) }.join("")
  try Test.eq(thinking.size > 100, true)
  try Test.eq(response.message.content, [LLM.Block.Thinking(thinking, JSON.null()), LLM.Block.Text("2 + 3 = 5")])
  Test.eq(response.usage, LLM.Usage(input: 21, output: 182))
end

def test_length_is_max_tokens() -> Result[Void]
  fake = try Fake.start([try Fake.sse("length.sse")])
  response = try LLM.response(try LLM.stream(provider(fake), LLM.Request(model: MODEL, messages: [user("Count.")])))
  try Fake.stop(fake)
  try Test.eq(response.stop_reason, LLM.StopReason.MaxTokens)
  Test.eq(response.message.content, [LLM.Block.Text("Sure, here are")])
end

def test_an_error_inside_the_stream_is_llm_api() -> Result[Void]
  fake = try Fake.start([try Fake.sse("stream_error.sse")])
  call = try LLM.stream(provider(fake), LLM.Request(model: MODEL, messages: [user("Say hello.")]))
  events = collect(call)
  result = LLM.response(call)
  try Fake.stop(fake)
  try Test.eq(texts(events), "Hello!")
  Test.eq(kind(result), "llm.api")
end

def test_a_429_is_tried_again_after_retry_after() -> Result[Void]
  wait = [HTTP.Header(name: "Retry-After", value: "0")]
  fake = try Fake.start([try Fake.json(429, "rate_limited.json", headers: wait), try Fake.sse("text.sse")])
  response = try LLM.response(
    try LLM.stream(provider(fake), LLM.Request(model: MODEL, messages: [user("Say hello.")])),
  )

  first = try Fake.next_request(fake)
  second = try Fake.next_request(fake)
  try Fake.stop(fake)
  try Test.eq(response.stop_reason, LLM.StopReason.EndTurn)
  Test.eq(second.body, first.body)
end

def test_a_401_is_llm_auth_and_not_tried_again() -> Result[Void]
  fake = try Fake.start([try Fake.json(401, "unauthorized.json"), try Fake.sse("text.sse")])
  result = LLM.stream(provider(fake), LLM.Request(model: MODEL, messages: [user("Say hello.")]))
  try Fake.stop(fake)
  case result
    ok(_) -> error("expected llm.auth")
    error(e) ->
      try Test.eq([e.kind, e.message], ["llm.auth", "llm: HTTP 401: Invalid API Key"])
      Test.eq(e.code, some(401))
  end
end

def test_a_cut_stream_is_llm_protocol() -> Result[Void]
  body = try Fake.fixture("text.sse")
  cut = Fake.Reply(status: 200, body: body.take(body.size / 2), piece_bytes: 100, cut: true)
  fake = try Fake.start([cut])
  call = try LLM.stream(provider(fake), LLM.Request(model: MODEL, messages: [user("Say hello.")]))
  result = LLM.response(call)
  try Fake.stop(fake)
  Test.eq(kind(result), "llm.protocol")
end

def test_cancel_stops_the_stream() -> Result[Void]
  fake = try Fake.start([try Fake.sse("reasoning.sse", piece_bytes: 1)])
  call = try LLM.stream(provider(fake), LLM.Request(model: MODEL, messages: [user("What is 2 + 3?")]))
  _ = call.events.recv(5000)
  LLM.cancel(call)
  result = LLM.response(call)
  try Fake.stop(fake)
  Test.eq(kind(result), "llm.cancelled")
end

def test_lists_the_models_with_their_context() -> Result[Void]
  fake = try Fake.start([try Fake.json(200, "models.json")])
  models = LLM.models(provider(fake))
  seen = try Fake.next_request(fake)
  try Fake.stop(fake)
  try Test.eq([seen.method, seen.path], ["GET", "/v1/models"])
  Test.eq(models, ok([LLM.Model(id: MODEL, context: some(4096))]))
end

private

def provider(fake: Fake.Fake) -> LLM.Provider
  LLM.openai_chat(fake.url, KEY, LLM.OpenAIChatOptions(timeout_ms: 5000, retry_base_ms: 1))
end

def user(text: String) -> LLM.Message = LLM.Message(role: LLM.Role.User, content: [LLM.Block.Text(text)])

def collect(call: LLM.Stream) -> List[LLM.Event]
  events: List[LLM.Event] = []
  while true
    case call.events.recv(5000)
      ok(event) -> events = events.push(event)
      error(_) -> break
    end
  end

  events
end

def texts(events: List[LLM.Event]) -> String = events.map { |e| text_of(e) }.join("")

def text_of(event: LLM.Event) -> String
  case event
    LLM.Event.TextDelta(text) -> text
    _ -> ""
  end
end

def thinking_of(event: LLM.Event) -> String
  case event
    LLM.Event.ThinkingDelta(text) -> text
    _ -> ""
  end
end

def input_pieces(events: List[LLM.Event]) -> List[String]
  events.map { |e| input_of(e) }.select { |piece| not piece.empty? }
end

def input_of(event: LLM.Event) -> String
  case event
    LLM.Event.ToolInputDelta(_, piece) -> piece
    _ -> ""
  end
end

def kind(result: Result[LLM.Response]) -> String
  case result
    ok(_) -> "ok"
    error(e) -> e.kind
  end
end
