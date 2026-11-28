## Owner-bound approval IDs: concurrent siblings and their parent ask at once, are answered out of order, and
## route to the right call. A deny never becomes an allow, the allowed call really runs, and a stranger or a stale
## id stays not found or resolved. A client that attaches while a child asks recovers it from the snapshot or the
## replay without confusing owners.

import Protocol from "pkg/protocol/protocol"
import Core from "../core"
import H from "support/harness"

# Two siblings and their parent ask `rm` at once. The test answers the second sibling first, denies the first
# sibling and the parent, and checks each named child and call got the right result: the allowed `rm` really ran
# (its file is gone, its `tool_finished` is ok), the denied ones never ran. IDs are distinct and owner-bound, the
# snapshot lists the child's ask with its owner, and the replay shows it with its provenance.
def test_concurrent_siblings_and_parent_route_by_owner() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(8)
  replies = ["spawn.sse", "text.sse", "bash_rm.sse", "bash_rm.sse", "bash_rm.sse", "text.sse", "text.sse", "text.sse"]
  H.using(H.Setup(replies: replies, registry: some(with_spawn(calls)))) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    host = try host_of(calls)
    first = try host.create.call(Core.NewChild())
    second = try host.create.call(Core.NewChild())
    try Test.assert(first != second, "the children share an id")
    try File.write_text("#{h.work}/open.txt", "gone\n")
    _ = try host.send.call(first, "Remove it.")
    _ = try host.send.call(second, "Remove it too.")
    _ = try H.send(h, parent, "Remove it as well.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    requests = approvals_of(a)
    try Test.eq(requests.size, 3)
    ids = requests.map { |r| r.approval_id }
    try Test.eq(ids.uniq.size, 3)
    by_session = requests.map { |r| r.session }
    try Test.assert(by_session.any? { |s| s.none? }, "the parent's own ask is missing")
    try Test.assert(by_session.include?(some(first)), "the first child's ask is missing")
    try Test.assert(by_session.include?(some(second)), "the second child's ask is missing")
    for request in requests
      if request.session.some?
        try Test.assert(request.approval_id.include?(":"), "a child ask is not owner-bound: #{request.approval_id}")
        try Test.assert(
          request.approval_id.start_with?(request.session.unwrap!),
          "a child ask does not name its owner: #{request.approval_id}",
        )
      end
    end

    # A client that attaches now recovers the child's ask from the snapshot, with its owner. The live stream
    # already showed each ask with its owner above (`approvals_of` came from it), and the parent file keeps the
    # child's id for a replay.
    snapshot = try H.session(h, parent)
    try Test.eq(snapshot.pending_approvals.size, 3)
    for request in requests
      try Test.assert(
        snapshot.pending_approvals.any? { |p| p.approval_id == request.approval_id and p.session == request.session },
        "the snapshot misses #{request.approval_id}",
      )
    end

    H.close(try H.subscribe(h, parent, some(snapshot.last_event_id)))
    first_ask = requests.select { |r| r.session == some(first) }[0]
    second_ask = requests.select { |r| r.session == some(second) }[0]
    own_ask = requests.select { |r| r.session.none? }[0]
    # Deliberately out of order: the second sibling first, then the first, then the parent.
    try Test.eq((try H.approve(h, parent, second_ask.approval_id, Protocol.Decision.Allow)).status, 200)
    try Test.eq((try H.approve(h, parent, first_ask.approval_id, Protocol.Decision.Deny)).status, 200)
    try Test.eq((try H.approve(h, parent, own_ask.approval_id, Protocol.Decision.Deny)).status, 200)
    a = try H.until(a, Protocol.EventKind.ApprovalResolved)
    a = try H.until(a, Protocol.EventKind.ApprovalResolved)
    a = try H.until(a, Protocol.EventKind.ApprovalResolved)
    _ = try H.idle(h, first)
    _ = try H.idle(h, second)
    _ = try H.idle(h, parent)
    a = try H.until(a, Protocol.EventKind.Usage)
    H.close(a)
    # The allowed sibling really ran: its file is gone and its finish is ok; the denied ones never ran.
    try Test.assert(not File.stat("#{h.work}/open.txt").ok?, "the allowed rm did not run")
    finished = finishes_of(a)
    allowed = finished.select { |f| f.session == some(second) }
    denied_first = finished.select { |f| f.session == some(first) }
    try Test.eq(allowed.size, 1)
    try Test.eq(denied_first.size, 1)
    try Test.eq([allowed[0].ok, denied_first[0].ok], [true, false])
    try Test.assert(denied_first[0].summary.include?("denied"), "the denied call: #{denied_first[0].summary}")
    try Test.assert((try File.read_text(H.session_file(h, parent))).include?(second), "the parent file keeps no child")
    # A stranger's route never answers a child's ask, an unknown id stays not found, and a late answer is resolved.
    stranger = try H.new_session(h)
    try Test.eq((try H.approve(h, stranger, second_ask.approval_id, Protocol.Decision.Deny)).status, 404)
    try Test.eq((try H.approve(h, parent, "a999", Protocol.Decision.Deny)).status, 404)
    late = try H.approve(h, parent, second_ask.approval_id, Protocol.Decision.Deny)
    try Test.eq(late.status, 409)
    late_own = try H.approve(h, parent, second_ask.approval_id, Protocol.Decision.Deny)
    Test.eq(late_own.status, 409)
  end
end

private

def with_spawn(calls: Channel[Core.Call]) -> Core.Registry = Core.registry() |> Core.add_tool(spawn_tool(calls))

def spawn_tool(calls: Channel[Core.Call]) -> Core.Tool
  Core.Tool(
    name: "spawn",
    description: "Gives the test its call, with its handle.",
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

def approvals_of(sub: H.Sub) -> List[Protocol.ApprovalRequested]
  found: List[Protocol.ApprovalRequested] = []
  for seen in sub.seen
    case seen.event
      Protocol.Event.ApprovalRequested(request) -> found = found.push(request)
      _ -> nil
    end
  end

  found
end

def finishes_of(sub: H.Sub) -> List[Protocol.ToolFinished]
  found: List[Protocol.ToolFinished] = []
  for seen in sub.seen
    case seen.event
      Protocol.Event.ToolFinished(done) -> found = found.push(done)
      _ -> nil
    end
  end

  found
end
