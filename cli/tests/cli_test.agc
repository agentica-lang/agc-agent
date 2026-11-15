# The line client as a child process on pipes, against a fake protocol server that streams recorded events.

import Protocol from "pkg/protocol/protocol"
import Driver from "support/driver"
import Fake from "support/fake_server"
import Routes from "support/routes"

PLAIN = ["--cwd", "/work"]
PROMPT = Routes.PROMPT
# Longer than the 10 s the client once waited for a piece of the stream.
QUIET_MS = 12_000

def test_a_turn_streams_text_tools_and_usage() -> Result[Void]
  Driver.within([Routes.created(), Routes.held_events(), Routes.accepting(["turn.sse"])], &a_turn)
end

def a_turn(rig: Driver.Rig) -> Result[Void]
  cli = try Driver.start(rig.dir, PLAIN)
  try Driver.say(cli, "hello")
  lines = try Driver.read_until(cli, "[turn finished]")
  done = try Driver.finish(cli)
  create = try Fake.request(rig.fake, "POST", Protocol.SESSIONS_PATH)
  message = try Fake.request(rig.fake, "POST", Protocol.messages_path("s1"))
  events = try Fake.request(rig.fake, "GET", Protocol.events_path("s1"))
  health = try Fake.request(rig.fake, "GET", Protocol.HEALTH_PATH)
  expected = [
    "[session s1]",
    "I'll read the file.",
    "[tool] read_file README.md",
    "[tool ok] read 120 bytes (8 ms)",
    "It says \"agc-agent\".",
    "[usage] input 1200, output 85, cache read 1000, cache write 0, context 1285",
    "[turn finished] end_turn",
  ]

  try Test.eq(lines, expected)
  try Test.eq(done.code, 0)
  try Test.eq(done.lines, [])
  try Test.eq(Protocol.decode_new_session(create.body), ok(Protocol.NewSession(cwd: "/work", model: none)))
  try Test.eq(Protocol.decode_send_message(message.body), ok(Protocol.SendMessage(text: "hello")))
  try Test.eq(Driver.header(events, Protocol.LAST_EVENT_ID_HEADER), ["0"])
  try Test.assert(Driver.authorized?(create) and Driver.authorized?(message), "every request carries the token")
  try Test.assert(Driver.authorized?(events) and Driver.authorized?(health), "every request carries the token")
  Test.eq(Fake.strays(rig.fake), 0)
end

def test_approvals_are_answered_with_y_n_and_a() -> Result[Void]
  routes = [
    Routes.created(),
    Routes.held_events(),
    Routes.accepting(["approval_1.sse"]),
    Routes.answering("a1", Fake.Reply(push: ["approval_2.sse"])),
    Routes.answering("a2", Fake.Reply(push: ["approval_3.sse"])),
    Routes.answering("a3", Fake.Reply(push: ["approval_4.sse"])),
  ]

  Driver.within(routes, &approvals)
end

def approvals(rig: Driver.Rig) -> Result[Void]
  cli = try Driver.start(rig.dir, PLAIN)
  try Driver.say(cli, "clean up")
  first = try Driver.read_until(cli, PROMPT)
  try Driver.say(cli, "y")
  second = try Driver.read_until(cli, PROMPT)
  try Driver.say(cli, "n")
  third = try Driver.read_until(cli, PROMPT)
  try Driver.say(cli, "a")
  last = try Driver.read_until(cli, "[turn finished]")
  done = try Driver.finish(cli)
  a1 = try Fake.request(rig.fake, "POST", Protocol.approval_path("s1", "a1"))
  a2 = try Fake.request(rig.fake, "POST", Protocol.approval_path("s1", "a2"))
  a3 = try Fake.request(rig.fake, "POST", Protocol.approval_path("s1", "a3"))
  expected = [
    "[session s1]",
    "I need to run commands.",
    "[tool] bash rm -r build",
    "[approval a1] bash: rm -r build",
    PROMPT,
    "[approval a1] allow (client)",
    "[tool ok] exit 0 (31 ms)",
    "[tool] write_file notes.txt",
    "[approval a2] write_file: notes.txt, 12 bytes",
    "  line one",
    "  line two",
    PROMPT,
    "[approval a2] deny (client)",
    "[tool failed] denied by the user (0 ms)",
    "[tool] bash make test",
    "[approval a3] bash: make test",
    PROMPT,
    "[approval a3] allow_session (client)",
    "[tool ok] exit 0 (950 ms)",
    "All done.",
    "[turn finished] end_turn",
  ]

  try Test.eq(first + second + third + last, expected)
  try Test.eq(done.code, 0)
  try Test.assert(Driver.authorized?(a1) and Driver.authorized?(a2) and Driver.authorized?(a3), "the token")
  try Test.eq(Protocol.decode_approve(a1.body), ok(Protocol.Approve(decision: Protocol.Decision.Allow)))
  try Test.eq(Protocol.decode_approve(a2.body), ok(Protocol.Approve(decision: Protocol.Decision.Deny)))
  Test.eq(Protocol.decode_approve(a3.body), ok(Protocol.Approve(decision: Protocol.Decision.AllowSession)))
end

def test_an_approval_another_client_answered_first_is_not_asked_again() -> Result[Void]
  Driver.within([Routes.created(), Routes.held_events(), Routes.accepting(["approval_1.sse"])], &answered_elsewhere)
end

def answered_elsewhere(rig: Driver.Rig) -> Result[Void]
  cli = try Driver.start(rig.dir, PLAIN)
  try Driver.say(cli, "clean up")
  asked = try Driver.read_until(cli, PROMPT)
  try Fake.push(rig.fake, "approval_elsewhere.sse")
  rest = try Driver.read_until(cli, "[turn finished]")
  done = try Driver.finish(cli)
  try Test.eq(rest, ["[approval a1] allow (client)", "[tool ok] exit 0 (31 ms)", "[turn finished] end_turn"])
  try Test.assert(asked.size == 5, "the request was asked once")
  try Test.eq(done.code, 0)
  Test.eq(Fake.strays(rig.fake), 0)
end

def test_a_late_answer_is_not_a_failure() -> Result[Void]
  failure = Protocol.Failure(kind: Protocol.KIND_APPROVAL_RESOLVED, message: "the approval is resolved")
  late = Fake.Reply(status: 409, body: Protocol.encode_failure(failure), push: ["approval_elsewhere.sse"])
  routes = [Routes.created(), Routes.held_events(), Routes.accepting(["approval_1.sse"]), Routes.answering("a1", late)]
  Driver.within(routes, &late_answer)
end

def late_answer(rig: Driver.Rig) -> Result[Void]
  cli = try Driver.start(rig.dir, PLAIN)
  try Driver.say(cli, "clean up")
  try Driver.read_until(cli, PROMPT)
  try Driver.say(cli, "y")
  rest = try Driver.read_until(cli, "[turn finished]")
  done = try Driver.finish(cli)
  answer = try Fake.request(rig.fake, "POST", Protocol.approval_path("s1", "a1"))
  expected = [
    "[approval a1] already answered",
    "[approval a1] allow (client)",
    "[tool ok] exit 0 (31 ms)",
    "[turn finished] end_turn",
  ]

  try Test.eq(rest, expected)
  try Test.eq(Protocol.decode_approve(answer.body), ok(Protocol.Approve(decision: Protocol.Decision.Allow)))
  try Test.eq(done.code, 0)
  Test.eq(done.errors, "")
end

def test_a_failed_answer_keeps_the_question_pending() -> Result[Void]
  routes = [
    Routes.created(),
    Routes.held_events(),
    Routes.accepting(["approval_1.sse"]),
    Fake.Route(
      method: "POST",
      path: Protocol.approval_path("s1", "a1"),
      replies: [Routes.failing(), Fake.Reply(push: ["approval_elsewhere.sse"])],
    ),
  ]

  Driver.within(routes, &failed_answer)
end

def failed_answer(rig: Driver.Rig) -> Result[Void]
  cli = try Driver.start(rig.dir, PLAIN)
  try Driver.say(cli, "clean up")
  try Driver.read_until(cli, PROMPT)
  try Driver.say(cli, "y")
  failed = try Driver.read_until(cli, "[error]")
  try Driver.say(cli, "y")
  rest = try Driver.read_until(cli, "[turn finished]")
  done = try Driver.finish(cli)
  try Test.assert(failed.last.include?("the answer was not sent"), "the failure is said: #{failed.last}")
  try Test.eq(rest[0], "[approval a1] allow (client)")
  Test.eq(done.code, 0)
end

def test_ctrl_c_stops_the_turn() -> Result[Void]
  stop = Fake.Reply(status: 202, push: ["cancelled.sse"])
  routes = [Routes.created(), Routes.held_events(), Routes.accepting(["working.sse"]), Routes.stopping(stop)]
  Driver.within(routes, &stopped)
end

def stopped(rig: Driver.Rig) -> Result[Void]
  cli = try Driver.start(rig.dir, PLAIN)
  try Driver.say(cli, "start")
  try Driver.read_until(cli, "Working on it...")
  try Process.signal(cli, System.Signal.Int)
  rest = try Driver.read_until(cli, "[turn finished]")
  done = try Driver.finish(cli)
  request = try Fake.request(rig.fake, "POST", Protocol.stop_path("s1"))
  try Test.eq(rest, ["[stopping the turn: Ctrl+C again leaves]", "[turn finished] cancelled"])
  try Test.assert(Driver.authorized?(request), "the stop carries the token")
  Test.eq(done.code, 0)
end

def test_a_second_ctrl_c_leaves() -> Result[Void]
  routes = [Routes.created(), Routes.held_events(), Routes.accepting(["working.sse"])]
  Driver.within(routes + [Routes.stopping(Fake.Reply(status: 202))], &left_after_stop)
end

def left_after_stop(rig: Driver.Rig) -> Result[Void] = left_after_ctrl_c(rig, "[stopping")

def test_a_second_ctrl_c_leaves_when_the_stop_failed() -> Result[Void]
  routes = [Routes.created(), Routes.held_events(), Routes.accepting(["working.sse"])]
  Driver.within(routes + [Routes.stopping(Routes.failing())], &left_after_failed_stop)
end

def left_after_failed_stop(rig: Driver.Rig) -> Result[Void] = left_after_ctrl_c(rig, "the stop was not sent")

def left_after_ctrl_c(rig: Driver.Rig, marker: String) -> Result[Void]
  cli = try Driver.start(rig.dir, PLAIN)
  try Driver.say(cli, "start")
  try Driver.read_until(cli, "Working on it...")
  try Process.signal(cli, System.Signal.Int)
  try Driver.read_until(cli, marker)
  try Process.signal(cli, System.Signal.Int)
  done = try Driver.finish(cli)
  try Test.eq(done.code, 130)
  Test.eq(done.lines, ["[interrupted]"])
end

def test_resuming_mid_turn_replays_the_whole_turn() -> Result[Void]
  routes = [
    Routes.session([Fake.Reply(session: "session_running.json")]),
    Routes.events([Fake.Reply(fixture: "turn_running.sse", hold: true)]),
  ]

  Driver.within(routes, &resumed)
end

def resumed(rig: Driver.Rig) -> Result[Void]
  cli = try Driver.start(rig.dir, ["--session", "s1", "--thinking"], "")
  replayed = try Driver.read_until(cli, "[tool] bash")
  try Fake.push(rig.fake, "turn_rest.sse")
  rest = try Driver.read_until(cli, "[turn finished]")
  done = try Driver.finish(cli)
  request = try Fake.request(rig.fake, "GET", Protocol.events_path("s1"))
  dim = String.from_code(27)
  expected = [
    "[session s1]",
    "user: run the tests",
    "#{dim}[2mChecking the tests.#{dim}[0m",
    "Running the tests.",
    "[tool] bash make test",
  ]

  try Test.eq(replayed, expected)
  try Test.eq(rest, ["[tool ok] exit 0 (950 ms)", "All pass.", "[turn finished] end_turn"])
  try Test.eq(Driver.header(request, Protocol.LAST_EVENT_ID_HEADER), ["4"])
  Test.eq(done.code, 0)
end

def test_an_approval_resolved_inside_the_replay_is_never_asked() -> Result[Void]
  routes = [
    Routes.session([Fake.Reply(session: "session_running.json")]),
    Routes.events([Fake.Reply(fixture: "replay_approval.sse", hold: true)]),
  ]

  Driver.within(routes, &replayed_approval)
end

def replayed_approval(rig: Driver.Rig) -> Result[Void]
  cli = try Driver.start(rig.dir, ["--session", "s1"])
  replayed = try Driver.read_until(cli, "(rule)")
  try Fake.push(rig.fake, "turn_rest.sse")
  rest = try Driver.read_until(cli, "[turn finished]")
  done = try Driver.finish(cli)
  all = replayed + rest
  try Test.assert(not all.include?(PROMPT), "no question: #{all}")
  try Test.assert(not all.any? { |line| line.include?("[approval a1] bash") }, "no question: #{all}")
  try Test.eq(done.code, 0)
  Test.eq(Fake.strays(rig.fake), 0)
end

def test_the_end_of_the_input_denies_every_approval() -> Result[Void]
  routes = [
    Routes.created(),
    Routes.held_events(),
    Routes.accepting(["approvals_two.sse"]),
    Routes.answering("a1", Fake.Reply()),
    Routes.answering("a2", Fake.Reply(push: ["approvals_denied.sse"])),
  ]

  Driver.within(routes, &denied_at_the_end)
end

def denied_at_the_end(rig: Driver.Rig) -> Result[Void]
  cli = try Driver.start(rig.dir, PLAIN)
  try Driver.say(cli, "clean up")
  done = try Driver.finish(cli)
  a1 = try Fake.request(rig.fake, "POST", Protocol.approval_path("s1", "a1"))
  a2 = try Fake.request(rig.fake, "POST", Protocol.approval_path("s1", "a2"))
  deny = ok(Protocol.Approve(decision: Protocol.Decision.Deny))
  try Test.eq(Protocol.decode_approve(a1.body), deny)
  try Test.eq(Protocol.decode_approve(a2.body), deny)
  try Test.assert(not done.lines.include?(PROMPT), "nobody was asked: #{done.lines}")
  try Test.eq(done.lines.last, "[turn finished] end_turn")
  Test.eq(done.code, 0)
end

def test_a_quiet_stream_stays_open() -> Result[Void]
  Driver.within([Routes.created(), Routes.held_events(), Routes.accepting([])], &quiet)
end

def quiet(rig: Driver.Rig) -> Result[Void]
  cli = try Driver.start(rig.dir, PLAIN)
  try Driver.say(cli, "hello")
  _ = try Fake.request(rig.fake, "GET", Protocol.events_path("s1"))
  Task.sleep(QUIET_MS)
  try Fake.push(rig.fake, "turn.sse")
  lines = try Driver.read_until(cli, "[turn finished]")
  done = try Driver.finish(cli)
  try Test.eq(lines.last, "[turn finished] end_turn")
  try Test.eq(Fake.unread(rig.fake, "GET", Protocol.events_path("s1")), 0)
  Test.eq(done.code, 0)
end
