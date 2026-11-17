## The registry of `Core.serve`, in a server: a prompt after the system prompt, handlers of events, wrappers of the runs
## of the tools, and services. The code of an extension that crashes or hangs fails its call, never the session.

import Protocol from "pkg/protocol/protocol"
import Core from "../core"
import Extensions from "../src/config/registry"
import Spec from "../src/tools/spec"
import Tools from "../src/tools/tools"
import Fake from "support/fake_llm"
import H from "support/harness"

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
    |> Core.wrap_tools(
      ->(n: String, _c: Core.Call, _next: Fn[Core.Call, Result[String]]) { ok(crash_on_boom("boom #{n}")) },
    )
  )

  hanging = (
    Core.registry().with(tool_ms: 50)
    |> Core.wrap_tools(->(n: String, _c: Core.Call, _next: Fn[Core.Call, Result[String]]) { ok(hang(n)) })
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
    |> Core.wrap_tools(
      ->(_n: String, _c: Core.Call, _next: Fn[Core.Call, Result[String]]) { ok("ran by the wrapper") },
    )
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

# Names that are taken: a built-in tool, a tool of the core outside `Tools.all`, the MCP prefix, and another extension.
def test_extension_tools_cannot_take_a_name() -> Result[Void]
  registry = Core.registry()
  for name in ["bash", "run_script", "mcp__s__x", "mine", "mine", "theirs"]
    registry = registry |> Core.add_tool(crashing_tool().with(name: name))
  end

  Test.eq(Extensions.clashes(registry, ["bash"]).size, 4)
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
  ->(name: String, call: Core.Call, next: Fn[Core.Call, Result[String]]) { suffixed(next, call, " #{name} #{tag}]") }
end

def suffixed(next: Fn[Core.Call, Result[String]], call: Core.Call, suffix: String) -> Result[String]
  out = try next.call(call)
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
