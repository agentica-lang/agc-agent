import HTTP from "std/http"
import LLM from "../llm"
import AnthropicWire from "../src/anthropic_wire"
import ChatWire from "../src/openai_chat_wire"
import ResponsesWire from "../src/openai_responses_wire"
import Ev from "support/events"
import Fake from "support/fake_api"

MODEL = "qwen2.5-0.5b-instruct"
KEY = "test-key"
READ_FILE_SCHEMA = (
  "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"limit\":{\"type\":\"integer\"}}," +
  "\"required\":[\"path\"]}"
)
TOOL_ID = "kCTtkXcKcYcFeTlsauQ3UorEfEvfwSZp"

struct ReadArgs
  path: String
  offset: Optional[Int]
  limit: Optional[Int]
end

def test_streams_text_and_sends_the_request() -> Result[Void]
  fake = try Fake.start([try Fake.sse("openai_chat/text.sse")])
  request = LLM.Request(
    model: MODEL,
    system: "Answer in one short sentence.",
    messages: [Ev.user("Say hello.")],
    max_tokens: some(32),
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

# A request without max_tokens leaves it to the server on the OpenAI APIs; anthropic, which needs one, sends its
# default. A given one is sent as it is.
def test_max_tokens_is_left_out_unless_given_except_on_anthropic() -> Result[Void]
  open = LLM.Request(model: MODEL, messages: [Ev.user("Hi.")])
  given = open.with(max_tokens: some(384_000))
  bodies = [
    try ChatWire.request_body(open),
    try ResponsesWire.request_body(open),
    try AnthropicWire.request_body(open),
    try ChatWire.request_body(given),
    try ResponsesWire.request_body(given),
    try AnthropicWire.request_body(given),
  ]

  limits = bodies.map { |body| limit_of(JSON.parse(body).unwrap!) }
  Test.eq(limits, ["", "", "64000", "384000", "384000", "384000"])
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

# An API that goes silent mid-stream fails the call after the read timeout, not after the time of a whole answer.
def test_a_stream_that_stalls_fails_after_its_read_timeout() -> Result[Void]
  stalling = (try Fake.sse("openai_chat/text.sse", piece_bytes: 64)).with(stall_after: 1024)
  fake = try Fake.start([stalling])
  provider = LLM.openai_chat(fake.url, KEY, LLM.Options(timeout_ms: 5000, read_timeout_ms: 300, tries: 1))
  started = Time.monotonic_ms
  call = try LLM.stream(provider, LLM.Request(model: MODEL, messages: [Ev.user("Say hello.")]))
  events = Ev.collect(call)
  result = Task.await(call.done)
  waited = Time.monotonic_ms - started
  try Fake.stop(fake)
  try Test.eq([Ev.kind(result), result.message], ["llm.network", "llm: the API sent nothing for 300 ms"])
  try Test.assert(waited < 5000, "it waited #{waited} ms")
  Test.eq(events.empty?, false)
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
  fake = try Fake.start([cut, try Fake.json(200, "openai_chat/models.json")])
  shared = try LLM.transport(pool_size: 1)
  options = LLM.Options(transport: some(shared), timeout_ms: 1500, read_timeout_ms: 0, tries: 1)
  provider = LLM.openai_chat(fake.url, KEY, options)
  call = try LLM.stream(provider, LLM.Request(model: MODEL, messages: [Ev.user("Say hello.")]))
  result = LLM.response(call)
  models = LLM.models(provider)
  LLM.close_transport(shared)
  try Fake.stop(fake)
  try Test.eq(Ev.kind(result), "llm.protocol")
  Test.eq(models, ok([LLM.Model(id: MODEL, context: some(4096))]))
end

def test_cancel_stops_the_stream() -> Result[Void]
  fake = try Fake.start([try Fake.sse_long("openai_chat/reasoning.sse")])
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

def test_provider_requests_reuse_one_connection_and_decode_gzip() -> Result[Void]
  listener = try TCP.listen("127.0.0.1", 0)
  body = try Zlib.gzip(try Fake.fixture("openai_chat/models.json"))
  sse = try Fake.fixture("openai_chat/text.sse")
  finish: Channel[Bool] = Channel.new(1)
  peer = Task.spawn do serve_provider(listener, sse, body, finish) end
  shared = try LLM.transport(pool_size: 1)
  options = LLM.Options(transport: some(shared), timeout_ms: 1500, tries: 1)
  url = "http://127.0.0.1:#{TCP.local_port(listener)}/v1"
  provider = LLM.openai_chat(url, KEY, options)
  call = try LLM.stream(provider, LLM.Request(model: MODEL, messages: [Ev.user("Say hello.")]))
  _ = Ev.collect(call)
  try finish.send(true, 0)
  first = LLM.response(call)
  second = LLM.models(LLM.openai_chat(url, "another-key", options))
  LLM.close_transport(shared)
  TCP.close_listener(listener)
  try Task.await(peer)
  expected = [LLM.Model(id: MODEL, context: some(4096))]
  try Test.assert(first.ok?, first.message)
  Test.eq(second, ok(expected))
end

def test_cancelling_a_silent_stream_frees_the_only_pool_slot() -> Result[Void]
  hold: Channel[Bool] = Channel.new(1)
  stream = (try Fake.sse("openai_chat/text.sse")).with(hold: some(hold))
  fake = try Fake.start([stream, try Fake.json(200, "openai_chat/models.json")])
  shared = try LLM.transport(pool_size: 1)
  options = LLM.Options(transport: some(shared), timeout_ms: 1500, read_timeout_ms: 10_000, tries: 1)
  provider = LLM.openai_chat(fake.url, KEY, options)
  call = try LLM.stream(provider, LLM.Request(model: MODEL, messages: [Ev.user("Say hello.")]))
  LLM.cancel(call)
  result = LLM.models(provider)
  hold.close
  LLM.close_transport(shared)
  try Fake.stop(fake)
  try Test.eq(Ev.kind(LLM.response(call)), "llm.cancelled")
  Test.eq(result, ok([LLM.Model(id: MODEL, context: some(4096))]))
end

def test_a_stalled_error_releases_the_slot_before_retrying_a_slow_head() -> Result[Void]
  hold: Channel[Bool] = Channel.new(1)
  rejected = Fake.Reply(status: 429, body: "rate limited".bytes, hold: some(hold))
  answered = (try Fake.sse("openai_chat/text.sse", piece_bytes: 0)).with(head_wait_ms: 150)
  fake = try Fake.start([rejected, answered])
  shared = try LLM.transport(pool_size: 1)
  options = LLM.Options(transport: some(shared), timeout_ms: 1500, read_timeout_ms: 60, tries: 2, retry_base_ms: 1)
  provider = LLM.openai_chat(fake.url, KEY, options)
  opened = LLM.stream(provider, LLM.Request(model: MODEL, messages: [Ev.user("Say hello.")]))
  hold.close
  result = case opened
    ok(call) -> LLM.response(call)
    error(e) -> error(e)
  end

  LLM.close_transport(shared)
  try Fake.stop(fake)
  Test.assert(result.ok?, result.message)
end

def test_model_listing_has_its_own_body_idle_timeout() -> Result[Void]
  hold: Channel[Bool] = Channel.new(1)
  reply = (try Fake.json(200, "openai_chat/models.json")).with(hold: some(hold))
  fake = try Fake.start([reply])
  options = LLM.Options(timeout_ms: 1500, read_timeout_ms: 60, tries: 1)
  result = LLM.models(LLM.openai_chat(fake.url, KEY, options))
  hold.close
  try Fake.stop(fake)
  case result
    ok(_) -> error("expected the model listing to time out")
    error(e) ->
      try Test.eq(e.kind, "llm.network")
      Test.assert(e.message.include?("within 60 ms"), e.message)
  end
end

def test_a_generation_request_over_one_mib_is_refused_locally() -> Result[Void]
  provider = LLM.openai_chat("http://127.0.0.1:1/v1", KEY, LLM.Options(tries: 1))
  message = Ev.user("x" * 1_048_576)
  case LLM.stream(provider, LLM.Request(model: MODEL, messages: [message]))
    ok(call) ->
      LLM.cancel(call)
      error("expected the request body to be refused")
    error(e) -> Test.eq([e.kind, e.message], ["llm.invalid_request", "llm: the request body exceeds 1048576 bytes"])
  end
end

private

def serve_provider(listener: TCP.Listener, sse: Bytes, models: Bytes, finish: Channel[Bool]) -> Result[Void]
  socket = try TCP.accept(listener, 1500)
  try Test.eq((try TCP.read_line(socket, 1500)).strip, "POST /v1/chat/completions HTTP/1.1")
  sent = try peer_headers(socket)
  try Test.eq(sent.get("authorization"), some("Bearer #{KEY}"))
  remaining = try sent.get("content-length").unwrap_or("").to_i
  while remaining > 0
    piece = try TCP.recv_bytes(socket, remaining, 1500)
    return error("the provider request ended before its content length") if piece.empty?

    remaining = remaining - piece.size
  end

  try TCP.send(
    socket,
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n",
    1500,
  )

  try TCP.send(socket, "#{format("%x", sse.size)}\r\n", 1500)
  try TCP.send_bytes(socket, sse, 1500)
  try TCP.send(socket, "\r\n", 1500)
  _ = try finish.recv(1500)
  try TCP.send(socket, "0\r\n\r\n", 1500)
  try Test.eq((try TCP.read_line(socket, 1500)).strip, "GET /v1/models HTTP/1.1")
  headers = try peer_headers(socket)
  try Test.eq(headers.get("authorization"), some("Bearer another-key"))
  try Test.assert(headers.get("accept-encoding").unwrap_or("").include?("gzip"), headers.inspect)
  try peer_response(socket, "Content-Encoding: gzip", models)
  TCP.close(socket)
  ok()
end

def peer_headers(socket: TCP.Socket) -> Result[Map[String, String]]
  headers: Map[String, String] = {}
  while true
    line = (try TCP.read_line(socket, 1500)).strip
    break if line.empty?

    parts = line.split(":")
    headers = headers.put(parts[0].downcase, parts.drop(1).join(":").strip)
  end

  ok(headers)
end

def peer_response(socket: TCP.Socket, header: String, body: Bytes) -> Result[Void]
  try TCP.send(socket, "HTTP/1.1 200 OK\r\n#{header}\r\nContent-Length: #{body.size}\r\n\r\n", 1500)
  TCP.send_bytes(socket, body, 1500)
end

def limit_of(body: JSON.Value) -> String
  for name in ["max_tokens", "max_output_tokens"]
    case JSON.get(body, name)
      ok(value) -> return JSON.encode(value)
      error(_) -> nil
    end
  end

  ""
end

def provider(fake: Fake.Fake) -> LLM.Provider
  LLM.openai_chat(fake.url, KEY, LLM.Options(timeout_ms: 5000, retry_base_ms: 1))
end

# An Int field's schema has the 64-bit bounds, which OpenAI refuses as too large: both wires leave them out.
def test_int_bounds_too_large_for_the_provider_are_left_out() -> Result[Void]
  tool = LLM.Tool(name: "read_file", description: "Read a file.", input_schema: JSON.schema(ReadArgs))
  request = LLM.Request(model: MODEL, messages: [Ev.user("Hi.")], tools: [tool])
  parameters = (
    "{\"type\": \"object\", \"properties\": {\"path\": {\"type\": \"string\"}, " +
    "\"offset\": {\"anyOf\": [{\"type\": \"integer\"}, {\"type\": \"null\"}]}, " +
    "\"limit\": {\"anyOf\": [{\"type\": \"integer\"}, {\"type\": \"null\"}]}}, \"required\": [\"path\"]}"
  )

  chat = try ChatWire.request_body(request)
  responses = try ResponsesWire.request_body(request)
  try Test.eq(
    JSON.get(JSON.parse(chat).unwrap!, "tools"),
    JSON.parse(
      "[{\"type\": \"function\", \"function\": {\"name\": \"read_file\", " +
      "\"description\": \"Read a file.\", \"parameters\": #{parameters}}}]",
    ),
  )

  Test.eq(
    JSON.get(JSON.parse(responses).unwrap!, "tools"),
    JSON.parse(
      "[{\"type\": \"function\", \"name\": \"read_file\", " +
      "\"description\": \"Read a file.\", \"parameters\": #{parameters}}]",
    ),
  )
end
