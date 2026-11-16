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

def test_a_new_session_names_its_model_and_api() -> Result[Void]
  Driver.within([Routes.created(), Routes.held_events()]) do |rig|
    cli = try Driver.start(rig.dir, PLAIN + ["--model", "m", "--api", "openai_responses"])
    try Driver.read_until(cli, "[session")
    _ = try Driver.finish(cli)
    create = try Fake.request(rig.fake, "POST", Protocol.SESSIONS_PATH)
    asked = Protocol.NewSession(cwd: "/work", model: some("m"), api: some("openai_responses"))
    Test.eq(Protocol.decode_new_session(create.body), ok(asked))
  end
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
    "[usage] input 1200, output (session) 85, cache read 1000, cache write 0, context 1285",
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

# `--delete ID` deletes that session and exits; a refusal (a turn runs) is an error.
def test_delete_removes_a_session_and_exits() -> Result[Void]
  busy = Protocol.Failure(kind: Protocol.KIND_SESSION_BUSY, message: "a turn is running")
  routes = [
    Fake.Route(method: "DELETE", path: Protocol.session_path("s1"), replies: [Fake.Reply(status: 200, body: "{}")]),
    Fake.Route(
      method: "DELETE",
      path: Protocol.session_path("s2"),
      replies: [Fake.Reply(status: 409, body: Protocol.encode_failure(busy))],
    ),
  ]

  Driver.within(routes, &deletes)
end

def deletes(rig: Driver.Rig) -> Result[Void]
  done = try Driver.exited(try Driver.start(rig.dir, ["--delete", "s1"]))
  try Test.eq([done.lines, [done.code.to_s]], [["[session s1 deleted]"], ["0"]])
  deleted = try Fake.request(rig.fake, "DELETE", Protocol.session_path("s1"))
  try Test.assert(Driver.authorized?(deleted), "the delete carries the token")
  refused = try Driver.exited(try Driver.start(rig.dir, ["--delete", "s2"]))
  try Test.eq([refused.lines, [refused.code.to_s]], [[], ["1"]])
  try Test.assert(refused.errors.include?("a turn is running"), refused.errors)
  Test.eq(Fake.strays(rig.fake), 0)
end

# `-p` sends one task, reads no line, prints only the answer on stdout and exits with the status of the turn.
def test_one_shot_prints_the_answer_on_stdout_and_the_rest_on_stderr() -> Result[Void]
  Driver.within([Routes.created(), Routes.held_events(), Routes.accepting(["turn.sse"])]) do |rig|
    done = try Driver.exited(try Driver.start(rig.dir, PLAIN + ["-p", "hello"]))
    message = try Fake.request(rig.fake, "POST", Protocol.messages_path("s1"))
    try Test.eq(Protocol.decode_send_message(message.body), ok(Protocol.SendMessage(text: "hello")))
    try Test.eq(done.lines, ["I'll read the file.", "It says \"agc-agent\"."])
    try Test.assert(done.errors.include?("[session s1]\n[tool] read_file README.md\n"), "stderr: #{done.errors}")
    try Test.assert(done.errors.include?("[turn finished] end_turn"), "stderr: #{done.errors}")
    Test.eq(done.code, 0)
  end
end

def test_one_shot_denies_approvals_and_yolo_allows_them() -> Result[Void]
  for yolo in [false, true]
    end_pushes = ["denied_end.sse"]
    decision = Protocol.Decision.Deny
    args = PLAIN + ["--prompt", "clean up"]
    if yolo
      end_pushes = ["approval_elsewhere.sse"]
      decision = Protocol.Decision.Allow
      args = args + ["--yolo"]
    end

    routes = [
      Routes.created(),
      Routes.held_events(),
      Routes.accepting(["approval_1.sse"]),
      Routes.answering("a1", Fake.Reply(push: end_pushes)),
    ]

    try Driver.within(routes) do |rig|
      done = try Driver.exited(try Driver.start(rig.dir, args))
      answer = try Fake.request(rig.fake, "POST", Protocol.approval_path("s1", "a1"))
      try Test.eq(Protocol.decode_approve(answer.body), ok(Protocol.Approve(decision: decision)))
      try Test.assert(not done.errors.include?(PROMPT), "nothing is asked: #{done.errors}")
      try Test.eq(done.errors.include?("--yolo: every tool call is approved"), yolo)
      Test.eq(done.code, 0)
    end
  end

  ok()
end

# 0 for a turn that ends normally, 130 for a cancelled one, 1 for any other end.
def test_one_shot_exits_130_when_cancelled_and_1_when_the_turn_fails() -> Result[Void]
  for pair in [["cancelled.sse", "130"], ["failed.sse", "1"]]
    try Driver.within([Routes.created(), Routes.held_events(), Routes.accepting([pair[0]])]) do |rig|
      done = try Driver.exited(try Driver.start(rig.dir, PLAIN + ["-p", "start"]))
      Test.eq(done.code.to_s, pair[1])
    end
  end

  ok()
end

# A task that cannot be sent fails at once: a busy session, a failed request, an empty task (sent never).
def test_one_shot_fails_when_the_task_is_not_sent() -> Result[Void]
  failure = Protocol.Failure(kind: Protocol.KIND_SESSION_BUSY, message: "a turn runs")
  busy = Fake.Reply(status: 409, body: Protocol.encode_failure(failure))
  for reply in [busy, Routes.failing()]
    sending = Fake.Route(method: "POST", path: Protocol.messages_path("s1"), replies: [reply])
    try Driver.within([Routes.created(), Routes.held_events(), sending]) do |rig|
      done = try Driver.exited(try Driver.start(rig.dir, PLAIN + ["-p", "start"]))
      try Test.assert(done.errors.include?("[error]"), "the failure is said on stderr: #{done.errors}")
      try Test.eq(done.lines, [])
      Test.eq(done.code, 1)
    end
  end

  Driver.within([Routes.created(), Routes.held_events(), Routes.accepting(["turn.sse"])]) do |rig|
    cli = try Driver.start(rig.dir, PLAIN + ["-p", "-"])
    try Driver.say(cli, "")
    done = try Driver.finish(cli)
    try Test.assert(done.errors.include?("the task is empty"), "stderr: #{done.errors}")
    try Test.eq(Fake.unread_requests(rig.fake, "POST", Protocol.messages_path("s1")).size, 0)
    Test.eq(done.code, 1)
  end
end

# `-p -` keeps the task as typed: only the newlines at its end go.
def test_one_shot_reads_the_task_from_stdin_with_a_dash() -> Result[Void]
  Driver.within([Routes.created(), Routes.held_events(), Routes.accepting(["turn.sse"])]) do |rig|
    cli = try Driver.start(rig.dir, PLAIN + ["-p", "-"])
    try Driver.say(cli, "  indented code")
    try Driver.say(cli, "and sum it up")
    try Driver.say(cli, "")
    done = try Driver.finish(cli)
    message = try Fake.request(rig.fake, "POST", Protocol.messages_path("s1"))
    expected = Protocol.SendMessage(text: "  indented code\nand sum it up")
    try Test.eq(Protocol.decode_send_message(message.body), ok(expected))
    Test.eq(done.code, 0)
  end
end

# `--yolo` allows the approvals of this run only: one that was pending before the client attached is asked.
def test_yolo_asks_an_approval_pending_before_it_attached() -> Result[Void]
  routes = [
    Routes.session([Fake.Reply(session: "session_running_approval.json")]),
    Routes.events([Fake.Reply(fixture: "replay_pending.sse", hold: true)]),
    Routes.answering("a1", Fake.Reply(push: ["turn_rest.sse"])),
  ]

  Driver.within(routes) do |rig|
    cli = try Driver.start(rig.dir, ["--session", "s1", "--yolo"])
    try Driver.read_until(cli, PROMPT)
    try Driver.say(cli, "n")
    try Driver.read_until(cli, "[turn finished]")
    done = try Driver.finish(cli)
    answer = try Fake.request(rig.fake, "POST", Protocol.approval_path("s1", "a1"))
    try Test.eq(Protocol.decode_approve(answer.body), ok(Protocol.Approve(decision: Protocol.Decision.Deny)))
    Test.eq(done.code, 0)
  end
end

# The session commands: /model and /thinking change the session, a bad level is refused before any request,
# /resume lists the sessions and switches to the one picked, /new makes another one, and /help lists them all.
def test_session_commands() -> Result[Void]
  list = Protocol.SessionList(
    sessions: [
      Protocol.SessionSummary(id: "s1", cwd: "/work", model: "m", api: "openai"),
      Protocol.SessionSummary(id: "s2", cwd: "/other", model: "m2", api: "openai"),
    ],
  )

  routes = [
    Fake.Route(
      method: "POST",
      path: Protocol.SESSIONS_PATH,
      replies: [Fake.Reply(status: 201, body: "{\"id\": \"s1\"}"), Fake.Reply(status: 201, body: "{\"id\": \"s3\"}")],
    ),
    Routes.held_events(),
    Fake.Route(
      method: "PATCH",
      path: Protocol.session_path("s1"),
      replies: [Fake.Reply(body: "{}"), Fake.Reply(body: "{}")],
    ),
    Fake.Route(
      method: "GET",
      path: Protocol.SESSIONS_PATH,
      replies: [
        Fake.Reply(body: Protocol.encode_session_list(list)),
        Fake.Reply(body: Protocol.encode_session_list(list)),
      ],
    ),
    Fake.Route(method: "GET", path: Protocol.session_path("s2"), replies: [Fake.Reply(session: "session_idle.json")]),
    Fake.Route(method: "GET", path: Protocol.events_path("s2"), replies: [Fake.Reply(hold: true)]),
    Fake.Route(method: "GET", path: Protocol.events_path("s3"), replies: [Fake.Reply(hold: true)]),
  ]

  Driver.within(routes) do |rig|
    cli = try Driver.start(rig.dir, PLAIN)
    try Driver.read_until(cli, "[session s1]")
    try Driver.say(cli, "/model qwen3")
    try Driver.read_until(cli, "[model qwen3 from the next turn]")
    try Driver.say(cli, "/thinking max")
    try Driver.read_until(cli, "[error] the thinking level is one of low, medium, high, default")
    try Driver.say(cli, "/thinking high")
    try Driver.read_until(cli, "[thinking high from the next turn]")
    try Driver.say(cli, "/resume")
    try Driver.read_until(cli, "2. s2  m2  /other")
    try Driver.say(cli, "/resume 2")
    try Driver.read_until(cli, "[session s2]")
    try Driver.say(cli, "/new")
    try Driver.read_until(cli, "[session s3]")
    try Driver.say(cli, "/help")
    try Driver.read_until(cli, "/quit                      leave")
    try Driver.say(cli, "/quit")
    done = try Driver.finish(cli)
    try Test.eq(done.code, 0)
    first = try Fake.request(rig.fake, "PATCH", Protocol.session_path("s1"))
    try Test.eq(Protocol.decode_update_session(first.body), ok(Protocol.UpdateSession(model: some("qwen3"))))
    second = try Fake.request(rig.fake, "PATCH", Protocol.session_path("s1"))
    try Test.eq(Protocol.decode_update_session(second.body), ok(Protocol.UpdateSession(effort: some("high"))))
    Test.eq(Fake.strays(rig.fake), 0)
  end
end

# A line that starts with `/` but is no client command (a path, a skill, `/` alone) goes to the agent as text. While a
# turn runs, /new and /resume are refused; a call that fails after /model warns about the name.
def test_slash_text_busy_switches_and_the_model_warning() -> Result[Void]
  accepted = Fake.Reply(status: 202, body: "{\"turn_id\": \"t1\"}")
  routes = [
    Routes.created(),
    Routes.held_events(),
    Fake.Route(method: "PATCH", path: Protocol.session_path("s1"), replies: [Fake.Reply(body: "{}")]),
    Fake.Route(
      method: "POST",
      path: Protocol.messages_path("s1"),
      replies: [accepted.with(push: ["working.sse"]), accepted],
    ),
    Routes.stopping(Fake.Reply(status: 202, push: ["model_failed.sse"])),
  ]

  Driver.within(routes) do |rig|
    cli = try Driver.start(rig.dir, PLAIN)
    try Driver.read_until(cli, "[session s1]")
    try Driver.say(cli, "/model qwen3")
    try Driver.read_until(cli, "[model qwen3 from the next turn]")
    try Driver.say(cli, "/")
    try Driver.read_until(cli, "Working on it...")
    for command in ["/new", "/resume 2"]
      try Driver.say(cli, command)
      try Driver.read_until(cli, "[a turn is running: /stop it first]")
    end

    try Driver.say(cli, "/stop")
    try Driver.read_until(cli, "[warning] the call failed after /model qwen3")
    try Driver.say(cli, "/etc/hosts has a bad entry")
    try Driver.say(cli, "/quit")
    done = try Driver.finish(cli)
    try Test.eq(done.code, 0)
    first = try Fake.request(rig.fake, "POST", Protocol.messages_path("s1"))
    second = try Fake.request(rig.fake, "POST", Protocol.messages_path("s1"))
    try Test.eq(
      [Protocol.decode_send_message(first.body), Protocol.decode_send_message(second.body)],
      [ok(Protocol.SendMessage(text: "/")), ok(Protocol.SendMessage(text: "/etc/hosts has a bad entry"))],
    )

    Test.eq(Fake.strays(rig.fake), 0)
  end
end
