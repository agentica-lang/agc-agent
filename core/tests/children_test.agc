## Child sessions (`Core.Host`): an extension tool starts a session of its own on another provider, watches it, sends
## to it and stops it. A child's answer wakes its parent, a child starts no sessions, and a stop or a delete of the
## parent reaches its children. Each turn here runs alone, so the fake's replies go in order.

import Protocol from "pkg/protocol/protocol"
import Core from "../core"
import Fake from "support/fake_llm"
import H from "support/harness"

## The answer of `text.sse`.
ANSWER = "Hello! It's a pleasure to meet you."

# The parent's tool gives the test its handle; the child, on `other`, answers, and its answer wakes the parent. The
# child's handle starts nothing, and the list shows only the parent.
def test_a_child_on_another_provider_answers_and_wakes_its_parent() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "spawn.sse", "text.sse", "text.sse"]
  setup = H.Setup(replies: replies, providers: ["other"], registry: some(with_spawn(calls)), approvals: false)
  H.using(setup) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    host = try host_of(calls)
    woke: Channel[String] = Channel.new(4)
    child = try host.create.call(Core.NewChild(provider: some("other"), model: some("m1")))
    try host.watch.call(child, ["turn_finished"], ->(seen: Core.Seen) { answered(host, parent, seen, woke) })
    _ = try host.send.call(child, "Say hi.")
    try Test.eq(woke.recv(5000), ok("true #{ANSWER}"))
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    paths = (1..5).to_a.map { |_| path_of(H.next_request(h)) }
    try Test.eq(paths.map { |path| path.start_with?("/other/") }, [false, false, true, true, false])
    try Test.assert(said(try H.session(h, parent)).include?("#{child} said: #{ANSWER}"), "the parent was not woken")
    child_call = try calls.recv(0)
    try Test.eq(child_call.session, child)
    refused = (try host_of_call(child_call)).create.call(Core.NewChild())
    try Test.eq(kind_of(refused), Protocol.KIND_INVALID)
    listed = (try H.get(h, Protocol.SESSIONS_PATH)).text
    Test.assert(listed.include?(parent) and not listed.include?(child), "the list: #{listed}")
  end
end

# The parent sends more and stops the child's turn; `/stop` of the parent stops it too, and the child stays. A
# delete of
# the parent deletes the child.
def test_a_parent_stops_and_deletes_its_children() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "text.sse@hold", "text.sse@hold"]
  H.using(H.Setup(replies: replies, registry: some(with_spawn(calls)), approvals: false)) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    host = try host_of(calls)
    child = try host.create.call(Core.NewChild())
    c = try H.subscribe(h, child)
    _ = try host.send.call(child, "More.")
    c = try H.until(c, Protocol.EventKind.TurnStarted)
    try Test.eq(host.stop.call(child), ok(true))
    c = try H.until(c, Protocol.EventKind.TurnFinished)
    try Test.eq(H.stop_reason(c), "cancelled")
    _ = try host.send.call(child, "Again.")
    c = try H.until(c, Protocol.EventKind.TurnStarted)
    try Test.eq((try H.post(h, "#{Protocol.session_path(parent)}/stop", "{}")).status, 200)
    c = try H.until(c, Protocol.EventKind.TurnFinished)
    H.close(c)
    # Both held replies go now: a release before would let the second one go at once.
    H.release(h)
    H.release(h)
    try Test.eq(H.stop_reason(c), "cancelled")
    try Test.eq((try H.session(h, child)).id, child)
    try Test.eq((try H.call(h, "DELETE", Protocol.session_path(parent), "", H.auth(h))).status, 200)
    try Test.eq((try H.get(h, Protocol.session_path(child))).status, 404)
    Test.assert(not File.read_text(H.session_file(h, child)).ok?, "the child's file stays")
  end
end

# A session wakes itself `FINN_WAKES_MAX` times per user message; a user message counts again.
def test_the_wakes_of_a_session_have_a_cap() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "text.sse", "text.sse", "text.sse"]
  H.using(H.Setup(replies: replies, registry: some(with_spawn(calls)), wakes_max: 1)) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    host = try host_of(calls)
    _ = try host.send.call(parent, "Wake.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    capped = host.send.call(parent, "Wake again.")
    _ = try H.send(h, parent, "Hi.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    _ = try host.send.call(parent, "Wake.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    Test.eq(kind_of(capped), Protocol.KIND_SESSION_BUSY)
  end
end

private

def with_spawn(calls: Channel[Core.Call]) -> Core.Registry = Core.registry() |> Core.add_tool(spawn_tool(calls))

# A tool that gives the test the call, with its handle.
def spawn_tool(calls: Channel[Core.Call]) -> Core.Tool
  Core.Tool(
    name: "spawn",
    description: "Gives the test its call.",
    input_schema: JSON.object({"type": JSON.from("object")}),
    asks: false,
    run: ->(call: Core.Call) { handed(calls, call) },
    target: ->(_call: Core.Call) { ok("") },
  )
end

def handed(calls: Channel[Core.Call], call: Core.Call) -> Result[String]
  try calls.send(call, 1000)
  ok("ok")
end

def host_of(calls: Channel[Core.Call]) -> Result[Core.Host] = host_of_call(try calls.recv(5000))

def host_of_call(call: Core.Call) -> Result[Core.Host] = call.host.to_result("the call has no host")

# A child's answer goes to its parent; a stopped turn wakes nobody.
def answered(host: Core.Host, parent: String, seen: Core.Seen, woke: Channel[String]) -> Void
  stop = JSON.string(JSON.get(seen.data, "stop_reason").unwrap_or(JSON.from(""))).unwrap_or("")
  return if stop != "end_turn"

  text = case host.snapshot.call(seen.session)
    ok(session) -> said(session).reverse.push("").first
    error(_) -> ""
  end

  sent = host.send.call(parent, "#{seen.session} said: #{text}")
  _ = woke.send("#{sent.ok?} #{text}", 0)
end

def said(session: Protocol.Session) -> List[String]
  session.history.select { |m| not m.thinking and m.tool.none? and m.stop.none? }.map { |m| m.text }
end

def path_of(seen: Result[Fake.Seen]) -> String
  case seen
    ok(request) -> request.path
    error(_) -> ""
  end
end

def kind_of[T](result: Result[T]) -> String
  case result
    ok(_) -> "ok"
    error(e) -> e.kind
  end
end
