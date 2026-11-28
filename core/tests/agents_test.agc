## The built-in subagent tools (`agent`, `agent_send`, `agent_stop`): ordered waited answers, the roster and the
## provider and tool ceilings, the cap, `/stop` during a wait, the async wake, and the refused inputs. Each turn here
## runs its fixture alone, except for the children an `agent` call starts, which share identical replies.

import Protocol from "pkg/protocol/protocol"
import Agents from "../src/ext/agents"
import Core from "../core"
import Spec from "../src/tools/spec"
import H from "support/harness"

ANSWER = "Hello! It's a pleasure to meet you."

# `agent` with two tasks answers both in input order, and the parent's next request holds the answers but not the
# children's tool output.
def test_agent_with_two_tasks_answers_both_in_input_order() -> Result[Void]
  replies = ["agent_two.sse", "bash_echo.sse", "text.sse", "bash_echo.sse", "text.sse", "text.sse"]
  H.using(H.Setup(replies: replies, approvals: false)) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    for _i in 1..5
      _ = try H.next_request(h)
    end

    body = (try H.next_request(h)).body
    try Test.assert(body.include?(ANSWER), "the parent's next request holds no answer")
    alpha = body.index_of("build (local/").unwrap_or(-1)
    beta = body.index_of("plan (local/").unwrap_or(-1)
    try Test.assert(alpha >= 0 and beta > alpha, "the answers are not in input order")
    try Test.assert(body.include?(": end_turn"), "the answers name no stop reason")
    Test.assert(not body.include?("other"), "a child's tool output leaked into the parent's request")
  end
end

# A user profile runs on its own provider; a project profile stays on the session's.
def test_a_user_profile_runs_on_its_provider_and_a_project_profile_stays() -> Result[Void]
  try user_profile_runs_on_its_provider()
  project_profile_stays_on_the_sessions_provider()
end

def user_profile_runs_on_its_provider() -> Result[Void]
  replies = ["agent_other.sse", "text.sse", "text.sse"]
  setup = H.Setup(replies: replies, providers: ["other"], approvals: false, profiles: true)
  H.using(setup) do |h|
    try write("#{h.base}/config/finn/profiles/fast.md", "---\ndescription: quick\nmodel: other/small\n---\n")
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    _ = try H.next_request(h)
    try Test.eq((try H.next_request(h)).path.start_with?("/other/"), true)
    body = (try H.next_request(h)).body
    Test.assert(body.include?("fast (other/small): end_turn"), "no headed answer on the profile's provider")
  end
end

def project_profile_stays_on_the_sessions_provider() -> Result[Void]
  replies = ["agent_other.sse", "text.sse", "text.sse"]
  setup = H.Setup(replies: replies, providers: ["other"], approvals: false, profiles: true, skills: true)
  H.using(setup) do |h|
    dir = "#{h.work}/.finn/profiles"
    try write("#{dir}/fast.md", "---\ndescription: project model\nmodel: other/small\n---\n")
    parent = try H.new_session_in(h, h.work)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    _ = try H.next_request(h)
    try Test.eq((try H.next_request(h)).path.start_with?("/other/"), false)
    body = (try H.next_request(h)).body
    Test.assert(body.include?("fast (local/"), "no headed answer on the session's provider")
  end
end

# With cap 1 the children run one at a time: the second child's first tool call comes only after the first child's
# usage reached the parent.
def test_with_cap_1_the_children_run_one_at_a_time() -> Result[Void]
  replies = ["agent_two.sse", "bash_echo.sse", "text.sse@hold", "bash_echo.sse", "text.sse", "text.sse"]
  setup = H.Setup(replies: replies, approvals: false, subagents_max: 1)
  H.using(setup) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.ToolFinished)
    first = try child_of(a)
    H.release(h)
    second = try until_other_child(a, first)
    H.close(a)
    before = before_second(second, first)
    try Test.assert(before.any? { |s| is_usage(s) }, "the second child starts before the first child's usage")
    b = try H.subscribe(h, parent)
    b = try H.until(b, Protocol.EventKind.TurnFinished)
    H.close(b)
    body = (try H.session(h, parent)).history.map { |m| m.text }.join("\n")
    Test.assert(body.include?(ANSWER), "the serial children gave no answers")
  end
end

# `/stop` during a waited `agent` call ends the call and stops the children's turns, and they stay open.
def test_stop_during_a_wait_ends_the_call_and_stops_the_children() -> Result[Void]
  replies = ["agent_one.sse", "bash_echo.sse", "text.sse@hold"]
  H.using(H.Setup(replies: replies, approvals: false)) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.ToolFinished)
    child = try child_of(a)
    try Test.eq((try H.post(h, Protocol.stop_path(parent), "{}")).status, 200)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(H.stop_reason(a), "cancelled")
    idle = try H.idle(h, child)
    try Test.eq(idle.turn_id.none?, true)
    try Test.eq((try H.get(h, Protocol.session_path(child))).status, 200)
    Test.eq((try H.get(h, Protocol.session_path(parent))).status, 200)
  end
end

# `wait: false` answers with the ids, and the child's answer wakes the parent once it is idle. `max_rounds: 1` ends
# the parent's first turn right after the call, so the wake always starts a turn of its own instead of joining a
# running one.
def test_wait_false_answers_with_the_ids_and_the_answer_wakes_the_parent() -> Result[Void]
  replies = ["agent_one_nowait.sse", "text.sse", "text.sse"]
  setup = H.Setup(replies: replies, approvals: false, max_rounds: some(1))
  H.using(setup) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    b = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(b)
    try Test.eq(started_source(b), "extension")
    child = try child_from_file(h, parent)
    try Test.eq((try H.get(h, Protocol.session_path(child))).status, 200)
    texts = (try H.session(h, parent)).history.map { |m| m.text }
    try Test.assert(texts.any? { |t| t.include?(ANSWER) }, "the wake carried no answer")
    Test.assert(texts.any? { |t| t.include?("build (local/") }, "the wake has no headed answer")
  end
end

# A timed-out child stops its turn, and its result holds the part of the answer there is. The child's reply is
# delayed past the timeout, so no test waits for anything.
def test_a_timeout_stops_the_child_turn_and_keeps_a_partial_answer() -> Result[Void]
  replies = ["agent_one.sse", "text.sse@1500", "text.sse"]
  setup = H.Setup(replies: replies, approvals: false, subagent_timeout_ms: 500)
  H.using(setup) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    _ = try H.next_request(h)
    _ = try H.next_request(h)
    body = (try H.next_request(h)).body
    Test.assert(body.include?("timed out after 500 ms"), "the result names no timeout")
  end
end

# Refused inputs fail the call, not the turn: no task, an unknown profile, and a stranger's id.
def test_refused_inputs_fail_the_call() -> Result[Void]
  try refused_input("agent_bad_tasks.sse", "agent needs at least one task")
  try refused_input("agent_bad_profile.sse", "unknown profile")
  try refused_input("send_unknown.sse", "no child session")
  refused_input("stop_unknown.sse", "no child session")
end

def refused_input(fixture: String, complaint: String) -> Result[Void]
  H.using(H.Setup(replies: [fixture, "text.sse"], approvals: false)) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    _ = try H.next_request(h)
    Test.assert((try H.next_request(h)).body.include?(complaint), "no refusal of #{fixture}")
  end
end

# A waited follow-up after an async start gets its own answer, and a second waited follow-up does too: one watcher
# per child dispatches by turn, so no waiter is dropped and no wake is misdirected.
def test_async_then_two_waited_followups_each_get_an_answer() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "text.sse", "text.sse", "text.sse", "text.sse", "text.sse"]
  setup = H.Setup(replies: replies, registry: some(with_spawn(calls)), approvals: false)
  H.using(setup) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    host = try host_of(calls)
    turns: ATS[String, String] = ATS.new()
    waits: ATS[String, Address[Agents.Heard]] = ATS.new()
    wakes: ATS[String, String] = ATS.new()
    names: ATS[String, String] = ATS.new()
    roster: Fn[List[Agents.Profile]] = -> { [] }
    limits = Agents.Limits(max: 0, timeout_ms: 0)
    tools = Agents.tools(roster, limits, turns, waits, wakes, names)
    ctx = Spec.Context(
      root: h.work,
      env: ->(_name: String) { error("no env") },
      host: some(host),
      session: some(parent),
    )

    async_input = try JSON.parse("{\"tasks\": [{\"prompt\": \"Say hi.\"}], \"wait\": false}")
    child = (try tools[0].run.call(ctx, async_input)).strip()
    try Test.assert(not child.empty?, "async start gave no id")
    c = try H.subscribe(h, child)
    c = try H.until(c, Protocol.EventKind.TurnFinished)
    H.close(c)
    first_input = try JSON.parse("{\"id\": \"" + child + "\", \"text\": \"Again.\", \"wait\": true}")
    first = try tools[1].run.call(ctx, first_input)
    try Test.assert(first.include?(ANSWER), "the first waited follow-up got no answer: #{first}")
    second_input = try JSON.parse("{\"id\": \"" + child + "\", \"text\": \"Once more.\", \"wait\": true}")
    second = try tools[1].run.call(ctx, second_input)
    Test.assert(second.include?(ANSWER), "the second waited follow-up got no answer: #{second}")
  end
end

# An async batch that does not fit the cap starts nothing, so no started id is ever lost and no unknown child is
# left running.
def test_async_batch_over_cap_starts_nothing() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse"]
  setup = H.Setup(replies: replies, registry: some(with_spawn(calls)), approvals: false)
  H.using(setup) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    host = try host_of(calls)
    turns: ATS[String, String] = ATS.new()
    waits: ATS[String, Address[Agents.Heard]] = ATS.new()
    wakes: ATS[String, String] = ATS.new()
    names: ATS[String, String] = ATS.new()
    roster: Fn[List[Agents.Profile]] = -> { [] }
    limits = Agents.Limits(max: 1, timeout_ms: 0)
    tools = Agents.tools(roster, limits, turns, waits, wakes, names)
    ctx = Spec.Context(
      root: h.work,
      env: ->(_name: String) { error("no env") },
      host: some(host),
      session: some(parent),
    )

    input = try JSON.parse("{\"tasks\": [{\"prompt\": \"One.\"}, {\"prompt\": \"Two.\"}], \"wait\": false}")
    result = tools[0].run.call(ctx, input)
    case result
      ok(_) -> return error("an over-cap async batch started")
      error(e) -> try Test.assert(e.message.include?("at most 1"), "no cap: #{e.message}")
    end

    Test.assert(turns.keys().empty?, "an over-cap batch left a turn behind")
  end
end

# An empty profile means the session's own: `agent: ""` starts a child instead of refusing it.
def test_empty_profile_means_the_sessions_own() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "text.sse"]
  setup = H.Setup(replies: replies, registry: some(with_spawn(calls)), approvals: false)
  H.using(setup) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    host = try host_of(calls)
    turns: ATS[String, String] = ATS.new()
    waits: ATS[String, Address[Agents.Heard]] = ATS.new()
    wakes: ATS[String, String] = ATS.new()
    names: ATS[String, String] = ATS.new()
    roster: Fn[List[Agents.Profile]] = -> { [] }
    limits = Agents.Limits(max: 0, timeout_ms: 0)
    tools = Agents.tools(roster, limits, turns, waits, wakes, names)
    ctx = Spec.Context(
      root: h.work,
      env: ->(_name: String) { error("no env") },
      host: some(host),
      session: some(parent),
    )

    input = try JSON.parse("{\"tasks\": [{\"agent\": \"\", \"prompt\": \"Say hi.\"}], \"wait\": true}")
    text = try tools[0].run.call(ctx, input)
    Test.assert(text.include?(ANSWER), "an empty profile gave no answer: #{text}")
  end
end

# A child cannot start a grandchild: its handle refuses, so no waiter is ever needed past one level.
def test_a_child_cannot_start_a_grandchild() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(8)
  replies = ["spawn.sse", "text.sse", "spawn.sse", "text.sse"]
  setup = H.Setup(replies: replies, registry: some(with_spawn(calls)), approvals: false)
  H.using(setup) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    host = try host_of(calls)
    child = try host.create.call(Core.NewChild())
    c = try H.subscribe(h, child)
    _ = try host.send.call(child, "Go.")
    c = try H.until(c, Protocol.EventKind.TurnFinished)
    H.close(c)
    child_call = try calls.recv(5000)
    child_host = try host_of_call(child_call)
    refused = child_host.create.call(Core.NewChild())
    case refused
      ok(_) -> Test.assert(false, "a grandchild started")
      error(e) -> Test.assert(e.kind == Protocol.KIND_INVALID, "wrong kind: #{e.kind}")
    end
  end
end

# The child's provider request hides the subagent tools while the parent's offers them: the handle's grandchild
# refusal alone cannot prove the schema is not offered. The child runs on `other`, so its request is the one to
# `/other/`, found by path rather than by arrival order.
def test_child_request_hides_subagent_tools() -> Result[Void]
  replies = ["agent_other.sse", "text.sse", "text.sse"]
  setup = H.Setup(replies: replies, providers: ["other"], approvals: false, profiles: true)
  H.using(setup) do |h|
    try write("#{h.base}/config/finn/profiles/fast.md", "---\ndescription: quick\nmodel: other/small\n---\n")
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    first = try H.next_request(h)
    second = try H.next_request(h)
    third = try H.next_request(h)
    seen = [first, second, third]
    parents = seen.select { |r| not r.path.start_with?("/other/") }
    children = seen.select { |r| r.path.start_with?("/other/") }
    try Test.eq(children.size, 1)
    try Test.eq(parents.size, 2)
    for request in parents
      offered = tool_names(request.body)
      try Test.assert(offered.include?("agent"), "the parent request hides agent: #{offered.join(", ")}")
      try Test.assert(offered.include?("agent_send"), "the parent request hides agent_send")
      try Test.assert(offered.include?("agent_stop"), "the parent request hides agent_stop")
    end

    child_tools = tool_names(children[0].body)
    try Test.assert(not child_tools.include?("agent"), "the child request offers agent: #{child_tools.join(", ")}")
    try Test.assert(not child_tools.include?("agent_send"), "the child request offers agent_send")
    try Test.assert(not child_tools.include?("agent_stop"), "the child request offers agent_stop")
    Test.assert(not child_tools.empty?, "the child request offers no tools at all")
  end
end

# A waited child kept open by its timeout, later sent a follow-up with `wait: false`, wakes this session exactly
# once with the child's answer: the wake is owed to the async turn, not to the watcher the waited start
# registered. The child's first reply is delayed past the timeout, so the wait ends while the child is still
# running; the follow-up's reply is immediate, so the wake follows at once.
def test_waited_child_kept_open_then_sent_async_wakes_parent_once() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "text.sse@1500", "text.sse", "text.sse"]
  setup = H.Setup(replies: replies, registry: some(with_spawn(calls)), approvals: false)
  H.using(setup) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    host = try host_of(calls)
    turns: ATS[String, String] = ATS.new()
    waits: ATS[String, Address[Agents.Heard]] = ATS.new()
    wakes: ATS[String, String] = ATS.new()
    names: ATS[String, String] = ATS.new()
    roster: Fn[List[Agents.Profile]] = -> { [] }
    tools = Agents.tools(roster, Agents.Limits(max: 0, timeout_ms: 500), turns, waits, wakes, names)
    ctx = Spec.Context(
      root: h.work,
      env: ->(_name: String) { error("no env") },
      host: some(host),
      session: some(parent),
    )

    waited = try JSON.parse("{\"tasks\": [{\"prompt\": \"Say hi.\"}], \"wait\": true}")
    partial = try tools[0].run.call(ctx, waited)
    try Test.assert(partial.include?("timed out after 500 ms"), "no partial answer after the timeout: #{partial}")
    try Test.eq(names.keys().size, 1)
    child = names.keys()[0]
    followup = try JSON.parse("{\"id\": \"" + child + "\", \"text\": \"Again.\", \"wait\": false}")
    try Test.eq(try tools[1].run.call(ctx, followup), child)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(extension_wakes(a), 1)
    texts = (try H.session(h, parent)).history.map { |m| m.text }
    try Test.assert(texts.any? { |t| t.include?(ANSWER) }, "the wake carried no answer")
    Test.assert(texts.any? { |t| t.include?("build (local/") }, "the wake has no headed answer")
  end
end

# A child whose turn has ended since frees its cap slot at once: the cap counts running turns, not table entries,
# so a `/stop` that cancels the waiting call (which never cleans up) still lets the parent launch again. The stub
# host's child is always idle, so its expected turn is stale by definition.
def test_an_idle_child_with_an_expected_turn_frees_its_cap_slot() -> Result[Void]
  turns: ATS[String, String] = ATS.new()
  waits: ATS[String, Address[Agents.Heard]] = ATS.new()
  wakes: ATS[String, String] = ATS.new()
  names: ATS[String, String] = ATS.new()
  turns.put("child-1", "turn-1")
  roster: Fn[List[Agents.Profile]] = -> { [] }
  tools = Agents.tools(roster, Agents.Limits(max: 1, timeout_ms: 0), turns, waits, wakes, names)
  ctx = Spec.Context(
    root: "/tmp",
    env: ->(_name: String) { error("no env") },
    host: some(stub_host()),
    session: some("parent"),
  )

  input = try JSON.parse("{\"tasks\": [{\"prompt\": \"Say hi.\"}], \"wait\": false}")
  case tools[0].run.call(ctx, input)
    ok(_) -> return error("the stubbed create should fail")
    error(e) ->
      try Test.assert(not e.message.include?("at most 1"), "an idle child still holds its cap slot: #{e.message}")
  end

  Test.assert(turns.keys().empty?, "an idle child keeps its expected turn")
end

# `/stop` during a capped waited call still lets the parent launch again: the stopped child is idle, so the next
# call starts a new child instead of failing every task with the cap. The child's first answer is held, so the wait
# is still in flight when the stop lands.
def test_stop_during_wait_then_capped_parent_launches_again() -> Result[Void]
  replies = [
    "agent_one.sse", "bash_echo.sse", "text.sse@hold", "agent_one.sse", "bash_echo.sse", "text.sse", "text.sse",
  ]

  setup = H.Setup(replies: replies, approvals: false, subagents_max: 1)
  H.using(setup) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.ToolFinished)
    child = try child_of(a)
    try Test.eq((try H.post(h, Protocol.stop_path(parent), "{}")).status, 200)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    try Test.eq(H.stop_reason(a), "cancelled")
    idle = try H.idle(h, child)
    try Test.eq(idle.turn_id.none?, true)
    try Test.eq((try H.get(h, Protocol.session_path(child))).status, 200)
    H.release(h)
    _ = try H.send(h, parent, "Go again.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    history = (try H.session(h, parent)).history.map { |m| m.text }.join("\n")
    Test.assert(history.include?(ANSWER), "the capped parent gave no answer after the stop")
  end
end

private

# The child whose tool call the events name.
def child_of(a: H.Sub) -> Result[String]
  for seen in a.seen
    for child in option_list(child_session(seen))
      return ok(child)
    end
  end

  error("no child tool call yet")
end

def child_session(seen: H.Seen) -> Optional[String]
  case seen.event
    Protocol.Event.ToolStarted(started) -> started.session
    Protocol.Event.ToolFinished(done) -> done.session
    Protocol.Event.Usage(usage) -> usage.session
    _ -> none
  end
end

def is_usage(seen: H.Seen) -> Bool
  case seen.event
    Protocol.Event.Usage(_) -> true
    _ -> false
  end
end

# Reads the stream until another child's tool call starts, and gives all it read so far.
def until_other_child(a: H.Sub, first: String) -> Result[H.Sub]
  current = a
  while true
    for seen in current.seen
      for child in option_list(child_session(seen))
        return ok(current) if child != first
      end
    end

    current = try H.until(current, Protocol.EventKind.ToolStarted)
  end

  ok(current)
end

# The events before the second child's first tool call: the first child's usage is among them.
def before_second(second: H.Sub, first: String) -> List[H.Seen]
  for at in 0...second.seen.size
    for child in option_list(child_session(second.seen[at]))
      return second.seen.take(at).select { |s| child_session(s) == some(first) } if child != first
    end
  end

  []
end

# The child id the parent's file names besides its own: the forwarded events carry it.
def child_from_file(h: H.Harness, parent: String) -> Result[String]
  text = try File.read_text(H.session_file(h, parent))
  for piece in text.split("\"")
    return ok(piece) if piece.start_with?("s") and piece.include?("-") and piece.length < 20 and piece != parent
  end

  error("the parent's file names no child")
end

# The source of the last `turn_started`, `user` for a user's message.
def started_source(sub: H.Sub) -> String
  sources: List[String] = []
  for seen in sub.seen
    case seen.event
      Protocol.Event.TurnStarted(started) -> sources = sources.push(started.source.unwrap_or("user"))
      _ -> nil
    end
  end

  return "" if sources.empty?

  sources.last
end

def with_spawn(calls: Channel[Core.Call]) -> Core.Registry = Core.registry() |> Core.add_tool(spawn_tool(calls))

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
  host_of_call(call)
end

def host_of_call(call: Core.Call) -> Result[Core.Host] = call.host.to_result("the call has no host")

# The tool names a provider request offers, in either wire shape.
def tool_names(body: String) -> List[String]
  json = JSON.parse(body).unwrap_or(JSON.object({}))
  listed: List[JSON.Value] = JSON.list(JSON.get(json, "tools").unwrap_or(JSON.array([]))).unwrap_or([])
  listed.map { |tool| tool_name(tool) }
end

def tool_name(tool: JSON.Value) -> String
  case JSON.get(tool, "name")
    ok(name) -> return JSON.string(name).unwrap_or("")
    error(_) -> nil
  end

  case JSON.get(tool, "function")
    ok(function) -> JSON.string(JSON.get(function, "name").unwrap_or(JSON.from(""))).unwrap_or("")
    error(_) -> ""
  end
end

def write(path: String, text: String) -> Result[Void]
  try mkdirs(path.slice(0, path.length - path.split("/").last.length - 1))
  File.write_text(path, text)
end

def mkdirs(dir: String) -> Result[Void]
  return ok() if File.stat(dir).ok?

  try mkdirs(dir.slice(0, dir.length - dir.split("/").last.length - 1))
  Dir.mkdir(dir)
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end

# How many turns of `sub` an extension wake started.
def extension_wakes(sub: H.Sub) -> Int
  woken = 0
  for seen in sub.seen
    case seen.event
      Protocol.Event.TurnStarted(started) ->
        if started.source == some("extension")
          woken = woken + 1
        end

      _ -> nil
    end
  end

  woken
end

# A session handle whose child is always idle: its snapshots show no running turn.
def stub_host() -> Spec.Host
  Spec.Host(
    create: ->(_child: Spec.NewChild) { error("no child starts here") },
    send: ->(_id: String, _text: String) { error("no child sends here") },
    stop: ->(_id: String) { error("no child stops here") },
    delete: ->(_id: String) { ok() },
    snapshot: ->(id: String) { ok(idle_session(id)) },
    watch: ->(_id: String, _names: List[String], _handler: Fn[Spec.Seen, Void]) { ok() },
  )
end

def idle_session(id: String) -> Protocol.Session
  Protocol.Session(
    id: id,
    cwd: "/tmp",
    model: "m",
    last_event_id: 0,
    turn_id: none,
    turn_from_event_id: none,
    pending_approvals: [],
    history: [],
  )
end
