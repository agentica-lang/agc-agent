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

# An async `agent` start whose child finishes before the wake is registered still wakes the parent exactly once:
# the send fires `turn_finished` at once, the wake carries the headed answer to the real parent, and a duplicate
# or stale turn after it wakes nothing and leaves no turn, waiter or wake behind.
def test_async_start_with_immediate_completion_wakes_once() -> Result[Void]
  setup = immediate()
  input = try JSON.parse("{\"tasks\": [{\"prompt\": \"Say hi.\"}], \"wait\": false}")
  try Test.eq(try setup.tools[0].run.call(setup.ctx, input), "child-1")
  check_immediate_wake(setup)
end

# An async `agent_send` whose child finishes before the post-send snapshot still wakes the parent exactly once:
# the send fires `turn_finished` at once, the wake carries the headed answer to the real parent, and a duplicate
# or stale turn after it wakes nothing and leaves no turn, waiter or wake behind.
def test_async_send_with_immediate_completion_wakes_once() -> Result[Void]
  setup = immediate()
  # A follow-up to a child the first call started keeps its recorded display name.
  setup.names.put("child-1", "build")
  input = try JSON.parse("{\"id\": \"child-1\", \"text\": \"Again.\", \"wait\": false}")
  try Test.eq(try setup.tools[1].run.call(setup.ctx, input), "child-1")
  check_immediate_wake(setup)
end

private

## A wake the immediate stub host recorded: the session it woke and the text it carried.
struct Woke
  id: String
  text: String
end

## Everything an immediate-completion run needs: the channels the stub host fires and records on, the handle, the
## subagent tables, the tools and the context of the parent.
struct Immediate
  handlers: Channel[Fn[Spec.Seen, Void]]
  woken: Channel[Woke]
  host: Spec.Host
  turns: ATS[String, String]
  waits: ATS[String, Address[Agents.Heard]]
  wakes: ATS[String, String]
  names: ATS[String, String]
  tools: List[Spec.Tool]
  ctx: Spec.Context
end

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

def immediate() -> Immediate
  handlers: Channel[Fn[Spec.Seen, Void]] = Channel.new(1)
  woken: Channel[Woke] = Channel.new(4)
  host = immediate_host(handlers, woken)
  turns: ATS[String, String] = ATS.new()
  waits: ATS[String, Address[Agents.Heard]] = ATS.new()
  wakes: ATS[String, String] = ATS.new()
  names: ATS[String, String] = ATS.new()
  tools = Agents.tools(-> { [] }, Agents.Limits(max: 0, timeout_ms: 0), turns, waits, wakes, names)
  ctx = Spec.Context(
    root: "/tmp",
    env: ->(_name: String) { error("no env") },
    host: some(host),
    session: some("parent"),
  )

  Immediate(
    handlers: handlers,
    woken: woken,
    host: host,
    turns: turns,
    waits: waits,
    wakes: wakes,
    names: names,
    tools: tools,
    ctx: ctx,
  )
end

# Everything a scripted run needs: the same tables, tools and context as `immediate`, on the given handle.
def rig_on(handlers: Channel[Fn[Spec.Seen, Void]], woken: Channel[Woke], host: Spec.Host) -> Immediate
  turns: ATS[String, String] = ATS.new()
  waits: ATS[String, Address[Agents.Heard]] = ATS.new()
  wakes: ATS[String, String] = ATS.new()
  names: ATS[String, String] = ATS.new()
  tools = Agents.tools(-> { [] }, Agents.Limits(max: 0, timeout_ms: 0), turns, waits, wakes, names)
  ctx = Spec.Context(
    root: "/tmp",
    env: ->(_name: String) { error("no env") },
    host: some(host),
    session: some("parent"),
  )

  Immediate(
    handlers: handlers,
    woken: woken,
    host: host,
    turns: turns,
    waits: waits,
    wakes: wakes,
    names: names,
    tools: tools,
    ctx: ctx,
  )
end

# A child that runs a second turn while its first turn's finish is still on its way: `send` fires the stale
# `turn_finished` before it answers, and answers with the live turn the snapshot already shows.
def stale_race() -> Immediate
  handlers: Channel[Fn[Spec.Seen, Void]] = Channel.new(1)
  woken: Channel[Woke] = Channel.new(4)
  rig_on(handlers, woken, stale_host(handlers, woken))
end

def stale_host(handlers: Channel[Fn[Spec.Seen, Void]], woken: Channel[Woke]) -> Spec.Host
  Spec.Host(
    create: ->(_child: Spec.NewChild) { ok("child-1") },
    send: ->(id: String, text: String) {
      if id == "child-1"
        fire_now(handlers, id, "turn-1")
        return ok(Protocol.MessageAccepted(turn_id: "turn-2"))
      end

      _ = woken.send(Woke(id: id, text: text), 1000)
      ok(Protocol.MessageAccepted(turn_id: "wake-turn"))
    },
    stop: ->(_id: String) { ok(false) },
    delete: ->(_id: String) { ok() },
    snapshot: ->(id: String) {
      return ok(running_child(id, "turn-2")) if id == "child-1"

      ok(immediate_parent(id))
    },
    watch: ->(_id: String, _names: List[String], handler: Fn[Spec.Seen, Void]) {
      _ = handlers.send(handler, 0)
      ok()
    },
  )
end

def running_child(id: String, turn: String) -> Protocol.Session
  Protocol.Session(
    id: id,
    cwd: "/tmp",
    model: "m",
    last_event_id: 0,
    turn_id: some(turn),
    turn_from_event_id: none,
    pending_approvals: [],
    history: [Protocol.Message(role: Protocol.Role.Assistant, text: ANSWER)],
    provider: "local",
  )
end

# A child whose send always fails while its snapshot still shows a live turn.
def failing_setup() -> Immediate
  handlers: Channel[Fn[Spec.Seen, Void]] = Channel.new(1)
  woken: Channel[Woke] = Channel.new(4)
  rig_on(handlers, woken, failing_host())
end

def failing_host() -> Spec.Host
  Spec.Host(
    create: ->(_child: Spec.NewChild) { ok("child-1") },
    send: ->(_id: String, _text: String) { error("the child is busy") },
    stop: ->(_id: String) { ok(false) },
    delete: ->(_id: String) { ok() },
    snapshot: ->(id: String) {
      return ok(running_child(id, "turn-2")) if id == "child-1"

      ok(immediate_parent(id))
    },
    watch: ->(_id: String, _names: List[String], _handler: Fn[Spec.Seen, Void]) { ok() },
  )
end

# A child whose stale finish a hung waiter still owns while an async send starts: `send` fires the stale finish
# before it answers, and the idle snapshot already holds an answer.
def hung_setup() -> Immediate
  handlers: Channel[Fn[Spec.Seen, Void]] = Channel.new(1)
  woken: Channel[Woke] = Channel.new(4)
  rig_on(handlers, woken, hung_host(handlers, woken))
end

def hung_host(handlers: Channel[Fn[Spec.Seen, Void]], woken: Channel[Woke]) -> Spec.Host
  Spec.Host(
    create: ->(_child: Spec.NewChild) { ok("child-1") },
    send: ->(id: String, text: String) {
      if id == "child-1"
        fire_now(handlers, id, "turn-1")
        return ok(Protocol.MessageAccepted(turn_id: "turn-2"))
      end

      _ = woken.send(Woke(id: id, text: text), 1000)
      ok(Protocol.MessageAccepted(turn_id: "wake-turn"))
    },
    stop: ->(_id: String) { ok(false) },
    delete: ->(_id: String) { ok() },
    snapshot: ->(id: String) {
      return ok(immediate_child(id)) if id == "child-1"

      ok(immediate_parent(id))
    },
    watch: ->(_id: String, _names: List[String], handler: Fn[Spec.Seen, Void]) {
      _ = handlers.send(handler, 0)
      ok()
    },
  )
end

# A child whose wake is consumed mid-send, as a late turn once did: the send answers with the live turn anyway.
def steal_host(handlers: Channel[Fn[Spec.Seen, Void]], woken: Channel[Woke], wakes: ATS[String, String]) -> Spec.Host
  Spec.Host(
    create: ->(_child: Spec.NewChild) { ok("child-1") },
    send: ->(id: String, text: String) {
      if id == "child-1"
        wakes.delete(id)
        return ok(Protocol.MessageAccepted(turn_id: "turn-2"))
      end

      _ = woken.send(Woke(id: id, text: text), 1000)
      ok(Protocol.MessageAccepted(turn_id: "wake-turn"))
    },
    stop: ->(_id: String) { ok(false) },
    delete: ->(_id: String) { ok() },
    snapshot: ->(id: String) {
      return ok(running_child(id, "turn-2")) if id == "child-1"

      ok(immediate_parent(id))
    },
    watch: ->(_id: String, _names: List[String], handler: Fn[Spec.Seen, Void]) {
      _ = handlers.send(handler, 0)
      ok()
    },
  )
end

# A child the test drives by hand: `send` answers with the running turn but fires nothing.
def manual_host(handlers: Channel[Fn[Spec.Seen, Void]], woken: Channel[Woke]) -> Spec.Host
  Spec.Host(
    create: ->(_child: Spec.NewChild) { ok("child-1") },
    send: ->(id: String, text: String) {
      return ok(Protocol.MessageAccepted(turn_id: "turn-1")) if id == "child-1"

      _ = woken.send(Woke(id: id, text: text), 1000)
      ok(Protocol.MessageAccepted(turn_id: "wake-turn"))
    },
    stop: ->(_id: String) { ok(false) },
    delete: ->(_id: String) { ok() },
    snapshot: ->(id: String) {
      return ok(running_child(id, "turn-1")) if id == "child-1"

      ok(immediate_parent(id))
    },
    watch: ->(_id: String, _names: List[String], handler: Fn[Spec.Seen, Void]) {
      _ = handlers.send(handler, 0)
      ok()
    },
  )
end

# A session handle whose child finishes at once: `send` fires the watcher's `turn_finished` before it answers, so
# the completion lands before the wake is registered and the post-send snapshot already shows an idle child with
# its answer. A `send` to any other id records the parent's wake. The first watcher wins, as `watch` promises.
def immediate_host(handlers: Channel[Fn[Spec.Seen, Void]], woken: Channel[Woke]) -> Spec.Host
  Spec.Host(
    create: ->(_child: Spec.NewChild) { ok("child-1") },
    send: ->(id: String, text: String) {
      if id == "child-1"
        fire_now(handlers, id, "turn-1")
        return ok(Protocol.MessageAccepted(turn_id: "turn-1"))
      end

      _ = woken.send(Woke(id: id, text: text), 1000)
      ok(Protocol.MessageAccepted(turn_id: "wake-turn"))
    },
    stop: ->(_id: String) { ok(false) },
    delete: ->(_id: String) { ok() },
    snapshot: ->(id: String) {
      return ok(immediate_child(id)) if id == "child-1"

      ok(immediate_parent(id))
    },
    watch: ->(_id: String, _names: List[String], handler: Fn[Spec.Seen, Void]) {
      _ = handlers.send(handler, 0)
      ok()
    },
  )
end

def immediate_child(id: String) -> Protocol.Session
  Protocol.Session(
    id: id,
    cwd: "/tmp",
    model: "m",
    last_event_id: 0,
    turn_id: none,
    turn_from_event_id: none,
    pending_approvals: [],
    history: [Protocol.Message(role: Protocol.Role.Assistant, text: ANSWER)],
    provider: "local",
  )
end

def immediate_parent(id: String) -> Protocol.Session
  Protocol.Session(
    id: id,
    cwd: "/tmp",
    model: "m",
    last_event_id: 0,
    turn_id: none,
    turn_from_event_id: none,
    pending_approvals: [],
    history: [],
    provider: "local",
  )
end

def finish_seen(child: String, turn: String) -> Spec.Seen
  Spec.Seen(
    session: child,
    root: "/tmp",
    name: "turn_finished",
    data: JSON.object({"turn_id": JSON.from(turn), "stop_reason": JSON.from("end_turn")}),
    parent: none,
  )
end

# Fires the watcher kept for `child` with its `turn_finished`, keeping it for the next fire.
def fire_now(handlers: Channel[Fn[Spec.Seen, Void]], child: String, turn: String) -> Void
  case handlers.recv(0)
    ok(handler) ->
      _ = handlers.send(handler, 1000)
      handler.call(finish_seen(child, turn))
    error(_) -> nil
  end
end

# One wake to the real parent with the headed answer, and nothing after: neither a duplicate of its turn nor a
# stale turn wakes again, and no turn, waiter or wake is left behind. The async child stays open, so its display
# name stays by design.
def check_immediate_wake(setup: Immediate) -> Result[Void]
  first = try setup.woken.recv(5000)
  try Test.eq(first.id, "parent")
  try Test.assert(first.text.include?(ANSWER), "the wake carried no answer: #{first.text}")
  # The finish landed before the send answered, so its own reason never arrived: the send reconciles it from the
  # snapshot, with `ended` for the reason a missed answer also carries.
  try Test.assert(first.text.include?("build (local/m): ended"), "the wake has no headed answer: #{first.text}")
  fire_now(setup.handlers, "child-1", "turn-1")
  try Test.assert(not setup.woken.recv(0).ok?, "a duplicate finish woke again")
  fire_now(setup.handlers, "child-1", "other-turn")
  try Test.assert(not setup.woken.recv(0).ok?, "a stale finish woke")
  try Test.assert(setup.turns.keys().empty?, "a turn is left behind")
  try Test.assert(setup.waits.keys().empty?, "a waiter is left behind")
  Test.assert(setup.wakes.keys().empty?, "a wake is left behind")
end

# A stale finish that lands between an async `agent_send`'s wake registration and its send answer wakes nothing:
# the send reconciles it from its snapshot, and only the live turn's finish wakes, exactly once.
def test_async_send_with_stale_finish_before_send_returns_wakes_once() -> Result[Void]
  setup = stale_race()
  setup.names.put("child-1", "build")
  input = try JSON.parse("{\"id\": \"child-1\", \"text\": \"Again.\", \"wait\": false}")
  try Test.eq(try setup.tools[1].run.call(setup.ctx, input), "child-1")
  # The stale turn woke nothing, and the live turn stayed tracked for the cap with its wake still owed.
  try Test.assert(not setup.woken.recv(0).ok?, "a stale finish woke")
  try Test.eq(setup.turns.get("child-1").unwrap_or(""), "turn-2")
  try Test.eq(setup.wakes.get("child-1").unwrap_or(""), "parent")
  fire_now(setup.handlers, "child-1", "turn-2")
  first = try setup.woken.recv(5000)
  try Test.eq(first.id, "parent")
  try Test.assert(first.text.include?(ANSWER), "the wake carried no answer: #{first.text}")
  try Test.assert(first.text.include?("build (local/m): end_turn"), "the wake has no headed answer: #{first.text}")
  fire_now(setup.handlers, "child-1", "turn-2")
  try Test.assert(not setup.woken.recv(0).ok?, "a duplicate finish woke again")
  fire_now(setup.handlers, "child-1", "other-turn")
  try Test.assert(not setup.woken.recv(0).ok?, "a stale finish woke")
  try Test.assert(setup.turns.keys().empty?, "a turn is left behind")
  try Test.assert(setup.waits.keys().empty?, "a waiter is left behind")
  Test.assert(setup.wakes.keys().empty?, "a wake is left behind")
end

# The same stale race through `agent`: the start answers with the id, wakes nothing stale, and wakes once for
# the live turn.
def test_async_start_with_stale_finish_before_send_returns_wakes_once() -> Result[Void]
  setup = stale_race()
  input = try JSON.parse("{\"tasks\": [{\"prompt\": \"Say hi.\"}], \"wait\": false}")
  try Test.eq(try setup.tools[0].run.call(setup.ctx, input), "child-1")
  try Test.assert(not setup.woken.recv(0).ok?, "a stale finish woke")
  try Test.eq(setup.turns.get("child-1").unwrap_or(""), "turn-2")
  fire_now(setup.handlers, "child-1", "turn-2")
  first = try setup.woken.recv(5000)
  try Test.eq(first.id, "parent")
  try Test.assert(first.text.include?(ANSWER), "the wake carried no answer: #{first.text}")
  try Test.assert(first.text.include?("build (local/m): end_turn"), "the wake has no headed answer: #{first.text}")
  fire_now(setup.handlers, "child-1", "turn-1")
  try Test.assert(not setup.woken.recv(0).ok?, "a stale finish woke")
  try Test.assert(setup.turns.keys().empty?, "a turn is left behind")
  try Test.assert(setup.waits.keys().empty?, "a waiter is left behind")
  Test.assert(setup.wakes.keys().empty?, "a wake is left behind")
end

# A failed async `agent_send` answers with the failure and leaves no wake behind; a live turn it never owned
# stays tracked.
def test_async_send_failure_cleans_its_wake_and_keeps_a_live_turn() -> Result[Void]
  try failing_send(false)
  failing_send(true)
end

def failing_send(foreign: Bool) -> Result[Void]
  setup = failing_setup()
  if foreign
    setup.turns.put("child-1", "turn-2")
    setup.wakes.put("child-1", "parent")
  end

  input = try JSON.parse("{\"id\": \"child-1\", \"text\": \"Again.\", \"wait\": false}")
  result = setup.tools[1].run.call(setup.ctx, input)
  case result
    ok(_) -> return error("a failed send answered")
    error(e) -> try Test.assert(e.message.include?("busy"), "wrong failure: #{e.message}")
  end

  try Test.assert(not setup.woken.recv(0).ok?, "a failed send woke")
  try Test.assert(setup.waits.keys().empty?, "a waiter is left behind")
  if foreign
    try Test.eq(setup.turns.get("child-1").unwrap_or(""), "turn-2")
    Test.eq(setup.wakes.get("child-1").unwrap_or(""), "parent")
  else
    try Test.assert(setup.turns.keys().empty?, "a turn is left behind")
    Test.assert(setup.wakes.keys().empty?, "a wake is left behind")
  end
end

# An async `agent_send` whose wake is gone by the time its send answers still tracks its live turn, so the cap
# counts it; the finish its stolen wake would have woken finds nobody owed and is dropped, leaving nothing behind.
def test_async_send_records_its_turn_despite_a_missing_wake() -> Result[Void]
  handlers: Channel[Fn[Spec.Seen, Void]] = Channel.new(1)
  woken: Channel[Woke] = Channel.new(4)
  turns: ATS[String, String] = ATS.new()
  waits: ATS[String, Address[Agents.Heard]] = ATS.new()
  wakes: ATS[String, String] = ATS.new()
  names: ATS[String, String] = ATS.new()
  names.put("child-1", "build")
  host = steal_host(handlers, woken, wakes)
  tools = Agents.tools(-> { [] }, Agents.Limits(max: 0, timeout_ms: 0), turns, waits, wakes, names)
  ctx = Spec.Context(
    root: "/tmp",
    env: ->(_name: String) { error("no env") },
    host: some(host),
    session: some("parent"),
  )

  input = try JSON.parse("{\"id\": \"child-1\", \"text\": \"Again.\", \"wait\": false}")
  try Test.eq(try tools[1].run.call(ctx, input), "child-1")
  # The wake was consumed mid-send, yet the live turn is tracked.
  try Test.assert(not woken.recv(0).ok?, "nothing finished yet, but something woke")
  try Test.eq(turns.get("child-1").unwrap_or(""), "turn-2")
  fire_now(handlers, "child-1", "turn-2")
  try Test.assert(not woken.recv(0).ok?, "nobody was owed a wake, but something woke")
  try Test.assert(turns.keys().empty?, "a turn is left behind")
  try Test.assert(waits.keys().empty?, "a waiter is left behind")
  Test.assert(wakes.keys().empty?, "a wake is left behind")
end

# A late finish that lands while an async `agent_send` starts still goes to the hung waiter that owns it, and the
# send still reconciles its own turn and wakes once for it: the waiter path never consumes the newer wake.
def test_async_send_with_a_hung_waiter_still_wakes_once() -> Result[Void]
  setup = hung_setup()
  waiter: Channel[Agents.Heard] = Channel.new(4)
  setup.turns.put("child-1", "turn-1")
  setup.waits.put("child-1", waiter.address)
  setup.names.put("child-1", "build")
  input = try JSON.parse("{\"id\": \"child-1\", \"text\": \"Again.\", \"wait\": false}")
  try Test.eq(try setup.tools[1].run.call(setup.ctx, input), "child-1")
  heard = try waiter.recv(5000)
  try Test.eq(heard.turn_id, "turn-1")
  woke = try setup.woken.recv(5000)
  try Test.eq(woke.id, "parent")
  try Test.assert(woke.text.include?(ANSWER), "the wake carried no answer: #{woke.text}")
  try Test.assert(woke.text.include?("build (local/m): ended"), "the wake has no headed answer: #{woke.text}")
  fire_now(setup.handlers, "child-1", "turn-2")
  try Test.assert(not setup.woken.recv(0).ok?, "a duplicate finish woke again")
  fire_now(setup.handlers, "child-1", "turn-9")
  try Test.assert(not setup.woken.recv(0).ok?, "a stale finish woke")
  try Test.assert(setup.turns.keys().empty?, "a turn is left behind")
  try Test.assert(setup.waits.keys().empty?, "a waiter is left behind")
  Test.assert(setup.wakes.keys().empty?, "a wake is left behind")
end

# An async `agent_send` queued into a waited turn owes no wake: the waiter's finish goes to the waiter alone.
def test_async_send_queued_into_a_waited_turn_wakes_nothing() -> Result[Void]
  handlers: Channel[Fn[Spec.Seen, Void]] = Channel.new(1)
  woken: Channel[Woke] = Channel.new(4)
  waiter: Channel[Agents.Heard] = Channel.new(4)
  host = manual_host(handlers, woken)
  turns: ATS[String, String] = ATS.new()
  waits: ATS[String, Address[Agents.Heard]] = ATS.new()
  wakes: ATS[String, String] = ATS.new()
  names: ATS[String, String] = ATS.new()
  turns.put("child-1", "turn-1")
  waits.put("child-1", waiter.address)
  tools = Agents.tools(-> { [] }, Agents.Limits(max: 0, timeout_ms: 0), turns, waits, wakes, names)
  ctx = Spec.Context(
    root: "/tmp",
    env: ->(_name: String) { error("no env") },
    host: some(host),
    session: some("parent"),
  )

  input = try JSON.parse("{\"id\": \"child-1\", \"text\": \"Again.\", \"wait\": false}")
  try Test.eq(try tools[1].run.call(ctx, input), "child-1")
  try Test.assert(not woken.recv(0).ok?, "a queued send owed a wake")
  try Test.assert(wakes.keys().empty?, "a queued send left a wake behind")
  fire_now(handlers, "child-1", "turn-1")
  heard = try waiter.recv(5000)
  try Test.eq(heard.turn_id, "turn-1")
  try Test.assert(not woken.recv(0).ok?, "the waiter’s finish woke as well")
  try Test.assert(turns.keys().empty?, "a turn is left behind")
  try Test.assert(waits.keys().empty?, "a waiter is left behind")
  Test.assert(wakes.keys().empty?, "a wake is left behind")
end
