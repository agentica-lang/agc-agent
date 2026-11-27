## Wakes (`Core.Host.send` to the session itself): a child's answer starts a turn of its idle parent, queued wakes
## neither count nor refuse, past the cap they park for the next user message, and no wake restarts a stopped parent.
## Each turn here runs alone, so the fake's replies go in order.

import Protocol from "pkg/protocol/protocol"
import Core from "../core"
import Config from "../src/config/config"
import Store from "../src/session/store"
import H from "support/harness"

# An idle parent woken by its child's answer starts a turn with the child's id as its source.
def test_an_idle_parent_starts_a_turn_on_its_child_answer() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "spawn.sse", "text.sse", "text.sse"]
  H.using(H.Setup(replies: replies, registry: some(with_spawn(calls)), approvals: false)) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    host = try host_of(calls)
    child = try host.create.call(Core.NewChild())
    _ = try host.send.call(child, "Say hi.")
    c = try H.subscribe(h, child)
    c = try H.until(c, Protocol.EventKind.TurnFinished)
    H.close(c)
    child_call = try calls.recv(5000)
    try Test.eq(child_call.session, some(child))
    child_host = try host_of_call(child_call)
    b = try H.subscribe(h, parent)
    woke = try child_host.send.call(parent, "the answer")
    try Test.assert(not woke.turn_id.empty?, "the wake did not start a turn")
    b = try H.until(b, Protocol.EventKind.TurnStarted)
    b = try H.until(b, Protocol.EventKind.TurnFinished)
    H.close(b)
    try Test.eq(started_source(b.seen), "child:#{child}")
    texts = H.said((try H.session(h, parent)).history).map { |m| m.text }
    Test.assert(texts.include?("the answer"), "the parent was not woken")
  end
end

# With the cap reached and the parent mid-turn, two wakes queue with no refusal; the running turn reads both.
def test_queued_wakes_neither_count_nor_refuse() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "text.sse", "text.sse@hold", "text.sse"]
  setup = H.Setup(replies: replies, registry: some(with_spawn(calls)), approvals: false, wakes_max: 1)
  H.using(setup) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    host = try host_of(calls)
    _ = try host.send.call(parent, "one")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    _ = try H.send(h, parent, "Again.")
    a = try H.until(a, Protocol.EventKind.TurnStarted)
    one = try host.send.call(parent, "two")
    two = try host.send.call(parent, "three")
    try Test.assert(one.message_id.some? and two.message_id.some?, "a queued wake was refused")
    try Test.assert(one.message_id != two.message_id, "the queued wakes share an id")
    H.release(h)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(started_sources(a.seen), ["user", "extension", "user"])
    Test.eq(delivered_ids(a.seen), [one.message_id.unwrap_or(""), two.message_id.unwrap_or("")])
  end
end

# A wake past the cap parks with an empty `turn_id`; the next user message takes it before its own.
def test_a_wake_past_the_cap_parks_for_the_next_user_message() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "text.sse", "text.sse"]
  setup = H.Setup(replies: replies, registry: some(with_spawn(calls)), approvals: false, wakes_max: 1)
  H.using(setup) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    host = try host_of(calls)
    _ = try host.send.call(parent, "one")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    parked = try host.send.call(parent, "two")
    try Test.eq(parked.turn_id, "")
    a = try H.until(a, Protocol.EventKind.MessageQueued)
    try Test.eq(queued_source(a.seen), "extension")
    try Test.eq((try H.session(h, parent)).turn_id, none)
    _ = try H.send(h, parent, "Hi.")
    a = try H.until(a, Protocol.EventKind.TurnStarted)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(started_sources(a.seen).last, "user")
    bodies: List[String] = []
    for _i in 1..4
      bodies = bodies.push((try H.next_request(h)).body)
    end

    carried = bodies[3]
    try Test.assert(carried.include?("two") and carried.include?("Hi."), "the user message did not carry the wake")
    Test.assert(
      carried.index_of("two").unwrap_or(1_000_000) < carried.index_of("Hi.").unwrap_or(-1),
      "the wake: #{carried}",
    )
  end
end

# An unfiltered watcher that wakes on every `turn_finished` does not restart a stopped parent: the wake parks.
def test_a_stopped_parent_is_not_restarted_by_a_watcher() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  woken: Channel[Result[Protocol.MessageAccepted]] = Channel.new(4)
  replies = ["spawn.sse", "text.sse@hold"]
  H.using(H.Setup(replies: replies, registry: some(with_spawn(calls)), approvals: false)) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnStarted)
    host = try host_of(calls)
    try host.watch.call(parent, ["turn_finished"], ->(seen: Core.Seen) { wake_again(host, parent, seen, woken) })
    stopped = try Protocol.decode_stopped((try H.post(h, Protocol.stop_path(parent), "{}")).text)
    try Test.eq(stopped.stopped, true)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    parked = try woken.recv(5000)
    try Test.eq(try parked, Protocol.MessageAccepted(turn_id: ""))
    try Test.eq((try H.session(h, parent)).turn_id, none)
    H.close(a)
    Test.eq(started_sources(a.seen), ["user"])
  end
end

# With no cap every wake starts a turn; a bad value fails at start.
def test_no_cap_wakes_without_limit_and_a_bad_value_fails() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "text.sse", "text.sse"]
  setup = H.Setup(replies: replies, registry: some(with_spawn(calls)), approvals: false, wakes_max: 0)
  try H.using(setup) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    host = try host_of(calls)
    one = try host.send.call(parent, "one")
    b = try H.subscribe(h, parent)
    b = try H.until(b, Protocol.EventKind.TurnFinished)
    H.close(b)
    two = try host.send.call(parent, "two")
    c = try H.subscribe(h, parent)
    c = try H.until(c, Protocol.EventKind.TurnFinished)
    H.close(c)
    try Test.assert(not one.turn_id.empty? and not two.turn_id.empty?, "a wake did not start a turn")
    Test.eq((try H.session(h, parent)).turn_id, none)
  end

  try Test.error?(Config.from_env(->(name) { wakes_env(name, "many") }))
  zero = try Config.from_env(->(name) { wakes_env(name, "0") })
  try Test.eq(zero.wakes_max, 0)
  missing = try Config.from_env(->(name) { no_wakes_env(name) })
  Test.eq(missing.wakes_max, 100)
end

# A child's host wakes only its parent: any other read or control of the parent stays `session.not_found`, as does
# every function on a stranger's session, while the child reads itself.
def test_a_child_host_wakes_only_its_parent() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(8)
  replies = ["spawn.sse", "text.sse", "spawn.sse", "text.sse", "text.sse"]
  H.using(H.Setup(replies: replies, registry: some(with_spawn(calls)), approvals: false)) do |h|
    parent = try H.new_session(h)
    stranger = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    host = try host_of(calls)
    child = try host.create.call(Core.NewChild())
    _ = try host.send.call(child, "Say hi.")
    c = try H.subscribe(h, child)
    c = try H.until(c, Protocol.EventKind.TurnFinished)
    H.close(c)
    child_call = try calls.recv(5000)
    try Test.eq(child_call.session, some(child))
    child_host = try host_of_call(child_call)
    b = try H.subscribe(h, parent)
    woke = try child_host.send.call(parent, "the answer")
    try Test.assert(not woke.turn_id.empty?, "the wake did not start a turn")
    b = try H.until(b, Protocol.EventKind.TurnStarted)
    b = try H.until(b, Protocol.EventKind.TurnFinished)
    H.close(b)
    try Test.eq(started_source(b.seen), "child:#{child}")
    try Test.eq((try child_host.snapshot.call(child)).id, child)
    try Test.eq(kind_of(child_host.snapshot.call(parent)), Protocol.KIND_SESSION_NOT_FOUND)
    watched = child_host.watch.call(parent, ["turn_finished"], ->(_s: Core.Seen) { nil })
    try Test.eq(kind_of(watched), Protocol.KIND_SESSION_NOT_FOUND)
    try Test.eq(kind_of(child_host.stop.call(parent)), Protocol.KIND_SESSION_NOT_FOUND)
    try Test.eq(kind_of(child_host.delete.call(parent)), Protocol.KIND_SESSION_NOT_FOUND)
    try Test.eq(kind_of(child_host.send.call(stranger, "Hi.")), Protocol.KIND_SESSION_NOT_FOUND)
    try Test.eq(kind_of(child_host.snapshot.call(stranger)), Protocol.KIND_SESSION_NOT_FOUND)
    try Test.eq((try H.get(h, Protocol.session_path(parent))).status, 200)
    try Test.eq((try H.get(h, Protocol.session_path(stranger))).status, 200)
    Test.eq((try H.session(h, parent)).turn_id, none)
  end
end

# An idle stop stops nothing and leaves the window closed: the next wake still starts a turn.
def test_an_idle_stop_leaves_the_window_closed() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "text.sse"]
  H.using(H.Setup(replies: replies, registry: some(with_spawn(calls)), approvals: false)) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    stopped = try Protocol.decode_stopped((try H.post(h, Protocol.stop_path(parent), "{}")).text)
    try Test.eq(stopped.stopped, false)
    host = try host_of(calls)
    b = try H.subscribe(h, parent)
    woke = try host.send.call(parent, "after idle stop")
    try Test.assert(not woke.turn_id.empty?, "an idle stop parked the next wake")
    b = try H.until(b, Protocol.EventKind.TurnStarted)
    b = try H.until(b, Protocol.EventKind.TurnFinished)
    H.close(b)
    Test.eq(started_source(b.seen), "extension")
  end
end

# A stop for a turn that is not running stops nothing and leaves the window closed.
def test_a_stale_stop_leaves_the_window_closed() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "text.sse"]
  H.using(H.Setup(replies: replies, registry: some(with_spawn(calls)), approvals: false)) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    stopped = try Protocol.decode_stopped((try H.post(h, Protocol.stop_path(parent), "{\"turn_id\": \"stale\"}")).text)
    try Test.eq(stopped.stopped, false)
    host = try host_of(calls)
    b = try H.subscribe(h, parent)
    woke = try host.send.call(parent, "after stale stop")
    try Test.assert(not woke.turn_id.empty?, "a stale stop parked the next wake")
    b = try H.until(b, Protocol.EventKind.TurnStarted)
    b = try H.until(b, Protocol.EventKind.TurnFinished)
    H.close(b)
    Test.eq(started_source(b.seen), "extension")
  end
end

# A real stop opens the window, an idle stop keeps it open, and the next user message closes it again.
def test_an_idle_stop_keeps_an_open_window_until_the_next_user_message() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse@hold", "text.sse", "text.sse"]
  H.using(H.Setup(replies: replies, registry: some(with_spawn(calls)), approvals: false)) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnStarted)
    host = try host_of(calls)
    stopped = try Protocol.decode_stopped((try H.post(h, Protocol.stop_path(parent), "{}")).text)
    try Test.eq(stopped.stopped, true)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    idle = try Protocol.decode_stopped((try H.post(h, Protocol.stop_path(parent), "{}")).text)
    try Test.eq(idle.stopped, false)
    b = try H.subscribe(h, parent)
    parked = try host.send.call(parent, "late")
    try Test.eq(parked.turn_id, "")
    b = try H.until(b, Protocol.EventKind.MessageQueued)
    H.close(b)
    _ = try H.send(h, parent, "Next.")
    c = try H.until(try H.subscribe(h, parent), Protocol.EventKind.TurnFinished)
    H.close(c)
    bodies: List[String] = []
    for _i in 1..3
      bodies = bodies.push((try H.next_request(h)).body)
    end

    carried = bodies[2]
    try Test.assert(carried.include?("late") and carried.include?("Next."), "the user message: #{carried}")
    d = try H.subscribe(h, parent)
    woke = try host.send.call(parent, "after")
    try Test.assert(not woke.turn_id.empty?, "the window stayed open past the user message")
    d = try H.until(d, Protocol.EventKind.TurnFinished)
    H.close(d)
    Test.eq(started_source(d.seen), "extension")
  end
end

# A parked wake survives a restart: the next user message carries it before its own, with its source on the queued
# event, and a second restart does not carry it again. Branching back after the user message takes it does not
# bring it back either.
def test_a_parked_wake_survives_a_restart_and_is_taken_once() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "text.sse", "text.sse", "text.sse"]
  setup = H.Setup(replies: replies, registry: some(with_spawn(calls)), approvals: false, wakes_max: 1)
  H.using(setup) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    host = try host_of(calls)
    _ = try host.send.call(parent, "one")
    _ = try H.idle(h, parent)
    parked = try host.send.call(parent, "two")
    try Test.eq(parked.turn_id, "")
    H.restarted(h, setup, "") do |r|
      saved = try Store.load(Store.Ref(port: Store.disk(), path: H.session_file(r, parent)))
      try Test.eq(saved.parked.map { |p| p.text }, ["two"])
      try Test.eq(saved.parked.map { |p| p.source }, ["extension"])
      b = try H.subscribe(r, parent)
      _ = try H.send(r, parent, "Hi.")
      b = try H.until(b, Protocol.EventKind.TurnStarted)
      b = try H.until(b, Protocol.EventKind.TurnFinished)
      H.close(b)
      try Test.eq(started_sources(b.seen).last, "user")
      bodies: List[String] = []
      for _i in 1..4
        bodies = bodies.push((try H.next_request(r)).body)
      end

      carried = bodies[3]
      try Test.assert(carried.include?("two") and carried.include?("Hi."), "the user message: #{carried}")
      try Test.assert(
        carried.index_of("two").unwrap_or(1_000_000) < carried.index_of("Hi.").unwrap_or(-1),
        "the wake: #{carried}",
      )

      H.restarted(r, setup, "") do |s|
        again = try Store.load(Store.Ref(port: Store.disk(), path: H.session_file(s, parent)))
        try Test.eq(again.parked, [])
        _ = try H.send(s, parent, "Again.")
        _ = try H.idle(s, parent)
        last = try last_user((try H.next_request(s)).body)
        try Test.eq(last, "Again.")
        nodes = try tree(s, parent)
        _ = try H.post(s, Protocol.branch_path(parent), Protocol.encode_branch(Protocol.Branch(entry: nodes[0].id)))
        _ = try H.send(s, parent, "Branched.")
        _ = try H.idle(s, parent)
        branched = try last_user((try H.next_request(s)).body)
        Test.eq(branched, "Branched.")
      end
    end
  end
end

# A parked wake waits with a shell's output: the next user message carries the shell first, then the wake.
def test_a_shell_output_and_a_parked_wake_reach_the_next_turn_in_order() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "text.sse", "text.sse"]
  setup = H.Setup(replies: replies, registry: some(with_spawn(calls)), approvals: false, wakes_max: 1)
  H.using(setup) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    host = try host_of(calls)
    _ = try host.send.call(parent, "one")
    _ = try H.idle(h, parent)
    parked = try host.send.call(parent, "two")
    try Test.eq(parked.turn_id, "")
    s = try H.subscribe(h, parent)
    shell = try shell(h, parent, "echo hi", true)
    try Test.eq(shell.status, 202)
    s = try H.until(s, Protocol.EventKind.ShellFinished)
    H.close(s)
    _ = try H.send(h, parent, "Hi.")
    _ = try H.idle(h, parent)
    bodies: List[String] = []
    for _i in 1..4
      bodies = bodies.push((try H.next_request(h)).body)
    end

    carried = bodies[3]
    hi = carried.index_of("hi").unwrap_or(1_000_000)
    two = carried.index_of("two").unwrap_or(1_000_000)
    said = carried.index_of("Hi.").unwrap_or(-1)
    try Test.assert(carried.include?("hi") and carried.include?("two"), "the turn: #{carried}")
    Test.assert(hi < two and two < said, "shell, wake, user: #{carried}")
  end
end

# A wake while a shell runs is refused as busy, and a child may wake itself with its own id.
def test_a_wake_during_a_shell_is_busy_and_a_child_may_wake_itself() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "spawn.sse", "text.sse", "text.sse"]
  H.using(H.Setup(replies: replies, registry: some(with_spawn(calls)), approvals: false)) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    host = try host_of(calls)
    _ = try shell(h, parent, "sleep 30", false)
    busy = host.send.call(parent, "while busy")
    try Test.eq(kind_of(busy), Protocol.KIND_SESSION_BUSY)
    _ = try H.post(h, Protocol.stop_path(parent), "{}")
    _ = try H.idle(h, parent)
    child = try host.create.call(Core.NewChild())
    _ = try host.send.call(child, "Say hi.")
    c = try H.subscribe(h, child)
    c = try H.until(c, Protocol.EventKind.TurnFinished)
    H.close(c)
    child_call = try calls.recv(5000)
    child_host = try host_of_call(child_call)
    me = try H.subscribe(h, child)
    woke = try child_host.send.call(child, "myself")
    try Test.assert(not woke.turn_id.empty?, "a child cannot wake itself")
    me = try H.until(me, Protocol.EventKind.TurnStarted)
    me = try H.until(me, Protocol.EventKind.TurnFinished)
    H.close(me)
    Test.eq(started_source(me.seen), "child:#{child}")
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
    run: ->(call: Core.Call) {
      _ = calls.send(call, 1000)
      ok("ok")
    },
    target: ->(_call: Core.Call) { ok("") },
  )
end

# An unfiltered watcher: every `turn_finished` wakes the session again, whatever stopped it.
def wake_again(
  host: Core.Host,
  parent: String,
  _seen: Core.Seen,
  woken: Channel[Result[Protocol.MessageAccepted]],
) -> Void
  _ = woken.send(host.send.call(parent, "again"), 0)
end

def host_of(calls: Channel[Core.Call]) -> Result[Core.Host] = host_of_call(try calls.recv(5000))

def host_of_call(call: Core.Call) -> Result[Core.Host] = call.host.to_result("the call has no host")

def kind_of[T](result: Result[T]) -> String
  case result
    ok(_) -> "ok"
    error(e) -> e.kind
  end
end

# The source of the last `turn_started`, `user` for a user's message.
def started_source(seen: List[H.Seen]) -> String
  sources = started_sources(seen)
  return "" if sources.empty?

  sources.last
end

def started_sources(seen: List[H.Seen]) -> List[String]
  sources: List[String] = []
  for one in seen
    case one.event
      Protocol.Event.TurnStarted(started) -> sources = sources.push(started.source.unwrap_or("user"))
      _ -> nil
    end
  end

  sources
end

# The `message_id`s the running turn read, in order (`message_delivered`, after the answer and the tool results).
def delivered_ids(seen: List[H.Seen]) -> List[String]
  ids: List[String] = []
  for one in seen
    case one.event
      Protocol.Event.MessageDelivered(delivered) ->
        for id in option_list(delivered.message_id)
          ids = ids.push(id)
        end

      _ -> nil
    end
  end

  ids
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end

def tree(h: H.Harness, id: String) -> Result[List[Protocol.TreeNode]]
  ok((try Protocol.decode_session_tree((try H.get(h, Protocol.tree_path(id))).text)).nodes)
end

# The last user message of a model request, which is the turn's own text with what it carries.
def last_user(body: String) -> Result[String]
  messages = try JSON.list(try JSON.get(try JSON.parse(body), "messages"))
  last = ""
  for message in messages
    role = JSON.string(JSON.get(message, "role").unwrap_or(JSON.null())).unwrap_or("")
    if role == "user"
      last = JSON.string(JSON.get(message, "content").unwrap_or(JSON.null())).unwrap_or(last)
    end
  end

  ok(last)
end

def shell(h: H.Harness, id: String, command: String, context: Bool) -> Result[H.Answer]
  H.post(h, Protocol.shell_path(id), Protocol.encode_run_shell(Protocol.RunShell(command: command, context: context)))
end

# The source of the last `message_queued` with an empty `turn_id` (a parked wake), "" when none.
def queued_source(seen: List[H.Seen]) -> String
  found = ""
  for one in seen
    case one.event
      Protocol.Event.MessageQueued(message) if message.turn_id.empty? -> found = message.source.unwrap_or("")
      _ -> nil
    end
  end

  found
end

def wakes_env(name: String, value: String) -> Result[String]
  return ok(value) if name == "FINN_WAKES_MAX"

  case name
    "FINN_STATE_DIR" -> ok("/state")
    "FINN_DATA_DIR" -> ok("/data")
    _ -> error("not set")
  end
end

def no_wakes_env(name: String) -> Result[String]
  return error("not set") if name == "FINN_WAKES_MAX"

  wakes_env(name, "")
end
