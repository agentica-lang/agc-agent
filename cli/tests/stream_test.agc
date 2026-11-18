# What the client does when its event stream says resync, ends, or fails.

import Protocol from "pkg/protocol/protocol"
import Driver from "support/driver"
import Fake from "support/fake_server"
import Routes from "support/routes"

PROMPT = Routes.PROMPT
LAST_EVENT_ID = Protocol.LAST_EVENT_ID_HEADER

def test_resync_reads_the_session_again_and_drops_the_old_stream() -> Result[Void]
  routes = [
    Routes.session([Fake.Reply(session: "session_resync_a.json"), Fake.Reply(session: "session_resync_b.json")]),
    Routes.events([Fake.Reply(fixture: "turn_then_resync.sse"), Fake.Reply(hold: true)]),
  ]

  Driver.within(routes, &resynced)
end

def resynced(rig: Driver.Rig) -> Result[Void]
  cli = try Driver.start(rig.dir, ["--session", "s1"])
  lines = try Driver.read_until(cli, "[resync")
  try Fake.push(rig.fake, "after_resync.sse")
  rest = try Driver.read_until(cli, "caught up")
  done = try Driver.finish(cli)
  shown = ["[session s1]", "user: hello", "assistant: hi", "on it", "[turn finished] end_turn"]
  try Test.eq(lines, shown.push("[resync: reading the session again]"))
  # The turn the stream showed is not printed again; the one it missed is.
  try Test.eq(rest, ["user: and then", "assistant: done", "caught up"])
  try Test.eq(try last_ids(rig), [["7"], ["12"]])
  Test.eq(done.code, 0)
end

def test_a_second_resync_in_a_row_skips_the_replay() -> Result[Void]
  running = Fake.Reply(session: "session_running_approval.json")
  routes = [
    Routes.session([running, running, running]),
    Routes.events([Fake.Reply(fixture: "resync.sse"), Fake.Reply(fixture: "resync.sse"), Fake.Reply(hold: true)]),
    Routes.answering("a1", Fake.Reply(push: ["turn_rest.sse"])),
  ]

  Driver.within(routes, &skipped_replay)
end

def skipped_replay(rig: Driver.Rig) -> Result[Void]
  cli = try Driver.start(rig.dir, ["--session", "s1"])
  lines = try Driver.read_until(cli, PROMPT)
  try Driver.say(cli, "y")
  rest = try Driver.read_until(cli, "[turn finished]")
  done = try Driver.finish(cli)
  answer = try Fake.request(rig.fake, "POST", Protocol.approval_path("s1", "a1"))
  expected = [
    "[session s1]",
    "user: run the tests",
    "[resync: reading the session again]",
    "[resync: reading the session again]",
    "[approval a1] bash: make test",
    PROMPT,
  ]

  try Test.eq(lines, expected)
  try Test.eq(try last_ids(rig), [["4"], ["4"], ["8"]])
  try Test.eq(Protocol.decode_approve(answer.body), ok(Protocol.Approve(decision: Protocol.Decision.Allow)))
  try Test.eq(rest.last, "[turn finished] end_turn")
  Test.eq(done.code, 0)
end

def test_a_server_that_keeps_asking_for_a_resync_is_given_up() -> Result[Void]
  running = Fake.Reply(session: "session_running.json")
  resync = Fake.Reply(fixture: "resync.sse")
  routes = [Routes.session([running, running, running]), Routes.events([resync, resync, resync])]
  Driver.within(routes, &given_up)
end

def given_up(rig: Driver.Rig) -> Result[Void]
  cli = try Driver.start(rig.dir, ["--session", "s1"])
  done = try Driver.exited(cli)
  try Test.eq(done.code, 1)
  try Test.assert(done.errors.include?("keeps asking"), "the reason: #{done.errors}")
  Test.eq(try last_ids(rig), [["4"], ["4"], ["8"]])
end

def test_an_event_between_two_resyncs_starts_the_count_again() -> Result[Void]
  running = Fake.Reply(session: "session_running.json")
  routes = [
    Routes.session([running, running, running]),
    Routes.events([Fake.Reply(fixture: "resync.sse"), Fake.Reply(hold: true), Fake.Reply(hold: true)]),
  ]

  Driver.within(routes, &counted_again)
end

def counted_again(rig: Driver.Rig) -> Result[Void]
  cli = try Driver.start(rig.dir, ["--session", "s1"])
  try Driver.read_until(cli, "[resync")
  try Fake.push(rig.fake, "text_after.sse")
  try Driver.read_until(cli, "more")
  try Fake.push(rig.fake, "resync.sse")
  try Driver.read_until(cli, "[resync")
  # The third subscription is the one that takes the push.
  first = try Fake.request(rig.fake, "GET", Protocol.events_path("s1"))
  second = try Fake.request(rig.fake, "GET", Protocol.events_path("s1"))
  third = try Fake.request(rig.fake, "GET", Protocol.events_path("s1"))
  try Fake.push(rig.fake, "turn_rest.sse")
  try Driver.read_until(cli, "[turn finished]")
  done = try Driver.finish(cli)
  ids = [first, second, third].map { |request| Driver.header(request, LAST_EVENT_ID) }
  try Test.eq(ids, [["4"], ["4"], ["4"]])
  Test.eq(done.code, 0)
end

def test_a_replay_after_a_resync_prints_nothing_twice() -> Result[Void]
  running = Fake.Reply(session: "session_running.json")
  routes = [
    Routes.session([running, running]),
    Routes.events([
      Fake.Reply(fixture: "turn_running_resync.sse"),
      Fake.Reply(fixture: "turn_running.sse", hold: true),
    ]),
  ]

  Driver.within(routes, &printed_once)
end

def printed_once(rig: Driver.Rig) -> Result[Void]
  cli = try Driver.start(rig.dir, ["--session", "s1", "--thinking"])
  lines = try Driver.read_until(cli, "[resync")
  try Fake.push(rig.fake, "turn_rest.sse")
  rest = try Driver.read_until(cli, "[turn finished]")
  done = try Driver.finish(cli)
  expected = [
    "[session s1]",
    "user: run the tests",
    "Checking the tests.",
    "Running the tests.",
    "[tool] bash make test",
    "[resync: reading the session again]",
  ]

  try Test.eq(lines, expected)
  try Test.eq(rest, ["[tool ok] exit 0 (950 ms)", "All pass.", "[turn finished] end_turn"])
  Test.eq(done.code, 0)
end

def test_a_turn_stopped_after_text_adds_no_answer_to_the_history() -> Result[Void]
  stopped("turn_cancelled_resync.sse", "[turn finished] cancelled")
end

def test_a_turn_failed_after_text_adds_no_answer_to_the_history() -> Result[Void]
  stopped("turn_failed_resync.sse", "[turn finished] error")
end

def stopped(fixture: String, finished: String) -> Result[Void]
  routes = [
    Routes.session([Fake.Reply(session: "session_resync_a.json"), Fake.Reply(session: "session_after_stop.json")]),
    Routes.events([Fake.Reply(fixture: fixture), Fake.Reply(hold: true)]),
  ]

  Driver.within(routes) do |rig|
    cli = try Driver.start(rig.dir, ["--session", "s1"])
    lines = try Driver.read_until(cli, "assistant: done")
    done = try Driver.finish(cli)
    try Test.eq(
      lines.drop(lines.size - 4),
      [finished, "[resync: reading the session again]", "user: next", "assistant: done"],
    )

    Test.eq(done.code, 0)
  end
end

def test_a_turn_cut_by_a_restart_shows_its_end_after_the_resync() -> Result[Void]
  routes = [
    Routes.session([Fake.Reply(session: "session_running.json"), Fake.Reply(session: "session_cut.json")]),
    Routes.events([Fake.Reply(fixture: "turn_running_resync.sse"), Fake.Reply(hold: true)]),
  ]

  Driver.within(routes, &cut_turn_ended)
end

def cut_turn_ended(rig: Driver.Rig) -> Result[Void]
  cli = try Driver.start(rig.dir, ["--session", "s1"])
  lines = try Driver.read_until(cli, "[the turn ended")
  first = try Fake.request(rig.fake, "GET", Protocol.events_path("s1"))
  second = try Fake.request(rig.fake, "GET", Protocol.events_path("s1"))
  done = try Driver.finish(cli)
  expected = [
    "[session s1]",
    "user: run the tests",
    "Running the tests.",
    "[tool] bash make test",
    "[resync: reading the session again]",
    "assistant: Running the tests.",
    "[the turn ended while the stream was away]",
  ]

  try Test.eq(lines, expected)
  try Test.eq([first, second].map { |request| Driver.header(request, LAST_EVENT_ID) }, [["4"], ["12"]])
  Test.eq(done.code, 0)
end

def test_a_stream_that_ends_is_read_again_from_the_last_event() -> Result[Void]
  routes = [
    Routes.session([Fake.Reply(session: "session_idle.json")]),
    Routes.events([Fake.Reply(fixture: "working.sse"), Fake.Reply(hold: true)]),
  ]

  Driver.within(routes, &reconnected)
end

def reconnected(rig: Driver.Rig) -> Result[Void]
  cli = try Driver.start(rig.dir, ["--session", "s1"])
  first = try Driver.read_until(cli, "Working on it...")
  try Fake.push(rig.fake, "cancelled.sse")
  rest = try Driver.read_until(cli, "[turn finished]")
  done = try Driver.finish(cli)
  try Test.eq(first.last, "Working on it...")
  try Test.eq(rest, ["[turn finished] cancelled"])
  try Test.eq(try last_ids(rig), [["0"], ["2"]])
  Test.eq(done.code, 0)
end

def test_a_server_of_another_version_found_on_a_reconnect_ends_the_client() -> Result[Void]
  current = Fake.Reply(
    body: Protocol.encode_health(Protocol.Health(version: "0.0.1", wire: some(Protocol.wire_digest()))),
  )

  old = Fake.Reply(body: "{\"version\": \"0.0.1\"}")
  routes = [
    # The start finds the server, then reads its version for the note; the reconnect finds the other one.
    Fake.Route(method: "GET", path: Protocol.HEALTH_PATH, replies: [current, current, old]),
    Routes.session([Fake.Reply(session: "session_idle.json")]),
    Routes.events([Fake.Reply(fixture: "working.sse"), Fake.Reply(hold: true)]),
  ]

  Driver.within(routes, &other_version)
end

def other_version(rig: Driver.Rig) -> Result[Void]
  cli = try Driver.start(rig.dir, ["--session", "s1"])
  _ = try Driver.read_until(cli, "Working on it...")
  done = try Driver.exited(cli)
  try Test.eq(done.code, 1)
  try Test.assert(done.errors.include?("now runs another version"), "the reason: #{done.errors}")
  Test.eq(Fake.unread(rig.fake, "GET", Protocol.events_path("s1")), 1)
end

def test_a_stream_that_fails_is_tried_again() -> Result[Void]
  failing = Fake.Reply(status: 500, body: "{\"kind\": \"server.error\", \"message\": \"down\"}")
  routes = [
    Routes.session([Fake.Reply(session: "session_idle.json")]),
    Routes.events([failing, failing, Fake.Reply(hold: true)]),
  ]

  Driver.within(routes, &retried)
end

def retried(rig: Driver.Rig) -> Result[Void]
  cli = try Driver.start(rig.dir, ["--session", "s1"])
  try Driver.read_until(cli, "[session s1]")
  _ = try Fake.request(rig.fake, "GET", Protocol.events_path("s1"))
  _ = try Fake.request(rig.fake, "GET", Protocol.events_path("s1"))
  _ = try Fake.request(rig.fake, "GET", Protocol.events_path("s1"))
  try Fake.push(rig.fake, "cancelled.sse")
  lines = try Driver.read_until(cli, "[turn finished]")
  done = try Driver.finish(cli)
  try Test.eq(lines, ["[turn finished] cancelled"])
  Test.eq(done.code, 0)
end

def test_a_stream_that_keeps_failing_is_given_up_after_three_tries() -> Result[Void]
  failing = Fake.Reply(status: 500, body: "{\"kind\": \"server.error\", \"message\": \"down\"}")
  routes = [
    Routes.session([Fake.Reply(session: "session_idle.json")]),
    Routes.events([failing, failing, failing, failing, Fake.Reply(hold: true)]),
  ]

  Driver.within(routes, &given_up_on_the_stream)
end

def given_up_on_the_stream(rig: Driver.Rig) -> Result[Void]
  cli = try Driver.start(rig.dir, ["--session", "s1"])
  done = try Driver.exited(cli)
  try Test.eq(done.code, 1)
  try Test.assert(done.errors.include?("lost the event stream"), "the reason: #{done.errors}")
  Test.eq(Fake.unread(rig.fake, "GET", Protocol.events_path("s1")), 4)
end

def test_an_accepted_stream_resets_the_count_of_failures() -> Result[Void]
  failing = Fake.Reply(status: 500, body: "{\"kind\": \"server.error\", \"message\": \"down\"}")
  ends = Fake.Reply()
  routes = [
    Routes.session([Fake.Reply(session: "session_idle.json")]),
    Routes.events([failing, failing, ends, failing, failing, Fake.Reply(hold: true)]),
  ]

  Driver.within(routes, &reset_by_an_accepted_stream)
end

def reset_by_an_accepted_stream(rig: Driver.Rig) -> Result[Void]
  cli = try Driver.start(rig.dir, ["--session", "s1"])
  try Driver.read_until(cli, "[session s1]")
  for _ in 1..6
    _ = try Fake.request(rig.fake, "GET", Protocol.events_path("s1"))
  end

  try Fake.push(rig.fake, "cancelled.sse")
  lines = try Driver.read_until(cli, "[turn finished]")
  done = try Driver.finish(cli)
  try Test.eq(lines, ["[turn finished] cancelled"])
  Test.eq(done.code, 0)
end

private

# The Last-Event-ID of each subscription the fake got that nobody read yet.
def last_ids(rig: Driver.Rig) -> Result[List[List[String]]]
  seen = Fake.unread_requests(rig.fake, "GET", Protocol.events_path("s1"))
  ok(seen.map { |request| Driver.header(request, LAST_EVENT_ID) })
end
