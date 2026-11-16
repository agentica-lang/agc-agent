import Protocol from "pkg/protocol/protocol"
import H from "support/harness"

# Each `usage` has the call's input and cache counts, their sum as the context, and the session's output so far, which
# goes on after a restart.
def test_usage_sums_the_output_of_the_session() -> Result[Void]
  setup = H.Setup(replies: ["write_file.sse", "text.sse", "text_cached.sse", "text.sse"])
  H.using(setup) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    _ = try H.send(h, id, "Again.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(usages(a.seen), ["100 20 0 0 100", "22 31 0 0 22", "30 38 120 0 150"])
    H.restarted(h, setup, "") do |r|
      b = try H.subscribe(r, id)
      _ = try H.send(r, id, "Once more.")
      b = try H.until(b, Protocol.EventKind.TurnFinished)
      H.close(b)
      Test.eq(usages(b.seen), ["22 49 0 0 22"])
    end
  end
end

# What a prompt cache needs: the system prompt and the tools are the same bytes on every call of a session, across
# turns, tool rounds and a restart (after which AGENTS.md changed), and the system prompt comes first.
def test_the_prompt_prefix_is_the_same_on_every_call() -> Result[Void]
  setup = H.Setup(replies: ["write_file.sse", "text.sse", "text.sse", "text.sse"])
  H.using(setup) do |h|
    try File.write_text("#{h.work}/AGENTS.md", "Use tabs.\n")
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    _ = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    _ = try H.send(h, id, "Again.")
    _ = try H.idle(h, id)
    try File.write_text("#{h.work}/AGENTS.md", "Use spaces.\n")
    H.restarted(h, setup, "") do |r|
      _ = try H.send(r, id, "Once more.")
      _ = try H.idle(r, id)
      prefixes: List[String] = []
      for _i in 1..4
        body = try JSON.parse((try H.next_request(r)).body)
        system = try JSON.at(try JSON.get(body, "messages"), 0)
        try Test.eq(JSON.get(system, "role"), ok(JSON.from("system")))
        try Test.assert(JSON.encode(system).include?("Use tabs."), "no AGENTS.md in the system prompt")
        prefixes = prefixes.push("#{JSON.encode(system)}\n#{JSON.encode(try JSON.get(body, "tools"))}")
      end

      Test.eq(prefixes.uniq.size, 1)
    end
  end
end

private

def usages(seen: List[H.Seen]) -> List[String]
  counts: List[String] = []
  for s in seen
    case s.event
      Protocol.Event.Usage(u) ->
        counts = counts.push("#{u.input} #{u.output} #{u.cache_read} #{u.cache_write} #{u.context}")
      _ -> nil
    end
  end

  counts
end
