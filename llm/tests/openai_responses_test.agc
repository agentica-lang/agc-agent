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

def test_streams_text_and_sends_the_request() -> Result[Void]
  fake = try Fake.start([try Fake.sse("openai_responses/text.sse")])
  request = LLM.Request(
    model: MODEL,
    system: "Answer in one short sentence.",
    messages: [Ev.user("Say hello.")],
    max_tokens: 32,
    temperature: some(0.0),
    extra: {"store": JSON.from(false)},
  )

  call = try LLM.stream(provider(fake), request)
  events = Ev.collect(call)
  response = try LLM.response(call)
  seen = try Fake.next_request(fake)
  try Fake.stop(fake)
  text = "Hello! It's a good day!"
  item_id = "msg_wqc4r8RrRgqRa7EVqqSebgLNB9yUjlfh"
  try Test.eq(Ev.texts(events), text)
  try Test.eq(events[0], LLM.Event.TextDelta(LLM.Piece(index: 0, text: "Hello", item_id: item_id)))
  try Test.eq(events.last, LLM.Event.Stop(LLM.StopReason.EndTurn))
  replay = try JSON.parse("{\"id\": \"#{item_id}\"}")
  try Test.eq(response.message.content, [LLM.Block.Text(LLM.TextPart(text: text, replay: some(replay)))])
  try Test.eq(response.usage, LLM.Usage(input: 22, output: 9))
  try Test.eq(response.id, "resp_LNUiJlrkTe61bkFFnOTExTPJXSuLRUsw")
  try Test.eq([seen.method, seen.path], ["POST", "/v1/responses"])
  try Test.eq(HTTP.header_values(seen.headers, "authorization"), ["Bearer #{KEY}"])
  expected = <<~JSON
    {"model": "qwen2.5-0.5b-instruct", "max_output_tokens": 32, "stream": true, "temperature": 0.0, "store": false,
     "instructions": "Answer in one short sentence.",
     "input": [{"type": "message", "role": "user", "content": [{"type": "input_text", "text": "Say hello."}]}]}
  JSON
  Test.eq(JSON.parse(seen.body), JSON.parse(expected))
end

# The call goes back with its item id, its call_id and its arguments as the model wrote them.
def test_streams_a_tool_call_in_pieces_and_sends_it_back() -> Result[Void]
  replies = [try Fake.sse("openai_responses/tool_call.sse", piece_bytes: 3), try Fake.sse("openai_responses/text.sse")]
  fake = try Fake.start(replies)
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
  item = "fc_CeNRDe1rL888N7ebWb3qSDMgBVGJX8dy"
  call_id = "call_CeNRDe1rL888N7ebWb3qSDMgBVGJX8dy"
  arguments = "{\"path\": \"README.md\", \"limit\": 10}"
  try Test.eq(
    events[0],
    LLM.Event.ToolUseStart(LLM.ToolStart(index: 0, id: call_id, name: "read_file", item_id: item)),
  )

  try Test.eq(Ev.input_pieces(events).join(""), arguments)
  try Test.eq(response.stop_reason, LLM.StopReason.ToolUse)
  tool_call = LLM.ToolCall(
    id: call_id,
    name: "read_file",
    arguments: arguments,
    input: try JSON.parse(arguments),
    replay: some(try JSON.parse("{\"id\": \"#{item}\"}")),
  )

  try Test.eq(response.message.content, [LLM.Block.ToolUse(tool_call)])
  tools = <<~JSON
    [{"type": "function", "name": "read_file", "description": "Read a file of the project.",
      "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "limit": {"type": "integer"}},
                     "required": ["path"]}}]
  JSON
  try Test.eq(JSON.get(try JSON.parse(first.body), "tools"), JSON.parse(tools))
  try Test.eq(JSON.get(try JSON.parse(first.body), "tool_choice"), ok(JSON.from("required")))
  result = LLM.Block.ToolResult(LLM.ToolOutput(tool_use_id: call_id, content: "no such file", is_error: true))
  again = request.with(messages: [ask, response.message, LLM.Message(role: LLM.Role.User, content: [result])])
  _ = try LLM.response(try LLM.stream(provider(fake), again))
  second = try Fake.next_request(fake)
  try Fake.stop(fake)
  expected = <<~JSON
    [{"type": "message", "role": "user",
      "content": [{"type": "input_text", "text": "Read the first 10 lines of README.md."}]},
     {"type": "function_call", "id": "fc_CeNRDe1rL888N7ebWb3qSDMgBVGJX8dy",
      "call_id": "call_CeNRDe1rL888N7ebWb3qSDMgBVGJX8dy",
      "name": "read_file", "arguments": "{\\"path\\": \\"README.md\\", \\"limit\\": 10}"},
     {"type": "function_call_output", "call_id": "call_CeNRDe1rL888N7ebWb3qSDMgBVGJX8dy",
      "output": "Error: no such file"}]
  JSON
  Test.eq(JSON.get(try JSON.parse(second.body), "input"), JSON.parse(expected))
end

# A reasoning item goes back as it came, `encrypted_content` included; a message keeps its id and Codex `phase`.
def test_reasoning_items_and_message_phase_round_trip() -> Result[Void]
  replies = [
    try Fake.sse("openai_responses/encrypted_reasoning.sse", piece_bytes: 11),
    try Fake.sse("openai_responses/text.sse"),
  ]

  fake = try Fake.start(replies)
  ask = Ev.user("Read README.md.")
  call = try LLM.stream(provider(fake), LLM.Request(model: MODEL, messages: [ask]))
  events = Ev.collect(call)
  response = try LLM.response(call)
  try Test.eq(events.map { |e| Ev.thinking_of(e) }.join(""), "Need the README first.")
  try Test.eq(response.stop_reason, LLM.StopReason.ToolUse)
  try Test.eq(response.usage, LLM.Usage(input: 20, output: 40, cache_read: 100, reasoning: 25))
  _ = try LLM.response(try LLM.stream(provider(fake), LLM.Request(model: MODEL, messages: [ask, response.message])))
  _ = try Fake.next_request(fake)
  second = try Fake.next_request(fake)
  try Fake.stop(fake)
  expected = <<~JSON
    [{"type": "message", "role": "user", "content": [{"type": "input_text", "text": "Read README.md."}]},
     {"id": "rs_hand_1", "type": "reasoning", "summary": [{"type": "summary_text", "text": "Need the README first."}],
      "encrypted_content": "gAAAAABoHandMadeOpaqueReasoning=="},
     {"type": "message", "role": "assistant", "id": "msg_hand_1", "phase": "commentary",
      "content": [{"type": "output_text", "text": "Reading it.", "annotations": []}]},
     {"type": "function_call", "id": "fc_hand_1", "call_id": "call_hand_1", "name": "read_file",
      "arguments": "{\\"path\\": \\"README.md\\"}"}]
  JSON
  Test.eq(JSON.get(try JSON.parse(second.body), "input"), JSON.parse(expected))
end

def test_streams_reasoning_text_as_thinking() -> Result[Void]
  fake = try Fake.start([try Fake.sse("openai_responses/reasoning.sse", piece_bytes: 64)])
  call = try LLM.stream(provider(fake), LLM.Request(model: "qwen3-0.6b", messages: [Ev.user("What is 2 + 3?")]))
  events = Ev.collect(call)
  response = try LLM.response(call)
  try Fake.stop(fake)
  thinking = events.map { |e| Ev.thinking_of(e) }.join("")
  try Test.assert(thinking.length > 100, "short thinking: #{thinking}")
  try Test.eq(response.message.content.size, 2)
  case response.message.content[0]
    LLM.Block.Thinking(part) ->
      try Test.eq(part.text, thinking)
      replay = try part.replay.to_result("no replay")
      Test.eq(JSON.get(replay, "id"), ok(JSON.from("rs_n2Ggmx010IPAjBElQCLbfV90vvvkl5B1")))
    _ -> error("expected thinking first")
  end
end

def test_a_custom_tool_call_keeps_its_raw_input() -> Result[Void]
  fake = try Fake.start([
    try Fake.sse("openai_responses/custom_tool_call.sse", piece_bytes: 9),
    try Fake.sse("openai_responses/text.sse"),
  ])

  patch_tool = LLM.Tool(
    name: "apply_patch",
    description: "Edit files.",
    input_schema: JSON.object({}),
    kind: LLM.ToolKind.Custom,
  )

  ask = Ev.user("Add hello.txt.")
  request = LLM.Request(model: MODEL, messages: [ask], tools: [patch_tool])
  response = try LLM.response(try LLM.stream(provider(fake), request))
  patch = "*** Begin Patch\n*** Add File: hello.txt\n+hello\n*** End Patch"
  try Test.eq(response.stop_reason, LLM.StopReason.ToolUse)
  tool_call = LLM.ToolCall(
    id: "call_hand_2",
    name: "apply_patch",
    arguments: patch,
    input: JSON.object({}),
    kind: LLM.ToolKind.Custom,
    replay: some(try JSON.parse("{\"id\": \"ctc_hand_1\"}")),
  )

  try Test.eq(response.message.content, [LLM.Block.ToolUse(tool_call)])
  result = LLM.Block.ToolResult(LLM.ToolOutput(tool_use_id: "call_hand_2", content: "done"))
  again = request.with(messages: [ask, response.message, LLM.Message(role: LLM.Role.User, content: [result])])
  _ = try LLM.response(try LLM.stream(provider(fake), again))
  first = try Fake.next_request(fake)
  second = try Fake.next_request(fake)
  try Fake.stop(fake)
  tools = "[{\"type\": \"custom\", \"name\": \"apply_patch\", \"description\": \"Edit files.\"}]"
  try Test.eq(JSON.get(try JSON.parse(first.body), "tools"), JSON.parse(tools))
  expected = <<~JSON
    [{"type": "message", "role": "user", "content": [{"type": "input_text", "text": "Add hello.txt."}]},
     {"type": "custom_tool_call", "id": "ctc_hand_1", "call_id": "call_hand_2", "name": "apply_patch",
      "input": "*** Begin Patch\\n*** Add File: hello.txt\\n+hello\\n*** End Patch"},
     {"type": "custom_tool_call_output", "call_id": "call_hand_2", "output": "done"}]
  JSON
  Test.eq(JSON.get(try JSON.parse(second.body), "input"), JSON.parse(expected))
end

def test_parallel_tool_calls_stay_apart() -> Result[Void]
  fake = try Fake.start([try Fake.sse("openai_responses/parallel_tool_calls.sse", piece_bytes: 5)])
  call = try LLM.stream(
    provider(fake),
    LLM.Request(model: MODEL, messages: [Ev.user("Read README.md and AGENTS.md.")]),
  )

  events = Ev.collect(call)
  response = try LLM.response(call)
  try Fake.stop(fake)
  try Test.eq(response.message.content.map { |b| Ev.path_of(b) }, ["README.md", "AGENTS.md"])
  Test.eq(Ev.starts(events), [0, 1])
end

def test_incomplete_for_max_output_tokens_is_max_tokens() -> Result[Void]
  fake = try Fake.start([try Fake.sse("openai_responses/length.sse")])
  response = try LLM.response(try LLM.stream(provider(fake), LLM.Request(model: MODEL, messages: [Ev.user("Count.")])))
  try Fake.stop(fake)
  try Test.eq(response.stop_reason, LLM.StopReason.MaxTokens)
  try Test.eq(response.usage, LLM.Usage(input: 19, output: 4, cache_read: 18))
  Test.eq(response.message.content.map { |b| Ev.text_of_block(b) }, ["Sure, here are"])
end

def test_a_failed_response_is_llm_api() -> Result[Void]
  fake = try Fake.start([try Fake.sse("openai_responses/stream_error.sse")])
  call = try LLM.stream(provider(fake), LLM.Request(model: MODEL, messages: [Ev.user("Say hello.")]))
  events = Ev.collect(call)
  result = LLM.response(call)
  try Fake.stop(fake)
  try Test.eq(Ev.texts(events), "Hello!")
  Test.eq(Ev.kind(result), "llm.api")
end

def test_a_429_is_tried_again_and_a_401_is_not() -> Result[Void]
  wait = [HTTP.Header(name: "Retry-After", value: "0")]
  fake = try Fake.start([
    try Fake.json(429, "openai_chat/rate_limited.json", headers: wait),
    try Fake.sse("openai_responses/text.sse"),
    try Fake.json(401, "openai_chat/unauthorized.json"),
    try Fake.sse("openai_responses/text.sse"),
  ])

  request = LLM.Request(model: MODEL, messages: [Ev.user("Say hello.")])
  response = try LLM.response(try LLM.stream(provider(fake), request))
  denied = LLM.stream(provider(fake), request)
  try Fake.stop(fake)
  try Test.eq(response.stop_reason, LLM.StopReason.EndTurn)
  case denied
    ok(_) -> error("expected llm.auth")
    error(e) -> Test.eq([e.kind, e.message], ["llm.auth", "llm: HTTP 401: Invalid API Key"])
  end
end

def test_a_cut_stream_is_llm_protocol() -> Result[Void]
  body = try Fake.fixture("openai_responses/text.sse")
  fake = try Fake.start([Fake.Reply(status: 200, body: body.take(body.size / 2), piece_bytes: 100, cut: true)])
  result = LLM.response(try LLM.stream(provider(fake), LLM.Request(model: MODEL, messages: [Ev.user("Say hello.")])))
  try Fake.stop(fake)
  Test.eq(Ev.kind(result), "llm.protocol")
end

def test_cancel_stops_the_stream() -> Result[Void]
  fake = try Fake.start([try Fake.sse("openai_responses/reasoning.sse", piece_bytes: 1)])
  call = try LLM.stream(provider(fake), LLM.Request(model: MODEL, messages: [Ev.user("What is 2 + 3?")]))
  _ = call.events.recv(5000)
  LLM.cancel(call)
  result = LLM.response(call)
  left = fake.left.recv(5000)
  try Fake.stop(fake)
  try Test.eq(left, ok(true))
  Test.eq(Ev.kind(result), "llm.cancelled")
end

private

def provider(fake: Fake.Fake) -> LLM.Provider
  LLM.openai_responses(fake.url, KEY, LLM.Options(timeout_ms: 5000, retry_base_ms: 1))
end
