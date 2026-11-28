## The built-in subagent tools (`agent`, `agent_send`, `agent_stop`): ordered waited answers, the roster and the
## provider and tool ceilings, the cap, `/stop` during a wait, the async wake, and the refused inputs. Each turn here
## runs its fixture alone, except for the children an `agent` call starts, which share identical replies.

import Protocol from "pkg/protocol/protocol"
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

# `/stop` during a waited `agent` call ends the call and stops the children's turns.
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
