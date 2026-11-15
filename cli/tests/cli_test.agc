# The line client as a child process on pipes, against a fake protocol server that streams recorded events.

import HTTP from "std/http"
import Protocol from "pkg/protocol/protocol"
import Driver from "support/driver"
import Fake from "support/fake_server"

PLAIN = ["--cwd", "/work"]
PROMPT = "allow? y = yes, n = no, a = yes for the session"

def created() -> Fake.Route
  reply = Fake.Reply(status: 201, body: "{\"id\": \"s1\"}")
  Fake.Route(method: "POST", path: Protocol.SESSIONS_PATH, replies: [reply])
end

def held_events() -> Fake.Route
  stream = Fake.Reply(hold: true)
  Fake.Route(method: "GET", path: Protocol.events_path("s1"), replies: [stream])
end

def accepting(pushes: List[String]) -> Fake.Route
  reply = Fake.Reply(status: 202, body: "{\"turn_id\": \"t1\"}", push: pushes)
  Fake.Route(method: "POST", path: Protocol.messages_path("s1"), replies: [reply])
end

def answering(approval_id: String, reply: Fake.Reply) -> Fake.Route
  Fake.Route(method: "POST", path: Protocol.approval_path("s1", approval_id), replies: [reply])
end

def stopping(reply: Fake.Reply) -> Fake.Route
  Fake.Route(method: "POST", path: Protocol.stop_path("s1"), replies: [reply])
end

def test_a_turn_streams_text_tools_and_usage() -> Result[Void]
  rig = try Driver.rig([created(), held_events(), accepting(["turn.sse"])])
  cli = try Driver.start(rig.dir, PLAIN)
  try Driver.say(cli, "hello")
  lines = try Driver.read_until(cli, "[turn finished]")
  done = try Driver.finish(cli)
  create = try Fake.request(rig.fake, "POST", Protocol.SESSIONS_PATH)
  message = try Fake.request(rig.fake, "POST", Protocol.messages_path("s1"))
  events = try Fake.request(rig.fake, "GET", Protocol.events_path("s1"))
  health = try Fake.request(rig.fake, "GET", Protocol.HEALTH_PATH)
  strays = Fake.strays(rig.fake)
  try Driver.clean_up(rig)
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
  Test.eq(strays, 0)
end

def test_approvals_are_answered_with_y_n_and_a() -> Result[Void]
  allowed = Fake.Reply(push: ["approval_2.sse"])
  denied = Fake.Reply(push: ["approval_3.sse"])
  session_wide = Fake.Reply(push: ["approval_4.sse"])
  rig = try Driver.rig([
    created(),
    held_events(),
    accepting(["approval_1.sse"]),
    answering("a1", allowed),
    answering("a2", denied),
    answering("a3", session_wide),
  ])

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
  try Driver.clean_up(rig)
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
  rig = try Driver.rig([created(), held_events(), accepting(["approval_1.sse"])])
  cli = try Driver.start(rig.dir, PLAIN)
  try Driver.say(cli, "clean up")
  asked = try Driver.read_until(cli, PROMPT)
  try Fake.push(rig.fake, "approval_elsewhere.sse")
  rest = try Driver.read_until(cli, "[turn finished]")
  done = try Driver.finish(cli)
  strays = Fake.strays(rig.fake)
  try Driver.clean_up(rig)
  try Test.eq(rest, ["[approval a1] allow (client)", "[tool ok] exit 0 (31 ms)", "[turn finished] end_turn"])
  try Test.assert(asked.size == 5, "the request was asked once")
  try Test.eq(done.code, 0)
  Test.eq(strays, 0)
end

def test_a_late_answer_is_not_a_failure() -> Result[Void]
  failure = Protocol.Failure(kind: Protocol.KIND_APPROVAL_RESOLVED, message: "the approval is resolved")
  late = Fake.Reply(status: 409, body: Protocol.encode_failure(failure), push: ["approval_elsewhere.sse"])
  rig = try Driver.rig([created(), held_events(), accepting(["approval_1.sse"]), answering("a1", late)])
  cli = try Driver.start(rig.dir, PLAIN)
  try Driver.say(cli, "clean up")
  try Driver.read_until(cli, PROMPT)
  try Driver.say(cli, "y")
  rest = try Driver.read_until(cli, "[turn finished]")
  done = try Driver.finish(cli)
  answer = try Fake.request(rig.fake, "POST", Protocol.approval_path("s1", "a1"))
  try Driver.clean_up(rig)
  try Test.eq(
    rest,
    [
      "[approval a1] already answered",
      "[approval a1] allow (client)",
      "[tool ok] exit 0 (31 ms)",
      "[turn finished] end_turn",
    ],
  )

  try Test.eq(Protocol.decode_approve(answer.body), ok(Protocol.Approve(decision: Protocol.Decision.Allow)))
  try Test.eq(done.code, 0)
  Test.eq(done.errors, "")
end

def test_ctrl_c_stops_the_turn() -> Result[Void]
  stop = Fake.Reply(status: 202, push: ["cancelled.sse"])
  rig = try Driver.rig([created(), held_events(), accepting(["working.sse"]), stopping(stop)])
  cli = try Driver.start(rig.dir, PLAIN)
  try Driver.say(cli, "start")
  try Driver.read_until(cli, "Working on it...")
  try Process.signal(cli, System.Signal.Int)
  rest = try Driver.read_until(cli, "[turn finished]")
  done = try Driver.finish(cli)
  request = try Fake.request(rig.fake, "POST", Protocol.stop_path("s1"))
  try Driver.clean_up(rig)
  try Test.eq(rest, ["[stopping the turn: Ctrl+C again leaves]", "[turn finished] cancelled"])
  try Test.assert(Driver.authorized?(request), "the stop carries the token")
  Test.eq(done.code, 0)
end

def test_a_second_ctrl_c_leaves() -> Result[Void]
  rig = try Driver.rig([created(), held_events(), accepting(["working.sse"]), stopping(Fake.Reply(status: 202))])
  cli = try Driver.start(rig.dir, PLAIN)
  try Driver.say(cli, "start")
  try Driver.read_until(cli, "Working on it...")
  try Process.signal(cli, System.Signal.Int)
  try Driver.read_until(cli, "[stopping")
  try Process.signal(cli, System.Signal.Int)
  done = try Driver.finish(cli)
  try Driver.clean_up(rig)
  try Test.eq(done.code, 130)
  Test.eq(done.lines, ["[interrupted]"])
end

def test_resync_reads_the_session_again() -> Result[Void]
  before = Fake.Reply(fixture: "session_resync_a.json")
  after = Fake.Reply(fixture: "session_resync_b.json")
  session = Fake.Route(method: "GET", path: Protocol.session_path("s1"), replies: [before, after])
  events = Fake.Route(
    method: "GET",
    path: Protocol.events_path("s1"),
    replies: [Fake.Reply(fixture: "resync.sse"), Fake.Reply(hold: true)],
  )

  rig = try Driver.rig([session, events])
  cli = try Driver.start(rig.dir, ["--session", "s1"])
  lines = try Driver.read_until(cli, "[resync")
  try Fake.push(rig.fake, "after_resync.sse")
  rest = try Driver.read_until(cli, "caught up")
  done = try Driver.finish(cli)
  first = try Fake.request(rig.fake, "GET", Protocol.events_path("s1"))
  second = try Fake.request(rig.fake, "GET", Protocol.events_path("s1"))
  try Driver.clean_up(rig)
  try Test.eq(lines, ["[session s1]", "user: hello", "assistant: hi", "[resync: reading the session again]"])
  try Test.eq(rest, ["caught up"])
  try Test.eq(
    [Driver.header(first, Protocol.LAST_EVENT_ID_HEADER), Driver.header(second, Protocol.LAST_EVENT_ID_HEADER)],
    [["7"], ["12"]],
  )

  Test.eq(done.code, 0)
end

def test_resuming_mid_turn_replays_the_whole_turn() -> Result[Void]
  session = Fake.Route(
    method: "GET",
    path: Protocol.session_path("s1"),
    replies: [Fake.Reply(fixture: "session_running.json")],
  )

  events = Fake.Route(
    method: "GET",
    path: Protocol.events_path("s1"),
    replies: [Fake.Reply(fixture: "turn_running.sse", hold: true)],
  )

  rig = try Driver.rig([session, events])
  cli = try Driver.start(rig.dir, ["--session", "s1", "--thinking"], "")
  replayed = try Driver.read_until(cli, "[tool] bash")
  try Fake.push(rig.fake, "turn_rest.sse")
  rest = try Driver.read_until(cli, "[turn finished]")
  done = try Driver.finish(cli)
  request = try Fake.request(rig.fake, "GET", Protocol.events_path("s1"))
  try Driver.clean_up(rig)
  dim = String.from_code(27)
  try Test.eq(
    replayed,
    [
      "[session s1]",
      "user: run the tests",
      "#{dim}[2mChecking the tests.#{dim}[0m",
      "Running the tests.",
      "[tool] bash make test",
    ],
  )

  try Test.eq(rest, ["[tool ok] exit 0 (950 ms)", "All pass.", "[turn finished] end_turn"])
  try Test.eq(Driver.header(request, Protocol.LAST_EVENT_ID_HEADER), ["4"])
  Test.eq(done.code, 0)
end

def test_a_wrong_token_is_refused_and_no_server_starts() -> Result[Void]
  rig = try Driver.rig([], "wrong")
  cli = try Driver.start(rig.dir, ["--server-command", "no-such-agc-server"])
  done = try Driver.finish(cli)
  health = try Fake.request(rig.fake, "GET", Protocol.HEALTH_PATH)
  try Driver.clean_up(rig)
  try Test.eq(Driver.header(health, "authorization"), ["Bearer wrong"])
  try Test.eq(done.code, 1)
  try Test.eq(done.lines, [])
  try Test.assert(done.errors.include?("the token is missing or wrong"), "the 401 is the reason: #{done.errors}")
  Test.assert(done.errors.include?("no-such-agc-server"), "the command is named: #{done.errors}")
end

def test_clients_that_start_together_start_one_server() -> Result[Void]
  dir = try Driver.empty_dir()
  command = try Driver.fake_command()
  args = ["--session", "s1", "--server-command", command]
  first = try Driver.start(dir, args)
  second = try Driver.start(dir, args)
  one = try Driver.finish(first)
  two = try Driver.finish(second)
  starts = try File.read_text(try Path.join([dir, "starts.log"]))
  server = try File.read_text(try Path.join([dir, "server.json"]))
  port = try JSON.get(try JSON.parse(server), "port")
  try Path.remove(dir)
  try Test.eq([one.lines, two.lines], [["[session s1]"], ["[session s1]"]])
  try Test.eq([one.code, two.code], [0, 0])
  try Test.eq(starts, "started\n")
  Test.assert(gone?(try JSON.int(port)), "the server stopped with its state folder")
end

private

# True once nothing answers on the port.
def gone?(port: Int) -> Bool
  for _ in 1..50
    return true if not HTTP.get_response("http://127.0.0.1:#{port}#{Protocol.HEALTH_PATH}").ok?

    Task.sleep(100)
  end

  false
end
