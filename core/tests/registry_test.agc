## The registry of `Core.serve`, in a server: a prompt after the system prompt, handlers of events, wrappers of the runs
## of the tools, and services. The code of an extension that crashes or hangs fails its call, never the session.

import Protocol from "pkg/protocol/protocol"
import Core from "../core"
import Extensions from "../src/config/registry"
import Spec from "../src/tools/spec"
import Tools from "../src/tools/tools"
import Fake from "support/fake_llm"
import H from "support/harness"

HOOKED = "echo hooked | tee other.txt"

# The model gets the prompt of the extension after the system prompt, and the message as the handler changed it; the
# session keeps what the user typed. A handler that crashes refuses its message and the session goes on.
def test_message_handlers_change_the_message_or_refuse_it() -> Result[Void]
  registry = (
    Core.registry()
    |> Core.add_prompt("Answer in one line.")
    |> Core.on(Core.Event.Message(->(text: String) { "#{text} (asked in a test)" }))
    |> Core.on(Core.Event.Message(&crash_on_boom))
  )

  H.using(H.Setup(replies: ["text.sse"], registry: some(registry))) do |h|
    id = try H.new_session(h)
    refused = try H.send(h, id, "boom")
    try Test.eq(refused.status, 400)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Hi.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    body = (try Fake.next_request(h.fake)).body
    try Test.assert(body.include?("Answer in one line."), "the prompt: #{body}")
    try Test.assert(body.include?("Hi. (asked in a test)"), "the message: #{body}")
    Test.assert(not body.include?("boom"), "the refused message: #{body}")
  end
end

# A `ToolBefore` handler changes a call before anything else sees it: the approval asks about the new input, and the
# tool runs on it.
def test_a_tool_before_handler_changes_what_the_approval_sees_and_what_runs() -> Result[Void]
  calls: Channel[String] = Channel.new(4)
  registry = Core.registry() |> Core.on(Core.Event.ToolBefore(->(call: Core.ToolCall) { hooked(calls, call) }))
  H.using(H.Setup(replies: ["bash_echo.sse", "text.sse"], registry: some(registry))) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Echo.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    asked = try H.approval(a)
    _ = try H.approve(h, id, asked.approval_id, Protocol.Decision.Allow)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(calls.recv(0), ok("#{id} bash"))
    try Test.eq(asked.preview, HOOKED)
    Test.eq(File.read_text("#{h.work}/other.txt"), ok("hooked\n"))
  end
end

# A `ToolBefore` handler that stops a call, or crashes, fails it before its approval: the model gets the reason.
def test_a_tool_before_handler_that_stops_or_crashes_fails_the_call() -> Result[Void]
  stop = (
    Core.registry()
    |> Core.on(Core.Event.ToolBefore(->(_call: Core.ToolCall) { Core.Check.Stop("no echo here") }))
  )

  crash = Core.registry() |> Core.on(Core.Event.ToolBefore(->(_call: Core.ToolCall) { crash_check() }))
  try stopped_call(stop, "blocked by an extension: no echo here")
  stopped_call(crash, "a tool_before handler failed: task crashed")
end

# An observer gets the events it names, of every session, in order, and the session's start and end. Nothing waits for
# an observer: one that is stuck until the end still lets the turn end, and loses the events past its inbox.
def test_observers_see_the_events_in_order_and_never_slow_a_turn() -> Result[Void]
  names = ["session_started", "turn_started", "tool_finished", "turn_finished", "session_ended"]
  got: Channel[String] = Channel.new(32)
  stuck_got: Channel[String] = Channel.new(32)
  gate: Channel[Bool] = Channel.new(1)
  registry = (
    Core.registry().with(observer_inbox: 1, handler_ms: 10_000)
    |> Core.on(Core.Event.Seen(names, ->(seen: Core.Seen) { observed_as(got, seen) }))
    |> Core.on(Core.Event.Seen(names, ->(seen: Core.Seen) { stuck(stuck_got, gate, seen) }))
  )

  H.using(H.Setup(replies: ["read_file.sse", "text.sse"], registry: some(registry))) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Read a.txt.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq((try H.call(h, "DELETE", Protocol.session_path(id), "", H.auth(h))).status, 200)
    seen = (1..5).to_a.map { |_| got.recv(5000).unwrap_or("none") }
    try Test.eq(
      seen,
      ["session_started #{id} true", "turn_started", "tool_finished", "turn_finished", "session_ended deleted"],
    )

    gate.close
    stuck_seen = [stuck_got.recv(5000).unwrap_or(""), stuck_got.recv(5000).unwrap_or("")]
    try Test.assert(stuck_seen[0] == "session_started" and not stuck_seen[1].empty?, "stuck: #{stuck_seen}")
    Test.assert(not stuck_got.recv(200).ok?, "the stuck observer lost no event")
  end
end

# The events a broken session file could not save reach the observers as they reach the clients, and a server that
# stops ends its sessions.
def test_observers_see_the_unsaved_end_of_a_turn_and_the_stop() -> Result[Void]
  got: Channel[String] = Channel.new(32)
  names = ["turn_started", "error", "turn_finished", "session_ended"]
  registry = Core.registry() |> Core.on(Core.Event.Seen(names, ->(seen: Core.Seen) { observed_as(got, seen) }))
  try H.using(H.Setup(replies: ["write_file.sse", "text.sse"], registry: some(registry))) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    try Test.eq(try H.run("chmod", ["400", H.session_file(h, id)]), 0)
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    Test.eq(try H.run("chmod", ["600", H.session_file(h, id)]), 0)
  end

  seen = (1..4).to_a.map { |_| got.recv(5000).unwrap_or("none") }
  Test.eq(seen, ["turn_started", "error", "turn_finished", "session_ended stopping"])
end

# A message handler that hangs refuses its message too.
def test_a_message_handler_that_hangs_refuses_the_message() -> Result[Void]
  registry = Core.registry().with(handler_ms: 50) |> Core.on(Core.Event.Message(&hang))
  H.using(H.Setup(replies: [], registry: some(registry))) do |h|
    id = try H.new_session(h)
    Test.eq((try H.send(h, id, "Hi.")).status, 400)
  end
end

# The fold handlers get the texts that stay; one that crashes or hangs adds nothing.
def test_fold_handlers_add_their_text_unless_they_fail() -> Result[Void]
  registry = (
    Core.registry().with(handler_ms: 50)
    |> Core.on(Core.Event.Fold(->(staying: List[String]) { "#{staying.size} kept" }))
    |> Core.on(Core.Event.Fold(->(_staying: List[String]) { crash_on_boom("boom") }))
    |> Core.on(Core.Event.Fold(->(_staying: List[String]) { hang("") }))
    |> Core.on(Core.Event.Fold(->(_staying: List[String]) { "" }))
  )

  Test.eq(Extensions.fold(registry, []), "\n\n0 kept")
end

# The first wrapper added is the outermost, around a built-in tool and an MCP tool alike; each gets the tool's name.
def test_wrappers_run_in_order_around_every_tool() -> Result[Void]
  base = try fresh()
  try File.write_text("#{base}/a.txt", "a\n")
  registry = (
    Core.registry()
    |> Core.wrap_tools(tagged("1"))
    |> Core.wrap_tools(tagged("2"))
  )

  echo = Spec.Tool(
    name: "mcp__s__echo",
    description: "",
    input_schema: JSON.object({}),
    asks: false,
    run: ->(_ctx: Spec.Context, _input: JSON.Value) { ok("echo") },
    target: ->(_ctx: Spec.Context, _input: JSON.Value) { ok("") },
  )

  ctx = try Tools.context(base, &unset, [echo], wrap: Extensions.wrap(registry))
  read = Tools.run(ctx, "read_file", JSON.object({"path": JSON.from("a.txt")}))
  mcp = Tools.run(ctx, "mcp__s__echo", JSON.object({}))
  _ = Path.remove(base)
  try Test.assert(read.text.end_with?(" read_file 2] read_file 1]"), read.text)
  Test.eq(mcp.text, "echo mcp__s__echo 2] mcp__s__echo 1]")
end

# A wrapper that crashes or hangs, or an extension tool that crashes, fails the call and nothing else.
def test_a_wrapper_or_a_tool_that_fails_fails_its_call() -> Result[Void]
  base = try fresh()
  crashing = (
    Core.registry()
    |> Core.wrap_tools(->(n: String, _c: Core.Call, _next: Fn[Result[String]]) { ok(crash_on_boom("boom #{n}")) })
  )

  hanging = (
    Core.registry().with(tool_ms: 50)
    |> Core.wrap_tools(->(n: String, _c: Core.Call, _next: Fn[Result[String]]) { ok(hang(n)) })
  )

  tools = Extensions.spec_tools(Core.registry() |> Core.add_tool(crashing_tool()))
  outputs = [
    Tools.run(try Tools.context(base, &unset, wrap: Extensions.wrap(crashing)), "glob", JSON.object({})),
    Tools.run(try Tools.context(base, &unset, wrap: Extensions.wrap(hanging)), "glob", JSON.object({})),
    Tools.run(try Tools.context(base, &unset, tools), "word_count", JSON.object({})),
  ]

  _ = Path.remove(base)
  Test.eq(outputs.map { |o| o.is_error }, [true, true, true])
end

# An extension tool that crashes in a turn ends as a failed tool result, and the turn goes on.
def test_an_extension_tool_that_crashes_fails_in_the_turn() -> Result[Void]
  registry = Core.registry() |> Core.add_tool(crashing_tool())
  H.using(H.Setup(replies: ["word_count.sse", "text.sse"], registry: some(registry))) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Count.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    text = try File.read_text(H.session_file(h, id))
    Test.assert(text.include?("the tool word_count failed: task crashed"), text)
  end
end

# The approval decides on the tool as it is: a deny rule refuses a call that a wrapper would answer by itself.
def test_a_deny_rule_refuses_a_wrapped_tool() -> Result[Void]
  registry = (
    Core.registry()
    |> Core.wrap_tools(->(_n: String, _c: Core.Call, _next: Fn[Result[String]]) { ok("ran by the wrapper") })
  )

  H.using(H.Setup(replies: ["bash_rm.sse", "text.sse"], deny: ["bash(rm *)"], registry: some(registry))) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Remove it.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    text = try File.read_text(H.session_file(h, id))
    Test.eq([text.include?("denied by a rule"), text.include?("ran by the wrapper")], [true, false])
  end
end

# A service starts with the server and stops after the server stops listening, before its files go.
def test_services_stop_after_the_server_stops_listening() -> Result[Void]
  seen: Channel[String] = Channel.new(8)
  where: Channel[String] = Channel.new(1)
  log = Core.Service(name: "log", start: -> { started(seen) }, stop: -> { _ = seen.send(stop_seen(where), 0) })
  registry = Core.registry() |> Core.add_service(log)
  try H.using(H.Setup(replies: [], registry: some(registry), shutdown: true)) do |h|
    _ = where.send(h.state_dir, 0)
    try Test.eq((try H.get(h, "/v1/health")).status, 200)
    Test.eq(seen.recv(0), ok("started"))
  end

  Test.eq(seen.recv(0), ok("server.json there"))
end

# A service that fails stops those started before it, in the reverse order, and the start fails.
def test_a_failed_service_stops_those_started_before_it() -> Result[Void]
  stopped: Channel[String] = Channel.new(4)
  services = ["a", "b"].map do |name|
    Core.Service(name: name, start: -> { ok() }, stop: -> { _ = stopped.send(name, 0) })
  end

  failing = Core.Service(name: "c", start: -> { error("no port") }, stop: -> { _ = stopped.send("c", 0) })
  try Test.eq(Extensions.start_services(services.push(failing)).ok?, false)
  try Test.eq([stopped.recv(100), stopped.recv(100)], [ok("b"), ok("a")])
  Test.error?(stopped.recv(0))
end

# A start or a stop that hangs past its time ends in about that time: its task is cancelled and nothing of it runs
# after.
def test_a_service_that_hangs_is_cancelled_in_its_time() -> Result[Void]
  hang: Channel[Bool] = Channel.new(2)
  seen: Channel[String] = Channel.new(2)
  slow_start = Core.Service(
    name: "slow",
    start: -> {
      _ = hang.recv(60_000)
      _ = seen.send("started late", 0)
      ok()
    },
    stop: -> { nil },
  )

  began = Time.monotonic_ms
  try Test.eq(Extensions.start_services([slow_start], 100).ok?, false)
  start_ms = Time.monotonic_ms - began
  slow_stop = Core.Service(
    name: "stuck",
    start: -> { ok() },
    stop: -> {
      _ = hang.recv(60_000)
      _ = seen.send("stopped late", 0)
    },
  )

  running = try Extensions.start_services([slow_stop], 1000)
  began = Time.monotonic_ms
  Extensions.stop_services(running)
  stop_ms = Time.monotonic_ms - began
  _ = hang.send(true, 0)
  _ = hang.send(true, 0)
  # The stop waits its 1000 ms before it cancels: one that never waits is caught too.
  in_time = start_ms < 1000 and stop_ms >= 900 and stop_ms < 2000
  try Test.assert(in_time, "start took #{start_ms} ms and stop #{stop_ms} ms")
  Test.error?(seen.recv(100))
end

# Names that are taken: a built-in tool, a tool of the core outside `Tools.all`, the MCP prefix, and another extension.
def test_extension_tools_cannot_take_a_name() -> Result[Void]
  registry = Core.registry()
  for name in ["bash", "run_script", "mcp__s__x", "mine", "mine", "theirs"]
    registry = registry |> Core.add_tool(crashing_tool().with(name: name))
  end

  Test.eq(Extensions.clashes(registry, ["bash"]).size, 4)
end

# The handlers of a message share one time budget: two that are each in time but too slow together refuse it, as a
# 400 rather than a session that does not answer.
def test_the_message_handlers_share_one_time_budget() -> Result[Void]
  registry = (
    Core.registry().with(handler_ms: 100)
    |> Core.on(Core.Event.Message(->(text: String) { slow(text, 70) }))
    |> Core.on(Core.Event.Message(->(text: String) { slow(text, 70) }))
  )

  H.using(H.Setup(replies: [], registry: some(registry))) do |h|
    id = try H.new_session(h)
    Test.eq((try H.send(h, id, "Hi.")).status, 400)
  end
end

# A message queued during a turn is accepted already: when its handler fails as the turn takes it, the model gets it
# as typed.
def test_a_queued_message_whose_handler_fails_reaches_the_model_as_typed() -> Result[Void]
  registry = Core.registry() |> Core.on(Core.Event.Message(&crash_on_boom))
  H.using(H.Setup(replies: ["write_file.sse", "text.sse"], registry: some(registry))) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    try Test.eq((try H.send(h, id, "boom later")).status, 202)
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    second = try H.request_messages(h, 2)
    Test.eq(JSON.get(second.last, "content"), ok(JSON.from("boom later")))
  end
end

# A wrapper sees the call, but the run it wraps takes no input: the tool runs on the input the approval saw, so a
# wrapper cannot swap an allowed command for a denied one.
def test_a_wrapper_runs_the_tool_on_the_input_the_approval_saw() -> Result[Void]
  seen: Channel[String] = Channel.new(4)
  registry = (
    Core.registry()
    |> Core.wrap_tools(->(_n: String, call: Core.Call, next: Fn[Result[String]]) { noted(seen, call, next) })
  )

  setup = H.Setup(
    replies: ["bash_echo.sse", "text.sse"],
    approvals: false,
    deny: ["bash(rm *)"],
    registry: some(registry),
  )

  H.using(setup) do |h|
    try File.write_text("#{h.work}/victim.txt", "x\n")
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Echo.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(seen.recv(0), ok("echo other | tee other.txt"))
    Test.eq(
      [File.read_text("#{h.work}/victim.txt"), File.read_text("#{h.work}/other.txt")],
      [ok("x\n"), ok("other\n")],
    )
  end
end

# `Core.resolve` hides what a read deny rule hides, however the path names it: through `.`, `..`, the absolute path or
# a link.
def test_resolve_keeps_the_read_deny_rules() -> Result[Void]
  base = try fresh()
  try File.write_text("#{base}/.env", "KEY=1\n")
  try Dir.mkdir("#{base}/sub")
  _ = try H.run("ln", ["-s", ".env", "#{base}/secret"])
  probe = Core.Tool(
    name: "probe",
    description: "",
    input_schema: JSON.object({}),
    run: ->(call: Core.Call) { Core.resolve(call, try JSON.string(try JSON.get(call.input, "path"))) },
    target: ->(_call: Core.Call) { ok("") },
  )

  open = try Tools.context(base, &unset, Extensions.spec_tools(Core.registry() |> Core.add_tool(probe)))
  denied = open.with(hidden: some(->(path: String) { path == ".env" }))
  paths = [".env", "./.env", "sub/../.env", "#{base}/.env", "secret"]
  results = [open, denied].map do |ctx|
    paths.map { |path| Tools.run(ctx, "probe", JSON.object({"path": JSON.from(path)})).is_error }
  end

  _ = Path.remove(base)
  Test.eq(results, [[false, false, false, false, false], [true, true, true, true, true]])
end

# A service runs in a task of its own from its start to its stop: a file it opens at the start is still open at the
# stop.
def test_a_service_keeps_what_it_opened_until_it_stops() -> Result[Void]
  base = try fresh()
  path = "#{base}/log.txt"
  held: Channel[File.Handle] = Channel.new(1)
  log = Core.Service(name: "log", start: -> { opened(held, path) }, stop: -> { closed(held) })
  running = try Extensions.start_services([log], 1000)
  Extensions.stop_services(running)
  text = File.read_text(path)
  _ = Path.remove(base)
  Test.eq(text, ok("started\nstopped\n"))
end

# A service that crashes as it starts stops those started before it and fails the start.
def test_a_service_that_crashes_fails_the_start() -> Result[Void]
  stopped: Channel[String] = Channel.new(4)
  first = Core.Service(name: "a", start: -> { ok() }, stop: -> { _ = stopped.send("a", 0) })
  crashing = Core.Service(name: "b", start: -> { crashed_start() }, stop: -> { _ = stopped.send("b", 0) })
  started = Extensions.start_services([first, crashing], 1000)
  try Test.assert(started.message.include?("service b: crashed"), started.message)
  try Test.eq(stopped.recv(100), ok("a"))
  Test.error?(stopped.recv(0))
end

def slow(text: String, ms: Int) -> String
  never: Channel[String] = Channel.new(1)
  never.recv(ms).unwrap_or(text)
end

def noted(seen: Channel[String], call: Core.Call, next: Fn[Result[String]]) -> Result[String]
  _ = seen.send(try JSON.string(try JSON.get(call.input, "command")), 0)
  next.call()
end

def opened(held: Channel[File.Handle], path: String) -> Result[Void]
  handle = try File.open(path, "append")
  try File.write(handle, "started\n")
  held.send(handle, 0)
end

def closed(held: Channel[File.Handle]) -> Void
  case held.recv(0)
    ok(handle) ->
      _ = File.write(handle, "stopped\n")
      _ = File.close(handle)
    error(_) -> nil
  end
end

def crashed_start() -> Result[Void]
  _ = crash_on_boom("boom")
  ok()
end

# The tests of an extension build a call with `Core.call`: its paths resolve in the real folder, behind a link or
# relative.
def test_core_call_builds_a_call_for_the_tests_of_an_extension() -> Result[Void]
  base = try fresh()
  try Dir.mkdir("#{base}/real")
  _ = try H.run("ln", ["-s", "real", "#{base}/link"])
  call = Core.call("#{base}/link", JSON.object({"text": JSON.from("one")}))
  results = [Core.resolve(call, "a.txt"), Core.resolve(call, "../outside")]
  here = Core.resolve(Core.call(".", JSON.object({})), "agentica.toml")
  _ = Path.remove(base)
  try Test.eq(results[0], ok("#{base}/real/a.txt"))
  try Test.error?(results[1])
  Test.eq(here, ok("#{try Path.real(".")}/agentica.toml"))
end

def crashing_tool() -> Core.Tool
  Core.Tool(
    name: "word_count",
    description: "Counts words.",
    input_schema: JSON.object({"type": JSON.from("object")}),
    asks: false,
    run: ->(_call: Core.Call) { ok(crash_on_boom("boom")) },
    target: ->(_call: Core.Call) { ok("") },
  )
end

def hooked(calls: Channel[String], call: Core.ToolCall) -> Core.Check
  _ = calls.send("#{call.session} #{call.name}", 0)
  Core.Check.Input(JSON.object({"command": JSON.from(HOOKED)}))
end

def crash_check() -> Core.Check
  none_yet: List[Core.Check] = []
  none_yet[0]
end

def stopped_call(registry: Core.Registry, reason: String) -> Result[Void]
  H.using(H.Setup(replies: ["bash_echo.sse", "text.sse"], registry: some(registry))) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Echo.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    _ = try Fake.next_request(h.fake)
    body = (try Fake.next_request(h.fake)).body
    try Test.assert(body.include?(reason), "the model gets #{reason.inspect}: #{body}")
    Test.assert(not File.read_text("#{h.work}/other.txt").ok?, "the call ran")
  end
end

def observed_as(got: Channel[String], seen: Core.Seen) -> Void
  detail = case seen.name
    "session_started" -> "#{seen.session} #{JSON.encode(JSON.get(seen.data, "new").unwrap_or(JSON.from(false)))}"
    "session_ended" -> JSON.string(JSON.get(seen.data, "reason").unwrap_or(JSON.from(""))).unwrap_or("")
    _ -> ""
  end

  _ = got.send("#{seen.name} #{detail}".strip, 0)
end

def stuck(got: Channel[String], gate: Channel[Bool], seen: Core.Seen) -> Void
  _ = got.send(seen.name, 0)
  _ = gate.recv(60_000)
end

def crash_on_boom(text: String) -> String
  return text if not text.include?("boom")

  none_yet: List[String] = []
  none_yet[0]
end

def hang(text: String) -> String
  never: Channel[String] = Channel.new(1)
  never.recv(60_000).unwrap_or(text)
end

def tagged(tag: String) -> Extensions.Wrapper
  ->(name: String, _call: Core.Call, next: Fn[Result[String]]) { suffixed(next, " #{name} #{tag}]") }
end

def suffixed(next: Fn[Result[String]], suffix: String) -> Result[String]
  out = try next.call()
  ok("#{out}#{suffix}")
end

def started(seen: Channel[String]) -> Result[Void]
  _ = seen.send("started", 0)
  ok()
end

def stop_seen(where: Channel[String]) -> String
  state_dir = where.recv(0).unwrap_or("")
  there = File.stat("#{state_dir}/server.json").ok?
  return "server.json gone" if not there
  return "listening" if listening?(state_dir)

  "server.json there"
end

def listening?(state_dir: String) -> Bool
  case File.read_text("#{state_dir}/server.json")
    ok(text) -> TCP.connect("127.0.0.1", port_of(text), 500).ok?
    error(_) -> false
  end
end

def port_of(text: String) -> Int
  case JSON.parse(text)
    ok(json) -> JSON.int(JSON.get(json, "port").unwrap_or(JSON.null)).unwrap_or(0)
    error(_) -> 0
  end
end

def unset(_name: String) -> Result[String] = error("unset")

def fresh() -> Result[String]
  tmp = System.env("TMPDIR").unwrap_or("/tmp")
  base = "#{tmp}/agc-registry-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(base)
  Path.real(base)
end
