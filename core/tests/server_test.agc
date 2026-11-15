import HTTP from "std/http"
import Protocol from "pkg/protocol/protocol"
import Server from "../src/server"
import H from "support/harness"

# The model writes a file, then runs bash on it, then answers. Two clients see the same events, and the first answer to
# an approval wins.
def test_a_turn_runs_tools_after_approvals_for_two_clients() -> Result[Void]
  h = try H.start(["write_file.sse", "bash.sse", "text.sse"])
  id = try H.new_session(h)
  a = try H.subscribe(h, id)
  b = try H.subscribe(h, id)
  sent = try H.send(h, id, "Write hello.txt, then show it.")
  try Test.eq(sent.status, 202)
  try Test.eq((try Protocol.decode_message_accepted(sent.text)).turn_id, "turn-1")
  try Test.eq((try H.send(h, id, "again")).status, 409)
  a = try H.until(a, Protocol.EventKind.ApprovalRequested)
  write = try H.approval(a)
  try Test.eq([write.tool, write.preview], ["write_file", "hello.txt"])
  try Test.eq((try H.approve(h, id, write.approval_id, Protocol.Decision.Allow)).status, 200)
  late = try H.approve(h, id, write.approval_id, Protocol.Decision.Deny)
  try Test.eq(late.status, 409)
  try Test.eq((try Protocol.decode_failure(late.text)).kind, Protocol.KIND_APPROVAL_RESOLVED)
  a = try H.until(a.with(seen: []), Protocol.EventKind.ApprovalRequested)
  bash = try H.approval(a)
  try Test.eq([bash.tool, bash.preview], ["bash", "cat hello.txt"])
  try Test.eq((try H.approve(h, id, bash.approval_id, Protocol.Decision.Allow)).status, 200)
  a = try H.until(a, Protocol.EventKind.TurnFinished)
  b = try H.until(b, Protocol.EventKind.TurnFinished)
  H.close(a)
  H.close(b)
  try Test.eq(H.stop_reason(a), "end_turn")
  try Test.eq(File.read_text("#{h.work}/hello.txt"), ok("hi\n"))
  try Test.eq(b.seen.size, (try H.session(h, id)).last_event_id)
  try Test.eq(
    H.kinds(b.seen.select { |s| tool_event?(s.event) }),
    [
      "tool_started",
      "approval_requested",
      "approval_resolved",
      "tool_finished",
      "tool_started",
      "approval_requested",
      "approval_resolved",
      "tool_finished",
    ],
  )

  third = try H.request_messages(h, 3)
  try Test.eq(JSON.get(third.last, "role"), ok(JSON.from("tool")))
  try Test.eq(JSON.get(third.last, "content"), ok(JSON.from("hi\n")))
  snapshot = try H.session(h, id)
  try H.stop(h)
  try Test.eq(snapshot.turn_id, none)
  Test.eq(snapshot.history.map { |m| Protocol.role_name(m.role) }, ["user", "assistant"])
end

# With no client attached, an approval is denied after the timeout, and the model gets the denial as an error.
def test_an_approval_nobody_answers_is_denied_and_sent_back_as_an_error() -> Result[Void]
  h = try H.start(["write_file.sse", "text.sse"], approval_timeout_ms: 200)
  id = try H.new_session(h)
  _ = try H.send(h, id, "Write hello.txt.")
  while (try H.session(h, id)).turn_id.some?
    Task.sleep(50)
  end

  a = try H.subscribe(h, id, some(0))
  a = try H.until(a, Protocol.EventKind.TurnFinished)
  H.close(a)
  resolved = a.seen.select { |s| Protocol.event_name(s.event) == "approval_resolved" }.map { |s| s.event }
  try Test.eq(resolved.size, 1)
  case resolved[0]
    Protocol.Event.ApprovalResolved(r) ->
      try Test.eq([Protocol.decision_name(r.decision), Protocol.source_name(r.source)], ["deny", "timeout"])
    _ -> nil
  end

  second = try H.request_messages(h, 2)
  try H.stop(h)
  content = JSON.string(try JSON.get(second.last, "content")).unwrap_or("")
  try Test.assert(content.include?("denied"), "not a denial: #{content}")
  Test.eq(File.stat("#{h.work}/hello.txt").ok?, false)
end

# A stop kills the running bash, ends the turn and leaves no unfinished call in the history.
def test_stop_during_a_long_bash_ends_the_turn() -> Result[Void]
  h = try H.start(["slow_bash.sse", "text.sse"])
  id = try H.new_session(h)
  a = try H.subscribe(h, id)
  _ = try H.send(h, id, "Sleep.")
  a = try H.until(a, Protocol.EventKind.ApprovalRequested)
  _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
  a = try H.until(a, Protocol.EventKind.ApprovalResolved)
  started = Time.monotonic_ms
  try Test.eq((try H.post(h, Protocol.stop_path(id), "")).status, 200)
  a = try H.until(a, Protocol.EventKind.TurnFinished)
  try Test.eq(H.stop_reason(a), "cancelled")
  try Test.assert(Time.monotonic_ms - started < 5000, "the stop took too long")
  try Test.eq((try H.send(h, id, "Hello again.")).status, 202)
  a = try H.until(a.with(seen: []), Protocol.EventKind.TurnFinished)
  H.close(a)
  second = try H.request_messages(h, 2)
  try H.stop(h)
  roles = second.map { |m| JSON.string(JSON.get(m, "role").unwrap_or(JSON.from(""))).unwrap_or("") }
  Test.eq(roles, ["system", "user", "user"])
end

# The running turn is kept whole, past the size of the buffer: an attach from `turn_from_event_id` replays all of it,
# and a `Last-Event-ID` older than what the server keeps gets `resync`.
def test_a_mid_turn_attach_replays_the_whole_turn() -> Result[Void]
  h = try H.start(["text.sse", "long_text_then_write.sse", "text.sse"], keep_events: 4)
  id = try H.new_session(h)
  a = try H.subscribe(h, id)
  _ = try H.send(h, id, "Hello.")
  a = try H.until(a, Protocol.EventKind.TurnFinished)
  _ = try H.send(h, id, "Write long.txt.")
  a = try H.until(a.with(seen: []), Protocol.EventKind.ApprovalRequested)
  snapshot = try H.session(h, id)
  from = try snapshot.turn_from_event_id.to_result("no turn runs")
  late = try H.until(try H.subscribe(h, id, some(from)), Protocol.EventKind.ApprovalRequested)
  old = try H.until(try H.subscribe(h, id, some(1)), Protocol.EventKind.Resync)
  H.close(late)
  H.close(old)
  H.close(a)
  try H.stop(h)
  try Test.assert(late.seen.size > 4, "the turn is shorter than the buffer")
  try Test.eq(H.kinds(late.seen).first, "turn_started")
  try Test.eq(late.seen.map { |s| s.id }, a.seen.map { |s| s.id })
  try Test.eq(snapshot.pending_approvals.map { |p| p.tool }, ["write_file"])
  Test.eq(H.kinds(old.seen), ["resync"])
end

def test_three_identical_rounds_stop_the_turn() -> Result[Void]
  h = try H.start(["read_file.sse", "read_file.sse", "read_file.sse", "text.sse"])
  id = try H.new_session(h)
  a = try H.subscribe(h, id)
  _ = try H.send(h, id, "Read missing.txt.")
  a = try H.until(a, Protocol.EventKind.TurnFinished)
  H.close(a)
  try H.stop(h)
  try Test.eq(H.stop_reason(a), "loop_guard")
  Test.eq(H.kinds(a.seen).select { |k| k == "tool_finished" }.size, 3)
end

def test_requests_need_the_token_a_local_host_and_no_foreign_origin() -> Result[Void]
  h = try H.start([])
  health = Protocol.HEALTH_PATH
  try Test.eq((try H.get(h, health)).status, 200)
  try Test.eq((try H.call(h, "GET", health, "", [])).status, 401)
  wrong = [HTTP.Header(name: "Authorization", value: "Bearer nope")]
  try Test.eq((try H.call(h, "GET", health, "", wrong)).status, 401)
  foreign = H.auth(h).push(HTTP.Header(name: "Origin", value: "http://evil.example"))
  try Test.eq((try H.call(h, "GET", health, "", foreign)).status, 403)
  own = H.auth(h).push(HTTP.Header(name: "Origin", value: "http://127.0.0.1:#{h.server.port}"))
  try Test.eq((try H.call(h, "GET", health, "", own)).status, 200)
  try Test.eq(try raw_status(h, "evil.example:#{h.server.port}"), "HTTP/1.1 403 Forbidden")
  info = try Protocol.decode_server_info(try File.read_text("#{h.state_dir}/server.json"))
  try Test.eq([info.port, info.pid], [h.server.port, System.pid])
  try Test.eq(info.token, h.token)
  try Test.eq((try File.stat("#{h.state_dir}/server.json")).mode % 512, 384)
  try Test.eq((try File.stat(h.state_dir)).mode % 512, 448)
  second = Server.start(
    Server.Options(state_dir: h.state_dir, provider: h.provider, model: "m", env: &H.fake_env, rules: H.no_rules()),
  )

  try H.stop(h)
  Test.error?(second)
end

private

def tool_event?(event: Protocol.Event) -> Bool
  ["tool_started", "tool_finished", "approval_requested", "approval_resolved"].include?(Protocol.event_name(event))
end

# The client always sends its own `Host`, so this one goes over a plain socket.
def raw_status(h: H.Harness, host: String) -> Result[String]
  socket = try TCP.connect("127.0.0.1", h.server.port, 5000)
  request = "GET #{Protocol.HEALTH_PATH} HTTP/1.1\r\nHost: #{host}\r\nAuthorization: Bearer #{h.token}\r\n\r\n"
  try TCP.send(socket, request, 5000)
  line = TCP.read_line(socket, 5000)
  TCP.close(socket)
  line
end
