# A session on the Anthropic Messages API: the prompt cache is asked for (the system prompt and the tools, and the
# conversation so far), the thinking blocks go back unchanged with their signatures across rounds and turns, and the
# usage counts the cache.

import Protocol from "pkg/protocol/protocol"
import H from "support/harness"

def test_a_session_on_anthropic_caches_and_keeps_its_thinking() -> Result[Void]
  H.using(H.Setup(api: "anthropic", replies: ["thinking_tool_use.sse", "text.sse", "text.sse"])) do |h|
    try File.write_text("#{h.work}/README.md", "# Readme\n")
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Read the README.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    usage = a.seen.select { |s| Protocol.event_name(s.event) == "usage" }.map { |s| s.event }
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
    cached = Protocol.Usage(input: 12, output: 45, cache_read: 2000, cache_write: 300, context: 2312)
    Test.eq(usage.take(1), [Protocol.Event.Usage(cached)])
  end
end

def text(json: JSON.Value, key: String) -> String
  JSON.string(JSON.get(json, key).unwrap_or(JSON.null())).unwrap_or("")
end
