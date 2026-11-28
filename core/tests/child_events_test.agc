## Children on their parent's stream: a child's tool, approval and usage events reach the parent's stream with
## the child's id, and nothing else does. A child's approval is answered on the parent's route, the parent's session
## allows count for the child (but its accept-edits mode does not), a child's asks wait while the parent is watched,
## and the child's cost adds to the parent's sums while the parent keeps its own context.

import HTTP from "std/http"
import Protocol from "pkg/protocol/protocol"
import Catalog from "../src/providers/catalog"
import Core from "../core"
import Fake from "support/fake_llm"
import H from "support/harness"

## Prices of `gpt-5.1` in the pinned copy, in USD per million tokens: input 1.25, output 10.
CALL_COST = (100.0 * 1.25 + 20.0 * 10.0) / 1_000_000.0
TEXT_COST = (22.0 * 1.25 + 11.0 * 10.0) / 1_000_000.0

## The answer of `text.sse`.
ANSWER = "Hello! It's a pleasure to meet you."

# A child's `bash` asks on the parent's stream, and a deny there reaches the child: its turn ends without running
# the command. The parent's stream replays the child's calls with its id, saves them in its own file, and sums the
# child's cost into its own sums, while its context stays its own. The child's answer text never shows there.
def test_a_child_ask_is_denied_on_the_parent_stream_and_sums_its_cost() -> Result[Void]
  within_models do |served, dir|
    calls: Channel[Core.Call] = Channel.new(4)
    catalog = Catalog.start(Catalog.Options(url: served.url, cache: "#{dir}/models.json"))
    setup = H.Setup(
      replies: ["spawn.sse", "text.sse", "bash_rm.sse", "text.sse"],
      model: "gpt-5.1",
      catalog: some(catalog),
      registry: some(with_spawn(calls)),
    )

    result = H.using(setup) do |h|
      parent = try H.new_session(h)
      a = try H.subscribe(h, parent)
      _ = try H.send(h, parent, "Go.")
      a = try H.until(a, Protocol.EventKind.TurnFinished)
      before = (try H.session(h, parent)).cost
      host = try host_of(calls)
      child = try host.create.call(Core.NewChild())
      _ = try host.send.call(child, "Remove it.")
      a = try H.until(a, Protocol.EventKind.ApprovalRequested)
      asked = try H.approval(a)
      try Test.eq(asked.session, some(child))
      try Test.eq(asked.tool, "bash")
      try Test.eq((try H.approve(h, parent, asked.approval_id, Protocol.Decision.Deny)).status, 200)
      a = try H.until(a, Protocol.EventKind.ApprovalResolved)
      try Test.eq(H.resolved_by(a), ["deny client"])
      _ = try H.idle(h, child)
      a = try H.until(a, Protocol.EventKind.Usage)
      H.close(a)
      child_texts = H.said((try H.session(h, child)).history).map { |m| m.text }
      try Test.assert(child_texts.any? { |t| t.include?("Hello!") }, "the child did not go on after the deny")

      # The parent keeps its own answer only: the child's identical answer text is never added to its history.
      try Test.eq(H.said((try H.session(h, parent)).history).map { |m| m.text }, ["Go.", ANSWER])
      try Test.eq(text_deltas(a), 10)
      forwarded = a.seen.select { |s| child_session(s) == some(child) }
      # The child's cost adds to the parent's running sums: its 20 output tokens come on top of the parent's 31.
      try Test.eq(usages(forwarded), ["100 51 0 0 22", "22 62 0 0 22"])
      # The parent's own two calls stay without a child, and the file keeps the child's id for a replay.
      try Test.eq(usages(a.seen.select { |s| child_session(s).none? }), ["100 20 0 0 100", "22 31 0 0 22"])
      try Test.assert(
        (try File.read_text(H.session_file(h, parent))).include?(child),
        "the parent file keeps no child",
      )

      last = (try H.session(h, parent)).usage
      try Test.eq(last.map { |u| [u.output, u.context] }, some([62, 22]))
      try near([last.map { |u| u.session_cost }.unwrap_or(none)], [some(2.0 * (CALL_COST + TEXT_COST))])
      try near([before], [some(CALL_COST + TEXT_COST)])
      replayed = try H.until(try H.subscribe(h, parent, some(0)), Protocol.EventKind.TurnFinished)
      H.close(replayed)
      try Test.assert(
        replayed.seen.any? { |s|
          case s.event
            Protocol.Event.ApprovalRequested(request) -> request.session == some(child)
            _ -> false
          end
        },
        "the replay shows no child approval",
      )

      ok()
    end

    Catalog.stop(catalog)
    try result
    ok()
  end
end

# The parent's session allow lets the child's same call run without asking again.
def test_the_parent_session_allow_runs_the_child_same_call() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "bash.sse", "text.sse", "bash.sse", "text.sse"]
  H.using(H.Setup(replies: replies, registry: some(with_spawn(calls)))) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    _ = try H.send(h, parent, "Run that command.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    asked = try H.approval(a)
    try Test.eq(asked.session, none)
    answer = try H.approve(h, parent, asked.approval_id, Protocol.Decision.AllowSession)
    try Test.eq(answer.status, 200)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    marked = a.seen.size
    host = try host_of(calls)
    child = try host.create.call(Core.NewChild())
    _ = try host.send.call(child, "Run that command.")
    _ = try H.idle(h, child)
    a = try H.until(a, Protocol.EventKind.Usage)
    a = try H.until(a, Protocol.EventKind.Usage)
    H.close(a)
    fresh = a.seen.drop(marked)
    try Test.eq(fresh.select { |s| child_session(s) == some(child) and is_requested(s) }.size, 0)
    try Test.eq(fresh.select { |s| is_started(s, child) }.size, 1)
    try Test.eq(fresh.select { |s| is_finished(s, child) }.size, 1)
    Test.eq(fresh.select { |s| child_session(s) == some(child) and is_usage(s) }.size, 2)
  end
end

# The accept-edits mode stays with the parent: the child's edit still asks on the parent's stream.
def test_accept_edits_stays_with_the_parent() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "write_file.sse", "text.sse"]
  H.using(H.Setup(replies: replies, registry: some(with_spawn(calls)))) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    change = Protocol.encode_update_session(Protocol.UpdateSession(accept_edits: some(true)))
    try Test.eq((try H.call(h, "PATCH", Protocol.session_path(parent), change, H.auth(h))).status, 200)
    try Test.eq((try H.session(h, parent)).accept_edits, true)
    host = try host_of(calls)
    child = try host.create.call(Core.NewChild())
    try Test.eq((try host.snapshot.call(child)).accept_edits, false)
    _ = try host.send.call(child, "Write it.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    asked = try H.approval(a)
    try Test.eq(asked.session, some(child))
    try Test.eq(asked.tool, "write_file")
    try Test.eq((try H.approve(h, parent, asked.approval_id, Protocol.Decision.Deny)).status, 200)
    a = try H.until(a, Protocol.EventKind.ApprovalResolved)
    _ = try H.idle(h, child)
    H.close(a)
    Test.eq(H.resolved_by(a), ["deny client"])
  end
end

# A child's ask waits while a client watches the parent: the child's own quiet does not time it out. This waits
# past the timeout, since the absence of a timeout is the behavior under test.
def test_a_child_ask_waits_while_the_parent_is_watched() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  setup = H.Setup(
    replies: ["spawn.sse", "text.sse", "bash_rm.sse", "text.sse"],
    registry: some(with_spawn(calls)),
    approval_timeout_ms: 500,
  )

  H.using(setup) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    host = try host_of(calls)
    child = try host.create.call(Core.NewChild())
    _ = try host.send.call(child, "Remove it.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    Task.sleep(1200)
    try Test.eq(H.resolved_by(a), [])
    asked = try H.approval(a)
    try Test.eq((try H.approve(h, parent, asked.approval_id, Protocol.Decision.Deny)).status, 200)
    a = try H.until(a, Protocol.EventKind.ApprovalResolved)
    _ = try H.idle(h, child)
    H.close(a)
    Test.eq(H.resolved_by(a), ["deny client"])
  end
end

# Two children ask, are answered and counted on the same parent stream, each under its own id; a late answer is
# resolved, not answered twice.
def test_two_children_answer_and_sum_on_the_parent_stream() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "bash_rm.sse", "text.sse", "bash_rm.sse", "text.sse"]
  H.using(H.Setup(replies: replies, registry: some(with_spawn(calls)))) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    host = try host_of(calls)
    first = try host.create.call(Core.NewChild())
    _ = try host.send.call(first, "Remove it.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    try Test.eq((try H.approve(h, parent, (try H.approval(a)).approval_id, Protocol.Decision.Deny)).status, 200)
    a = try H.until(a, Protocol.EventKind.ApprovalResolved)
    _ = try H.idle(h, first)
    second = try host.create.call(Core.NewChild())
    _ = try host.send.call(second, "Remove it too.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    asked = try H.approval(a)
    try Test.eq(asked.session, some(second))
    try Test.eq((try H.approve(h, parent, asked.approval_id, Protocol.Decision.Deny)).status, 200)
    a = try H.until(a, Protocol.EventKind.ApprovalResolved)
    _ = try H.idle(h, second)
    a = try H.until(a, Protocol.EventKind.Usage)
    H.close(a)
    try Test.eq(H.resolved_by(a), ["deny client", "deny client"])
    try Test.eq(requests_of(a, first).size, 1)
    try Test.eq(requests_of(a, second).size, 1)
    try Test.eq(usages(a.seen.select { |s| child_session(s) == some(first) }).size, 2)
    try Test.eq(usages(a.seen.select { |s| child_session(s) == some(second) }).size, 2)
    try Test.eq((try H.session(h, parent)).usage.map { |u| u.output }, some(93))
    late = try H.approve(h, parent, asked.approval_id, Protocol.Decision.Deny)
    Test.eq(late.status, 409)
  end
end

# Only the parent's own children answer through it: a stranger's approval and an unknown id stay not found, and a
# delete of the parent takes a child that waits for an answer.
def test_only_the_parent_children_answer_through_it() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "bash_rm.sse", "text.sse"]
  H.using(H.Setup(replies: replies, registry: some(with_spawn(calls)))) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    host = try host_of(calls)
    child = try host.create.call(Core.NewChild())
    _ = try host.send.call(child, "Remove it.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    asked = try H.approval(a)
    stranger = try H.new_session(h)
    try Test.eq((try H.approve(h, stranger, asked.approval_id, Protocol.Decision.Deny)).status, 404)
    try Test.eq((try H.approve(h, parent, "a999", Protocol.Decision.Deny)).status, 404)
    try Test.eq((try H.call(h, "DELETE", Protocol.session_path(parent), "", H.auth(h))).status, 200)
    H.close(a)
    try Test.eq((try H.get(h, Protocol.session_path(child))).status, 404)
    try Test.eq((try H.get(h, Protocol.session_path(parent))).status, 404)
    try Test.assert(not File.read_text(H.session_file(h, parent)).ok?, "the parent's file stays")
    Test.assert(not File.read_text(H.session_file(h, child)).ok?, "the child's file stays")
  end
end

private

struct Served
  url: String
end

# A models.dev server that answers at once from the pinned copy, for the prices of one test.
def within_models(body: Fn[Served, String, Result[Void]]) -> Result[Void]
  tmp = System.env("TMPDIR").unwrap_or("/tmp")
  dir = "#{tmp}/core-child-models-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  json = try Fake.fixture("models_dev/api.json")
  handler = ->(_request: HTTP.Request) { ok(HTTP.Response(status: 200, headers: [], body: json)) }
  http = try HTTP.serve("127.0.0.1", 0, HTTP.app(handler))
  result = body.call(Served(url: "http://127.0.0.1:#{HTTP.local_port(http)}/api.json"), dir)
  HTTP.close_server(http)
  _ = HTTP.wait(http)
  _ = Path.remove(dir)
  result
end

def with_spawn(calls: Channel[Core.Call]) -> Core.Registry = Core.registry() |> Core.add_tool(spawn_tool(calls))

# A tool that gives the test the call, with its handle.
def spawn_tool(calls: Channel[Core.Call]) -> Core.Tool
  Core.Tool(
    name: "spawn",
    description: "Gives the test its call.",
    input_schema: JSON.object({"type": JSON.from("object")}),
    asks: false,
    run: ->(call: Core.Call) {
      _ = calls.send(call, 1000)
      ok("ok")
    },
    target: ->(_call: Core.Call) { ok("") },
  )
end

def host_of(calls: Channel[Core.Call]) -> Result[Core.Host]
  call = try calls.recv(5000)
  call.host.to_result("the call has no host")
end

def child_session(seen: H.Seen) -> Optional[String]
  case seen.event
    Protocol.Event.ToolStarted(started) -> started.session
    Protocol.Event.ToolFinished(done) -> done.session
    Protocol.Event.ApprovalRequested(request) -> request.session
    Protocol.Event.Usage(usage) -> usage.session
    _ -> none
  end
end

def is_requested(seen: H.Seen) -> Bool
  case seen.event
    Protocol.Event.ApprovalRequested(_) -> true
    _ -> false
  end
end

def is_usage(seen: H.Seen) -> Bool
  case seen.event
    Protocol.Event.Usage(_) -> true
    _ -> false
  end
end

def is_started(seen: H.Seen, child: String) -> Bool
  case seen.event
    Protocol.Event.ToolStarted(started) -> started.session == some(child)
    _ -> false
  end
end

def is_finished(seen: H.Seen, child: String) -> Bool
  case seen.event
    Protocol.Event.ToolFinished(done) -> done.session == some(child)
    _ -> false
  end
end

def requests_of(sub: H.Sub, child: String) -> List[H.Seen]
  sub.seen.select { |s|
    case s.event
      Protocol.Event.ApprovalRequested(request) -> request.session == some(child)
      _ -> false
    end
  }
end

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

def text_deltas(sub: H.Sub) -> Int
  deltas = 0
  for s in sub.seen
    case s.event
      Protocol.Event.TextDelta(_) -> deltas = deltas + 1
      _ -> nil
    end
  end

  deltas
end

# Costs are sums of floats: equal to a billionth of a dollar.
def near(actual: List[Optional[Float]], expected: List[Optional[Float]]) -> Result[Void]
  message = "#{actual.inspect} is not #{expected.inspect}"
  try Test.eq(actual.size, expected.size)
  for i in 0...actual.size
    left = try actual[i].to_result(message)
    right = try expected[i].to_result(message)
    try Test.assert((left - right).abs < 0.000000001, message)
  end

  ok()
end
