import Protocol from "pkg/protocol/protocol"
import Folder from "../src/session/folder"
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
    Test.eq(H.said(snapshot.history).map { |m| Protocol.role_name(m.role) }, ["user", "assistant"])
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
    Task.sleep(1200)
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
  H.using(H.Setup(replies: ["write_file.sse", "text.sse"], approval_timeout_ms: 800)) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    H.close(a)
    Task.sleep(300)
    b = try H.subscribe(h, id)
    Task.sleep(1200)
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

# A stop for a turn that is not the running one stops nothing; one for the running turn stops it.
def test_a_stop_for_another_turn_stops_nothing() -> Result[Void]
  H.using(H.Setup(replies: ["write_file.sse"])) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    turn_id = (try H.session(h, id)).turn_id
    other = Protocol.encode_stop_turn(Protocol.StopTurn(turn_id: some("t-gone")))
    missed = try H.post(h, Protocol.stop_path(id), other)
    try Test.eq([missed.status.to_s, missed.text], ["200", Protocol.encode_stopped(Protocol.Stopped(stopped: false))])
    try Test.eq((try H.session(h, id)).turn_id, turn_id)
    try Test.eq((try H.post(h, Protocol.stop_path(id), "{\"turn\": 1}")).status, 400)
    hit = try H.post(h, Protocol.stop_path(id), Protocol.encode_stop_turn(Protocol.StopTurn(turn_id: turn_id)))
    try Test.eq(hit.text, Protocol.encode_stopped(Protocol.Stopped(stopped: true)))
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    Test.eq(H.stop_reason(a), "cancelled")
  end
end

# The files of the session folder, for a client's `@` list: breadth first, without hidden files, the folders of
# dependencies, links (to a file, to a folder outside, or up out of the folder) and what a `read_file` deny rule hides;
# cut at MAX_FILES.
def test_the_files_route_lists_the_session_folder() -> Result[Void]
  H.using(H.Setup(replies: [], deny: ["read_file(secrets/**)"])) do |h|
    root = "#{h.work}/project"
    outside = "#{h.work}/outside"
    for dir in [root, outside, "#{root}/src", "#{root}/node_modules", "#{root}/.git", "#{root}/secrets", "#{root}/sub"]
      try Dir.mkdir(dir)
    end

    for file in ["b.txt", "a.txt", ".env", "src/main.agc", "node_modules/x.js", ".git/HEAD", "secrets/key.txt"]
      try File.write_text("#{root}/#{file}", "x")
    end

    try File.write_text("#{outside}/secret.txt", "x")
    try link(outside, "#{root}/out_dir")
    try link("#{root}/a.txt", "#{root}/linked.txt")
    try link("../../outside", "#{root}/sub/up")
    id = try H.new_session_in(h, root)
    answer = try H.get(h, Protocol.files_path(id))
    try Test.eq(answer.status, 200)
    whole = Protocol.FileList(files: ["a.txt", "b.txt", "src/main.agc"], truncated: false)
    try Test.eq(Protocol.decode_file_list(answer.text), ok(whole))
    try Test.eq((try H.get(h, Protocol.files_path("s-none"))).status, 404)
    many = "#{h.work}/many"
    try Dir.mkdir(many)
    for i in 0..Folder.MAX_FILES
      try File.write_text("#{many}/f#{i}", "")
    end

    cut = try Protocol.decode_file_list((try H.get(h, Protocol.files_path(try H.new_session_in(h, many)))).text)
    try Test.eq([cut.files.size.to_s, cut.truncated.to_s], [Folder.MAX_FILES.to_s, "true"])
    Test.eq(Folder.files(many, none, 0), Protocol.FileList(files: [], truncated: true))
  end
end

# A files command only proposes paths: a file stays only when the walk could show it, so not a deny rule's, a link's,
# one outside the folder, a folder, or a name not in UTF-8 or with a control character. Endless output is cut. A
# command that fails or
# does not end in time gives the walk, with a note.
def test_a_files_command_lists_only_what_the_walk_allows() -> Result[Void]
  setup = H.Setup(
    replies: [],
    deny: ["read_file(secrets/**)", "read_file(private)"],
    files_command: ["sh", "-c", "printf 'x\\377\\n'; cat ../list.txt"],
  )

  H.using(setup) do |h|
    root = "#{h.work}/project"
    outside = "#{h.work}/outside"
    for dir in [root, outside, "#{root}/src", "#{root}/secrets", "#{root}/private"]
      try Dir.mkdir(dir)
    end

    odd = "bad#{String.from_code(27)}.txt"
    for file in ["a.txt", "b.txt", ".env", "src/main.agc", "secrets/key.txt", "private/key.txt", odd]
      try File.write_text("#{root}/#{file}", "x")
    end

    try File.write_text("#{outside}/secret.txt", "x")
    try link(outside, "#{root}/out_dir")
    try link("#{root}/a.txt", "#{root}/linked.txt")
    proposed = ["a.txt", "./b.txt", ".env", "src/main.agc", "secrets/key.txt", "private/key.txt", odd, "linked.txt"]
    proposed = proposed + ["out_dir/secret.txt"]
    proposed = proposed + ["../outside/secret.txt", "#{outside}/secret.txt", "missing.txt", "src", "a.txt"]
    proposed = proposed + ["src//main.agc", "src/../a.txt"]
    try File.write_text("#{h.work}/list.txt", proposed.join("\n") + "\n")
    id = try H.new_session_in(h, root)
    answer = try Protocol.decode_file_list((try H.get(h, Protocol.files_path(id))).text)
    try Test.eq(answer, Protocol.FileList(files: ["a.txt", "b.txt", ".env", "src/main.agc"]))
    walk = Folder.files(root, none)
    failed = Folder.listed(root, none, ["false"], &unset)
    slow = Folder.listed(root, none, ["sleep", "5"], &unset, 100)
    endless = Folder.listed(root, none, ["yes", "a.txt"], &unset)
    try Test.eq(endless, Protocol.FileList(files: ["a.txt"], truncated: true))
    try Test.eq([failed.files, slow.files], [walk.files, walk.files])
    Test.eq(
      [failed.note, slow.note],
      [
        "files.command failed, so the built-in walk listed the files: exit code 1",
        "files.command failed, so the built-in walk listed the files: it did not end in time",
      ],
    )
  end
end

# What a files command starts is killed when the list is read, when it is cut and when it runs out of time: nothing is
# left behind, and the cut list and the timeout still say so.
def test_a_files_command_leaves_no_process_behind() -> Result[Void]
  base = "#{System.env("TMPDIR").unwrap_or("/tmp")}/core-files-#{Random.int(0, 999_999_999)}"
  root = "#{base}/project"
  try Dir.mkdir(base)
  try Dir.mkdir(root)
  try File.write_text("#{root}/a.txt", "x")
  left = ["sh", "-c", "trap '' TERM; sleep 60 >/dev/null & echo $! > ../left.pid; echo a.txt"]
  done = Folder.listed(root, none, left, &unset)
  cut = Folder.listed(root, none, ["sh", "-c", "trap '' TERM; echo $$ > ../cut.pid; yes a.txt | cat"], &unset)
  slow = Folder.listed(root, none, ["sh", "-c", "trap '' TERM; echo $$ > ../slow.pid; sleep 60"], &unset, 300)
  pids: List[String] = []
  for name in ["left", "cut", "slow"]
    pids = pids.push((try File.read_text("#{base}/#{name}.pid")).strip)
  end

  gone = pids.map { |pid| gone?(pid) }
  _ = Path.remove(base)
  try Test.eq([done, cut], [Protocol.FileList(files: ["a.txt"]), Protocol.FileList(files: ["a.txt"], truncated: true)])
  try Test.eq(slow.note, "files.command failed, so the built-in walk listed the files: it did not end in time")
  Test.eq(gone, [true, true, true])
end

# A killed process goes once its new parent has reaped it.
def gone?(pid: String) -> Bool
  deadline = Time.monotonic_ms + 5000
  while Time.monotonic_ms < deadline
    return true if try_kill(pid) != 0
  end

  false
end

def try_kill(pid: String) -> Int
  case Process.spawn("/bin/sh", ["-c", "kill -0 \"$1\" 2>/dev/null", "sh", pid])
    ok(check) ->
      code = Process.wait(check, 1000).unwrap_or(1)
      Process.close(check)
      code
    error(_) -> 1
  end
end

def unset(_name: String) -> Result[String] = error("unset")

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

# A `length` stop in the middle of a call runs no tool and sends no call back; the turn's end names the limit sent,
# `FINN_MAX_TOKENS` here.
def test_a_call_cut_by_max_tokens_is_dropped() -> Result[Void]
  H.using(H.Setup(replies: ["length_tool.sse", "text.sse"], max_tokens: some(500))) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write cut.txt.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    try Test.eq(H.stop_reason(a), "max_tokens")
    try Test.eq(H.turn_max_tokens(a), some(500))
    try Test.eq(JSON.get(try JSON.parse((try H.next_request(h)).body), "max_tokens"), ok(JSON.from(500)))
    try Test.eq(H.kinds(a.seen).select { |k| k == "tool_started" }, [])
    _ = try H.send(h, id, "Go on.")
    a = try H.until(a.with(seen: []), Protocol.EventKind.TurnFinished)
    H.close(a)
    second = try H.request_messages(h, 1)
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

def test_a_turn_can_run_more_than_fifty_tool_rounds() -> Result[Void]
  replies = (1..25).to_a.flat_map { |_| ["read_file.sse", "read_outside.sse"] }
  replies = replies + ["read_file.sse", "text.sse"]
  H.using(H.Setup(replies: replies, approvals: false)) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Read the files.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(H.stop_reason(a), "end_turn")
    Test.eq(H.kinds(a.seen).select { |k| k == "tool_finished" }.size, 51)
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

# A stop that does not cancel waits for the running turn; the sessions are flushed, the server file goes and the port
# is closed.
def test_a_stop_waits_for_the_running_turn_and_removes_the_server_file() -> Result[Void]
  H.using(H.Setup(replies: ["text.sse@hold"])) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Hello.")
    a = try H.until(a, Protocol.EventKind.TurnStarted)
    status = try Protocol.decode_server_status((try H.get(h, Protocol.SERVER_PATH)).text)
    try Test.eq([status.sessions, status.running_turns, status.pid], [1, 1, System.pid])
    asked = try H.post(
      h,
      Protocol.SERVER_STOP_PATH,
      Protocol.encode_stop_server(Protocol.StopServer(now: some(false))),
    )

    try Test.eq(asked.status, 200)
    try Test.eq(Server.stop_requested(h.server), false)
    stopping = Task.spawn(-> { Server.shutdown(h.server, false) })
    H.release(h)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    Task.await(stopping)
    try Test.eq(H.stop_reason(a), "end_turn")
    H.close(a)
    try Test.assert(not File.stat("#{h.state_dir}/server.json").ok?, "server.json is removed")
    Test.assert(not H.get(h, Protocol.HEALTH_PATH).ok?, "the port is closed")
  end
end

def test_a_stop_with_now_cancels_the_running_turn() -> Result[Void]
  H.using(H.Setup(replies: ["text.sse@hold"])) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Hello.")
    a = try H.until(a, Protocol.EventKind.TurnStarted)
    asked = try H.post(h, Protocol.SERVER_STOP_PATH, Protocol.encode_stop_server(Protocol.StopServer(now: some(true))))
    try Test.eq(asked.status, 200)
    try Test.eq(Server.stop_requested(h.server), true)
    Server.shutdown(h.server, true)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(H.stop_reason(a), "cancelled")
    Test.assert(not File.stat("#{h.state_dir}/server.json").ok?, "server.json is removed")
  end
end

# The stop keeps answering while the turn runs, refuses new work with 503, waits for the turn (longer than the time the
# connections get at the end) and shows its `turn_finished` to the client that watches.
def test_a_stop_drains_a_turn_longer_than_the_shutdown_time_and_refuses_new_work() -> Result[Void]
  H.using(H.Setup(replies: ["text.sse@hold"])) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Hello.")
    a = try H.until(a, Protocol.EventKind.TurnStarted)
    _ = try H.post(h, Protocol.SERVER_STOP_PATH, Protocol.encode_stop_server(Protocol.StopServer(now: some(false))))
    stopping = Task.spawn(-> { Server.shutdown(h.server, Server.stop_requested(h.server), 300) })
    Task.sleep(700)
    status = try Protocol.decode_server_status((try H.get(h, Protocol.SERVER_PATH)).text)
    try Test.eq(status.running_turns, 1)
    refused = try H.post(
      h,
      Protocol.messages_path(id),
      Protocol.encode_send_message(Protocol.SendMessage(text: "More.")),
    )

    try Test.eq(refused.status, 503)
    try Test.eq((try Protocol.decode_failure(refused.text)).kind, Protocol.KIND_SERVER_STOPPING)
    try Test.eq((try H.post(h, Protocol.SESSIONS_PATH, "{}")).status, 503)
    try Test.eq((try H.get(h, Protocol.session_path(id))).status, 200)
    H.release(h)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    Task.await(stopping)
    H.close(a)
    try Test.eq(H.stop_reason(a), "end_turn")
    Test.assert(not File.stat("#{h.state_dir}/server.json").ok?, "server.json is removed")
  end
end

# A second stop, with `now`, while the first waits for the turn, cancels it.
def test_a_stop_that_waits_is_escalated_by_a_stop_with_now() -> Result[Void]
  H.using(H.Setup(replies: ["text.sse@hold"])) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Hello.")
    a = try H.until(a, Protocol.EventKind.TurnStarted)
    _ = try H.post(h, Protocol.SERVER_STOP_PATH, Protocol.encode_stop_server(Protocol.StopServer(now: some(false))))
    stopping = Task.spawn(-> { Server.shutdown(h.server, Server.stop_requested(h.server)) })
    status = try Protocol.decode_server_status((try H.get(h, Protocol.SERVER_PATH)).text)
    try Test.eq(status.running_turns, 1)
    again = try H.post(h, Protocol.SERVER_STOP_PATH, Protocol.encode_stop_server(Protocol.StopServer(now: some(true))))
    try Test.eq(again.status, 200)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    Task.await(stopping)
    H.close(a)
    Test.eq(H.stop_reason(a), "cancelled")
  end
end

# A turn that waits for an approval counts as ended: the stop does not wait for an answer nobody gives.
def test_a_stop_does_not_wait_for_an_approval() -> Result[Void]
  H.using(H.Setup(replies: ["write_file.sse", "text.sse"], drain_ms: 30_000)) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    Server.shutdown(h.server, false)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    Test.eq(H.stop_reason(a), "cancelled")
  end
end

# `stop_requested` waits again after its time, so a server never stops by itself.
def test_stop_requested_waits_again_after_its_time() -> Result[Void]
  H.using(H.Setup(replies: [])) do |h|
    answers: Channel[Bool] = Channel.new(1)
    waiting = Task.spawn(
      -> {
        _ = answers.send(Server.stop_requested(h.server, 20), 5000)
        ok()
      },
    )

    Task.sleep(150)
    try Test.error?(answers.recv(0))
    Server.request_stop(h.server, true)
    try Test.eq(answers.recv(2000), ok(true))
    Task.await(waiting)
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
        providers: h.providers,
        provider: h.provider,
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
      providers: h.providers,
      provider: h.provider,
      model: "m",
      env: &H.fake_env,
    )

    try Test.error?(Server.start(options))
    try linked_folder(h)
    foreign_owner(h)
  end
end

# A link to a private folder of ours is refused, and so is a link to nothing, which is not made into a folder.
def linked_folder(h: H.Harness) -> Result[Void]
  target = "#{h.base}/real-state"
  try Dir.mkdir_private(target)
  try link(target, "#{h.base}/linked-state")
  try link("#{h.base}/nothing", "#{h.base}/dangling-state")
  try refused_link(h, "#{h.base}/linked-state")
  refused_link(h, "#{h.base}/dangling-state")
end

def refused_link(h: H.Harness, state_dir: String) -> Result[Void]
  options = Config.Options(
    state_dir: state_dir,
    data_dir: "#{h.base}/data",
    providers: h.providers,
    provider: h.provider,
    model: "m",
    env: &H.fake_env,
  )

  started = Server.start(options)
  if started.ok?
    Server.stop(started.unwrap!)
  end

  case started
    ok(_) -> Test.assert(false, "a link to a folder was taken")
    error(e) -> Test.assert(e.message.include?("is a link"), e.message)
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
    providers: h.providers,
    provider: h.provider,
    model: "m",
    env: &H.fake_env,
  )

  case Server.start(options)
    ok(_) -> Test.assert(false, "a folder of another user was taken")
    error(e) -> Test.assert(e.message.include?("not owned by you"), e.message)
  end
end

# With the approvals on, a bash command that only reads asks like any other; a deny rule refuses it without asking.
def test_a_read_only_command_asks_and_a_deny_rule_refuses_it() -> Result[Void]
  try H.using(H.Setup(replies: ["bash_read.sse", "text.sse"])) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Show hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Deny)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    Test.eq(H.kinds(a.seen).select { |k| k == "approval_requested" }.size, 1)
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
