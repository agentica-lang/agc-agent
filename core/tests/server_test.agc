import Protocol from "pkg/protocol/protocol"
import Config from "../src/config/config"
import Server from "../src/http/server"
import H from "support/harness"

# The model writes a file, then runs bash on it, then answers. Two clients see the same events, and the first answer to
# an approval wins.
def test_a_turn_runs_tools_after_approvals_for_two_clients() -> Result[Void]
  H.using(H.Setup(replies: ["write_file.sse", "bash.sse", "text.sse"])) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    b = try H.subscribe(h, id)
    sent = try H.send(h, id, "Write hello.txt, then show it.")
    try Test.eq(sent.status, 202)
    try Test.assert(
      (try Protocol.decode_message_accepted(sent.text)).turn_id.start_with?("turn-1-"),
      "a numbered turn",
    )

    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    write = try H.approval(a)
    try Test.eq([write.tool, write.preview, write.detail], ["write_file", "hello.txt", "hi\n"])
    try Test.eq((try H.approve(h, id, write.approval_id, Protocol.Decision.Allow)).status, 200)
    late = try H.approve(h, id, write.approval_id, Protocol.Decision.Deny)
    try Test.eq(late.status, 409)
    try Test.eq((try Protocol.decode_failure(late.text)).kind, Protocol.KIND_APPROVAL_RESOLVED)
    a = try H.until(a.with(seen: []), Protocol.EventKind.ApprovalRequested)
    bash = try H.approval(a)
    try Test.eq([bash.tool, bash.preview], ["bash", "cat hello.txt | tee copy.txt"])
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
    try Test.eq(snapshot.turn_id, none)
    Test.eq(snapshot.history.map { |m| Protocol.role_name(m.role) }, ["user", "assistant"])
  end
end

# Without the approval extension, the calls run without asking.
def test_without_the_approval_extension_every_call_runs() -> Result[Void]
  H.using(H.Setup(replies: ["write_file.sse", "bash.sse", "text.sse"], approvals: false)) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt, then show it.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(H.kinds(a.seen).select { |k| k.start_with?("approval_") }, [])
    try Test.eq(finished_ok(a), [true, true])
    Test.eq(File.read_text("#{h.work}/copy.txt"), ok("hi\n"))
  end
end

# With no client attached, an approval is denied after the timeout, and the model gets the denial as an error.
def test_an_approval_nobody_answers_is_denied_and_sent_back_as_an_error() -> Result[Void]
  H.using(H.Setup(replies: ["write_file.sse", "text.sse"], approval_timeout_ms: 200)) do |h|
    id = try H.new_session(h)
    _ = try H.send(h, id, "Write hello.txt.")
    _ = try H.idle(h, id)
    a = try H.until(try H.subscribe(h, id, some(0)), Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(H.resolved_by(a), ["deny timeout"])
    second = try H.request_messages(h, 2)
    content = JSON.string(try JSON.get(second.last, "content")).unwrap_or("")
    try Test.assert(content.include?("denied"), "not a denial: #{content}")
    Test.eq(File.stat("#{h.work}/hello.txt").ok?, false)
  end
end

# The timeout runs only while no client is attached: from when the last one leaves.
def test_an_approval_waits_for_an_attached_client_and_times_out_after_it_leaves() -> Result[Void]
  H.using(H.Setup(replies: ["write_file.sse", "text.sse"], approval_timeout_ms: 800)) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    Task.sleep(1500)
    try Test.eq((try H.session(h, id)).pending_approvals.size, 1)
    H.close(a)
    Task.sleep(300)
    try Test.eq((try H.session(h, id)).pending_approvals.size, 1)
    _ = try H.idle(h, id)
    replay = try H.until(try H.subscribe(h, id, some(0)), Protocol.EventKind.TurnFinished)
    H.close(replay)
    Test.eq(H.resolved_by(replay), ["deny timeout"])
  end
end

# A client that attaches before the timeout stops it; it starts again when that client leaves.
def test_a_new_client_stops_the_approval_timeout() -> Result[Void]
  H.using(H.Setup(replies: ["write_file.sse", "text.sse"], approval_timeout_ms: 2500)) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    H.close(a)
    Task.sleep(1300)
    b = try H.subscribe(h, id)
    Task.sleep(4000)
    try Test.eq((try H.session(h, id)).pending_approvals.size, 1)
    H.close(b)
    _ = try H.idle(h, id)
    replay = try H.until(try H.subscribe(h, id, some(0)), Protocol.EventKind.TurnFinished)
    H.close(replay)
    Test.eq(H.resolved_by(replay), ["deny timeout"])
  end
end

# A stop kills the running bash, ends the turn and leaves no unfinished call in the history.
def test_stop_during_a_long_bash_kills_it_and_ends_the_turn() -> Result[Void]
  H.using(H.Setup(replies: ["slow_bash.sse", "text.sse"])) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Sleep.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    pid = try wait_pid("#{h.work}/pid.txt")
    try Test.eq(try alive?(pid), true)
    started = Time.monotonic_ms
    try Test.eq((try H.post(h, Protocol.stop_path(id), "")).status, 200)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    try Test.eq(H.stop_reason(a), "cancelled")
    try Test.assert(Time.monotonic_ms - started < 5000, "the stop took too long")
    try Test.eq(try gone(pid), true)
    try Test.eq((try H.send(h, id, "Hello again.")).status, 202)
    a = try H.until(a.with(seen: []), Protocol.EventKind.TurnFinished)
    H.close(a)
    second = try H.request_messages(h, 2)
    roles = second.map { |m| JSON.string(JSON.get(m, "role").unwrap_or(JSON.from(""))).unwrap_or("") }
    Test.eq(roles, ["system", "user", "user"])
  end
end

def test_stop_while_an_approval_waits_denies_it() -> Result[Void]
  H.using(H.Setup(replies: ["write_file.sse"])) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    _ = try H.post(h, Protocol.stop_path(id), "")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(H.resolved_by(a), ["deny stop"])
    try Test.eq(H.kinds(a.seen).drop(a.seen.size - 2), ["approval_resolved", "turn_finished"])
    Test.eq(H.stop_reason(a), "cancelled")
  end
end

# `allow_session` allows the same tool on the same target; another bash command asks again.
def test_allow_session_allows_the_same_command_only() -> Result[Void]
  H.using(H.Setup(replies: ["bash.sse", "bash.sse", "bash_echo.sse", "text.sse"])) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Show hello.txt twice, then echo.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.AllowSession)
    a = try H.until(a.with(seen: []), Protocol.EventKind.ApprovalRequested)
    echo = try H.approval(a)
    try Test.eq(echo.preview, "echo other | tee other.txt")
    try Test.eq(H.kinds(a.seen).select { |k| k == "tool_finished" }.size, 2)
    _ = try H.approve(h, id, echo.approval_id, Protocol.Decision.Allow)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    Test.eq(H.stop_reason(a), "end_turn")
  end
end

# A `length` stop in the middle of a call runs no tool and sends no call back.
def test_a_call_cut_by_max_tokens_is_dropped() -> Result[Void]
  H.using(H.Setup(replies: ["length_tool.sse", "text.sse"])) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write cut.txt.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    try Test.eq(H.stop_reason(a), "max_tokens")
    try Test.eq(H.kinds(a.seen).select { |k| k == "tool_started" }, [])
    _ = try H.send(h, id, "Go on.")
    a = try H.until(a.with(seen: []), Protocol.EventKind.TurnFinished)
    H.close(a)
    second = try H.request_messages(h, 2)
    try Test.eq(second.map { |m| JSON.get(m, "tool_calls").ok? }, [false, false, false, false])
    Test.eq(JSON.get(second[2], "content"), ok(JSON.from("Writing it now.")))
  end
end

# The running turn is kept whole, past the size of the buffer: an attach from `turn_from_event_id` replays all of it,
# and a `Last-Event-ID` older than what the server keeps gets `resync`.
def test_a_mid_turn_attach_replays_the_whole_turn() -> Result[Void]
  H.using(H.Setup(replies: ["text.sse", "long_text_then_write.sse", "text.sse"], keep_events: 4)) do |h|
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
    try Test.assert(late.seen.size > 4, "the turn is shorter than the buffer")
    try Test.eq(H.kinds(late.seen).first, "turn_started")
    try Test.eq(late.seen.map { |s| s.id }, a.seen.map { |s| s.id })
    try Test.eq(snapshot.pending_approvals.map { |p| p.tool }, ["write_file"])
    Test.eq(H.kinds(old.seen), ["resync"])
  end
end

def test_three_identical_rounds_stop_the_turn() -> Result[Void]
  H.using(H.Setup(replies: ["read_file.sse", "read_file.sse", "read_file.sse", "text.sse"])) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Read missing.txt.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(H.stop_reason(a), "loop_guard")
    Test.eq(H.kinds(a.seen).select { |k| k == "tool_finished" }.size, 3)
  end
end

# AGENTS.md goes into the system prompt only when it is a regular file of the folder (not a link out of it, not a
# FIFO), cut at 64 KB.
def test_agents_md_is_read_only_inside_the_folder() -> Result[Void]
  H.using(H.Setup(replies: ["text.sse", "text.sse", "text.sse"])) do |h|
    try File.write_text("#{h.base}/secret.txt", "TOP SECRET")
    try link("#{h.base}/secret.txt", "#{h.work}/AGENTS.md")
    fifo = "#{h.base}/fifo"
    try Dir.mkdir(fifo)
    _ = try run("mkfifo", ["#{fifo}/AGENTS.md"])
    big = "#{h.base}/big"
    try Dir.mkdir(big)
    try File.write_text("#{big}/AGENTS.md", "Use tabs.\n#{(1..70_000).map { |_i| "x" }.join("")}END")
    for cwd in [h.work, fifo, big]
      id = try H.new_session_in(h, cwd)
      _ = try H.send(h, id, "Hello.")
      _ = try H.idle(h, id)
    end

    linked = system_text(try H.request_messages(h, 1))
    piped = system_text(try H.request_messages(h, 1))
    cut = system_text(try H.request_messages(h, 1))
    try Test.assert(not linked.include?("TOP SECRET"), "the secret reached the model")
    try Test.assert(not piped.include?("AGENTS.md of the session folder"), "the FIFO was read")
    try Test.assert(cut.include?("Use tabs.") and not cut.include?("END"), "AGENTS.md was not cut")
    Test.assert(cut.bytesize < 70_000, "AGENTS.md was not cut")
  end
end

def test_the_server_keeps_its_state_folder_private_and_runs_once() -> Result[Void]
  H.using(H.Setup(replies: [])) do |h|
    health = Protocol.HEALTH_PATH
    try Test.eq((try H.get(h, health)).status, 200)
    try Test.eq((try H.call(h, "GET", health, "", [])).status, 401)
    info = try Protocol.decode_server_info(try File.read_text("#{h.state_dir}/server.json"))
    try Test.eq([info.port, info.pid], [h.server.port, System.pid])
    try Test.eq(info.token, h.token)
    try Test.eq((try File.stat("#{h.state_dir}/server.json")).mode % 512, 384)
    try Test.eq((try File.stat(h.state_dir)).mode % 512, 448)
    second = Server.start(
      Config.Options(
        state_dir: h.state_dir,
        data_dir: h.data_dir,
        apis: h.apis,
        api: "openai",
        model: "m",
        env: &H.fake_env,
      ),
    )

    try Test.error?(second)
    open_data = "#{h.base}/open-data"
    try Dir.mkdir("#{open_data}/sessions")
    try Test.eq(try H.run("chmod", ["700", open_data]), 0)
    try Test.eq(try H.run("chmod", ["755", "#{open_data}/sessions"]), 0)
    options = Config.Options(
      state_dir: "#{h.base}/other-state",
      data_dir: open_data,
      apis: h.apis,
      api: "openai",
      model: "m",
      env: &H.fake_env,
    )

    try Test.error?(Server.start(options))
    foreign_owner(h)
  end
end

# A private folder of another user (`/root` when it is there and not ours) is refused for that reason.
def foreign_owner(h: H.Harness) -> Result[Void]
  root = File.stat("/root")
  mine = File.stat("/proc/self")
  return ok() if not root.ok? or not mine.ok?
  return ok() if root.unwrap!.user_id == mine.unwrap!.user_id or root.unwrap!.mode % 64 != 0

  options = Config.Options(
    state_dir: "/root",
    data_dir: "#{h.base}/data",
    apis: h.apis,
    api: "openai",
    model: "m",
    env: &H.fake_env,
  )

  case Server.start(options)
    ok(_) -> Test.assert(false, "a folder of another user was taken")
    error(e) -> Test.assert(e.message.include?("not owned by you"), e.message)
  end
end

# A bash command that only reads runs without asking; a deny rule of one of its commands still refuses it.
def test_a_read_only_command_runs_without_asking_unless_denied() -> Result[Void]
  try H.using(H.Setup(replies: ["write_file.sse", "bash_read.sse", "text.sse"])) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt, then show it.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(H.kinds(a.seen).select { |k| k == "approval_requested" }.size, 1)
    Test.eq(finished_ok(a), [true, true])
  end

  H.using(H.Setup(replies: ["bash_read.sse", "text.sse"], deny: ["bash(cat *)"])) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Show hello.txt.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(H.kinds(a.seen).select { |k| k == "approval_requested" }.size, 0)
    Test.eq(finished_ok(a), [false])
  end
end

private

def tool_event?(event: Protocol.Event) -> Bool
  ["tool_started", "tool_finished", "approval_requested", "approval_resolved"].include?(Protocol.event_name(event))
end

def system_text(messages: List[JSON.Value]) -> String
  JSON.string(JSON.get(messages[0], "content").unwrap_or(JSON.from(""))).unwrap_or("")
end

def link(target: String, path: String) -> Result[Void]
  _ = try run("ln", ["-s", target, path])
  ok()
end

def run(program: String, args: List[String]) -> Result[Int]
  process = try Process.spawn(program, args)
  code = Process.wait(process, 5000)
  Process.close(process)
  code
end

def wait_pid(path: String) -> Result[String]
  for _i in 1..100
    case File.read_text(path)
      ok(text) if not text.strip.empty? -> return ok(text.strip)
      _ -> Task.sleep(50)
    end
  end

  error("no pid in #{path}")
end

def alive?(pid: String) -> Result[Bool] = ok(try run("kill", ["-0", pid]) == 0)

def gone(pid: String) -> Result[Bool]
  for _i in 1..40
    return ok(true) if not try alive?(pid)

    Task.sleep(50)
  end

  ok(false)
end

def finished_ok(sub: H.Sub) -> List[Bool]
  out: List[Bool] = []
  for seen in sub.seen
    case seen.event
      Protocol.Event.ToolFinished(done) -> out = out.push(done.ok)
      _ -> nil
    end
  end

  out
end
