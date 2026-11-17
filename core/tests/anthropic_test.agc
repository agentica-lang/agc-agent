# A session on the Anthropic Messages API: the prompt cache is asked for (the system prompt and the tools, and the
# conversation so far), the thinking blocks go back unchanged with their signatures across rounds and turns, and the
# usage counts the cache.

import Protocol from "pkg/protocol/protocol"
import Fake from "support/fake_llm"
import H from "support/harness"

MODEL = "qwen2.5-0.5b-instruct"

def test_a_session_on_anthropic_caches_and_keeps_its_thinking() -> Result[Void]
  H.using(H.Setup(api: "anthropic", replies: ["thinking_tool_use.sse", "text.sse", "text.sse"])) do |h|
    try File.write_text("#{h.work}/README.md", "# Readme\n")
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Read the README.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    usage = a.seen.select { |s| Protocol.event_name(s.event) == "usage" }.map { |s| H.untimed(s.event) }
    _ = try H.send(h, id, "Thanks.")
    a = try H.until(a.with(seen: []), Protocol.EventKind.TurnFinished)
    H.close(a)
    first = try H.next_request(h)
    try Test.eq([first.method, first.path], ["POST", "/v1/messages"])
    asked = try JSON.parse(first.body)
    try Test.eq(JSON.encode(try JSON.get(asked, "cache_control")), "{\"type\":\"ephemeral\"}")
    system = try JSON.at(try JSON.get(asked, "system"), 0)
    try Test.eq(JSON.encode(try JSON.get(system, "cache_control")), "{\"type\":\"ephemeral\"}")
    _ = try H.next_request(h)
    third = try JSON.parse((try H.next_request(h)).body)
    messages = try JSON.list(try JSON.get(third, "messages"))
    try Test.eq(messages.map { |m| text(m, "role") }, ["user", "assistant", "user", "assistant", "user"])
    blocks = try JSON.list(try JSON.get(messages[1], "content"))
    try Test.eq(blocks.map { |b| text(b, "type") }, ["thinking", "redacted_thinking", "text", "tool_use"])
    try Test.eq(text(blocks[0], "signature"), "EqQBCkYIBxgCKkBhandMadeSignature==")
    try Test.eq(text(blocks[1], "data"), "EmwKAhandMadeRedacted==")
    cached = Protocol.Usage(
      input: 12,
      output: 45,
      cache_read: 2000,
      cache_write: 300,
      context: 2312,
      window: some(1_000_000),
      call_output: some(45),
    )

    Test.eq(usage.take(1), [Protocol.Event.Usage(cached)])
  end
end

# Inside a tool round past the limit Anthropic does not fold: the rest of the turn sends no thinking blocks, and the
# session keeps them. The next turn folds at its start.
def test_anthropic_folds_only_between_turns() -> Result[Void]
  replies = ["thinking_tool_use.sse", "text_large.sse", "text.sse", "text.sse"]
  H.using(H.Setup(api: "anthropic", context_window: 100, replies: replies)) do |h|
    try File.write_text("#{h.work}/README.md", "# Readme\n")
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Read the README.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    _ = try H.send(h, id, "Again.")
    a = try H.until(a.with(seen: []), Protocol.EventKind.TurnFinished)
    H.close(a)
    _ = try H.next_request(h)
    second = try messages_of(h)
    try Test.eq(second.map { |m| types(m) }, [["text"], ["text", "tool_use"], ["tool_result"]])
    summary = try messages_of(h)
    try Test.eq(summary.size, 1)
    after = try messages_of(h)
    try Test.assert(JSON.encode(JSON.from(after)).include?("Summary of the session so far"), "not folded")
    Test.eq(after.flat_map { |m| types(m) }.select { |t| t.include?("thinking") }, [])
  end
end

# A turn that stripped its thinking blocks leaves the session stripped until a fold: after a failed summary, and
# after a
# restart, the requests still go without them.
def test_a_stripped_session_stays_stripped_until_a_fold() -> Result[Void]
  replies = ["thinking_tool_use.sse", "text_large.sse", "400:unauthorized.json", "text.sse", "text.sse"]
  setup = H.Setup(api: "anthropic", context_window: 100, replies: replies)
  H.using(setup) do |h|
    try File.write_text("#{h.work}/README.md", "# Readme\n")
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Read the README.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    _ = try H.send(h, id, "Again.")
    a = try H.until(a.with(seen: []), Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(H.stop_reason(a), "end_turn")
    for _i in 1..3
      _ = try H.next_request(h)
    end

    after_failed = try messages_of(h)
    try Test.eq(thinking(after_failed), [])
    H.restarted(h, setup, "") do |r|
      b = try H.subscribe(r, id)
      _ = try H.send(r, id, "Once more.")
      b = try H.until(b, Protocol.EventKind.TurnFinished)
      H.close(b)
      Test.eq(thinking(try messages_of(r)), [])
    end
  end
end

# A token fetched again stays with the session: the next turn's summary call carries it.
def test_a_fresh_token_stays_for_the_next_calls() -> Result[Void]
  replies = ["401:unauthorized.json", "text_large.sse", "text.sse", "text.sse"]
  H.using(H.Setup(api: "anthropic", fresh_token: "fresh", context_window: 100, replies: replies)) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Hi.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    _ = try H.send(h, id, "Again.")
    a = try H.until(a.with(seen: []), Protocol.EventKind.TurnFinished)
    H.close(a)
    _ = try H.next_request(h)
    _ = try H.next_request(h)
    summary = try H.next_request(h)
    try Test.eq((try JSON.list(try JSON.get(try JSON.parse(summary.body), "messages"))).size, 1)
    Test.eq(
      [header(summary, "authorization"), header(try H.next_request(h), "authorization")],
      ["Bearer fresh", "Bearer fresh"],
    )
  end
end

# After a 401 the token is fetched again once, and the call is made again with it.
def test_a_401_fetches_the_token_again() -> Result[Void]
  setup = H.Setup(api: "anthropic", fresh_token: "fresh", replies: ["401:unauthorized.json", "text.sse"])
  H.using(setup) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Hi.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(H.stop_reason(a), "end_turn")
    try Test.eq(header(try H.next_request(h), "x-api-key"), "test-key")
    Test.eq(header(try H.next_request(h), "authorization"), "Bearer fresh")
  end
end

# A session without a model takes its API's: on an Anthropic server an OpenAI session gets `default`; on an OpenAI
# server an Anthropic session gets Claude Opus 5.5 and a Responses one the server's model.
def test_a_session_takes_the_model_of_its_api() -> Result[Void]
  try H.using(H.Setup(api: "anthropic", replies: [])) do |h|
    id = try H.new_session_in(h, h.work, some("openai"))
    Test.eq((try H.session(h, id)).model, "default")
  end

  H.using(H.Setup(replies: [])) do |h|
    claude = try H.new_session_in(h, h.work, some("anthropic"))
    responses = try H.new_session_in(h, h.work, some("openai_responses"))
    Test.eq([(try H.session(h, claude)).model, (try H.session(h, responses)).model], ["claude-opus-5-5", MODEL])
  end
end

# Anthropic is never local: its window comes from `GET /models`, never `/props` (which would get `FINN_API_KEY`).
def test_anthropic_never_asks_props() -> Result[Void]
  setup = H.Setup(api: "anthropic", context_window: 0, props: true, replies: ["models.json", "text.sse"])
  H.using(setup) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Hi.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    Test.eq([(try H.next_request(h)).path, (try H.next_request(h)).path], ["/v1/models", "/v1/messages"])
  end
end

# `FINN_COMPACT_MODEL` names a model of the server's API: a session on another API folds with its own model.
def test_the_compact_model_is_for_the_server_api_only() -> Result[Void]
  replies = ["anthropic/text_large.sse", "anthropic/text.sse", "anthropic/text.sse"]
  setup = H.Setup(compact_model: "cheap", context_window: 100, replies: replies)
  H.using(setup) do |h|
    id = try H.new_session_in(h, h.work, some("anthropic"))
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Hi.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    _ = try H.send(h, id, "Again.")
    a = try H.until(a.with(seen: []), Protocol.EventKind.TurnFinished)
    H.close(a)
    _ = try H.next_request(h)
    summary = try JSON.parse((try H.next_request(h)).body)
    Test.eq(text(summary, "model"), "claude-opus-5-5")
  end
end

# After a move from Anthropic to a provider of the Responses API, no thinking block of Anthropic is sent.
def test_a_move_from_anthropic_leaves_the_thinking_behind() -> Result[Void]
  replies = ["thinking_tool_use.sse", "text.sse", "openai_responses/text.sse"]
  H.using(H.Setup(api: "anthropic", replies: replies, providers: ["other:openai_responses"])) do |h|
    try File.write_text("#{h.work}/README.md", "# Readme\n")
    id = try H.new_session(h)
    _ = try H.send(h, id, "Read the README.")
    _ = try H.idle(h, id)
    change = Protocol.encode_update_session(Protocol.UpdateSession(provider: some("other"), model: some("m1")))
    try Test.eq((try H.call(h, "PATCH", Protocol.session_path(id), change, H.auth(h))).status, 200)
    _ = try H.send(h, id, "Thanks.")
    _ = try H.idle(h, id)
    _ = try H.next_request(h)
    _ = try H.next_request(h)
    third = try H.next_request(h)
    try Test.eq(third.path, "/other/responses")
    input = try JSON.list(try JSON.get(try JSON.parse(third.body), "input"))
    Test.eq(input.map { |i| text(i, "type") }.uniq.sort, ["function_call", "function_call_output", "message"])
  end
end

def messages_of(h: H.Harness) -> Result[List[JSON.Value]]
  JSON.list(try JSON.get(try JSON.parse((try H.next_request(h)).body), "messages"))
end

def thinking(messages: List[JSON.Value]) -> List[String]
  messages.flat_map { |m| types(m) }.select { |t| t.include?("thinking") }
end

def types(message: JSON.Value) -> List[String]
  case JSON.list(JSON.get(message, "content").unwrap_or(JSON.null()))
    ok(blocks) -> blocks.map { |b| text(b, "type") }
    error(_) -> ["text"]
  end
end

def header(seen: Fake.Seen, name: String) -> String
  seen.headers.select { |h| h.name.downcase == name }.map { |h| h.value }.join(",")
end

def text(json: JSON.Value, key: String) -> String
  JSON.string(JSON.get(json, key).unwrap_or(JSON.null())).unwrap_or("")
end
