import Mcp from "pkg/mcp/mcp"
import Protocol from "pkg/protocol/protocol"
import Approval from "../src/approval/approval"
import McpTools from "../src/ext/mcp"
import Tools from "../src/tools/tools"
import Fake from "support/fake_llm"
import H from "support/harness"

FAKES = ["../mcp/tests/support/fake_server.agc", "mcp/tests/support/fake_server.agc"]

# The model sees `mcp__fake__echo`, the call asks with its JSON input, and the result goes back to the model.
def test_a_session_calls_an_mcp_tool_after_an_approval() -> Result[Void]
  within_mcp do |started|
    H.using(H.Setup(replies: ["mcp_echo.sse", "text.sse"], tools: started.tools)) do |h|
      id = try H.new_session(h)
      a = try H.subscribe(h, id)
      _ = try H.send(h, id, "Echo it.")
      a = try H.until(a, Protocol.EventKind.ApprovalRequested)
      asked = try H.approval(a)
      _ = try H.approve(h, id, asked.approval_id, Protocol.Decision.Allow)
      _ = try H.until(a, Protocol.EventKind.TurnFinished)
      H.close(a)
      try Test.eq([asked.tool, asked.preview], ["mcp__fake__echo", "{\"text\":\"hello from mcp\"}"])
      first = try JSON.parse((try H.next_request(h)).body)
      try Test.assert(JSON.encode(try JSON.get(first, "tools")).include?("\"mcp__fake__echo\""), "no MCP tool offered")
      messages: List[JSON.Value] = try JSON.list(
        try JSON.get(try JSON.parse((try H.next_request(h)).body), "messages"),
      )

      Test.eq(JSON.get(messages.last, "content"), ok(JSON.from("hello from mcp")))
    end
  end
end

# Tools that a server lists after the start reach a session that started before them.
def test_tools_listed_late_reach_the_sessions() -> Result[Void]
  within_mcp do |started|
    H.using(H.Setup(replies: ["mcp_echo.sse", "text.sse"], late_tools: some(-> { started.tools }))) do |h|
      id = try H.new_session(h)
      a = try H.subscribe(h, id)
      _ = try H.send(h, id, "Echo it.")
      a = try H.until(a, Protocol.EventKind.ApprovalRequested)
      _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
      _ = try H.until(a, Protocol.EventKind.TurnFinished)
      H.close(a)
      first = try JSON.parse((try H.next_request(h)).body)
      Test.assert(JSON.encode(try JSON.get(first, "tools")).include?("\"mcp__fake__echo\""), "no MCP tool offered")
    end
  end
end

# The tools of a turn are those there were when it started: a tool listed during the turn waits for the next one, so
# both requests of a turn offer the same tools.
def test_a_turn_keeps_the_tools_it_started_with() -> Result[Void]
  within_mcp do |started|
    calls: Channel[Int] = Channel.new(1)
    _ = calls.send(0, 1000)
    late = -> { growing(calls, started.tools) }
    H.using(H.Setup(replies: ["read_file.sse", "text.sse"], late_tools: some(late))) do |h|
      id = try H.new_session(h)
      a = try H.subscribe(h, id)
      _ = try H.send(h, id, "Read it.")
      a = try H.until(a, Protocol.EventKind.TurnFinished)
      H.close(a)
      first = tool_names(try H.next_request(h))
      second = tool_names(try H.next_request(h))
      try Test.eq(second, first)
      Test.assert(second.size > 0, "no tools offered")
    end
  end
end

# A rule allows a call; a crash is an error result and the next call starts the server again; a big result is cut.
def test_mcp_tools_follow_the_rules_and_survive_a_crash() -> Result[Void]
  within_mcp do |started|
    rules = try Approval.parse_rules(["mcp__fake__echo(*)"], [])
    ctx = try Tools.context(".", &H.fake_env, rules, started.tools)
    input = JSON.object({"text": JSON.from("hi")})
    try Test.eq(Tools.verdict(ctx, "mcp__fake__echo", input), Tools.Verdict.Allow)
    try Test.eq(Tools.verdict(ctx, "mcp__fake__fail", input), Tools.Verdict.Ask)
    crashed = Tools.run(ctx, "mcp__fake__crash", JSON.object({}))
    again = Tools.run(ctx, "mcp__fake__echo", input)
    failed = Tools.run(ctx, "mcp__fake__fail", JSON.object({}))
    big = Tools.run(ctx, "mcp__fake__big", JSON.object({}))
    try Test.eq(crashed.is_error, true)
    try Test.eq(again, Tools.Output(text: "hi", is_error: false))
    try Test.eq(failed, Tools.Output(text: "it failed", is_error: true))
    Test.assert(big.text.length < 31000 and big.text.include?("[output cut"), "not cut: #{big.text.length}")
  end
end

# A server name or env name that could break out of its place is refused.
def test_the_config_refuses_odd_names() -> Result[Void]
  within_dir do |dir|
    for name in ["../x", "a__b"]
      try write_config(dir, {name: JSON.object({"command": JSON.from("true")})})
      try Test.assert(McpTools.servers(->(n) { config_env(dir, n) }, dir).ok? == false, "#{name} taken")
    end

    env = JSON.object({"A=B": JSON.from("x")})
    try write_config(dir, {"ok": JSON.object({"command": JSON.from("true"), "env": env})})
    try Test.assert(McpTools.servers(->(n) { config_env(dir, n) }, dir).ok? == false, "A=B taken")
    try write_config(dir, {"ok": JSON.object({"command": JSON.from("X=1")})})
    Test.assert(McpTools.servers(->(n) { config_env(dir, n) }, dir).ok? == false, "a command with = taken")
  end
end

# The server gets the env of its config and none of the agent's keys; a tool listed twice or with a bad name is left
# out with a warning.
def test_a_server_gets_a_short_environment_and_unique_tools() -> Result[Void]
  within_dir do |dir|
    env = JSON.object({"FAKE_MCP_GREETING": JSON.from("hi"), "FAKE_MCP_MODE": JSON.from("odd")})
    try write_config(dir, {"odd": try fake_server(env)})
    servers = (try McpTools.servers(->(n) { config_env(dir, n) }, dir)).map do |server|
      secret = {"SECRET_API_KEY": "leaked"}
      Mcp.Server(name: server.name, command: server.command, args: server.args, env: secret, log: server.log)
    end

    started = McpTools.start(servers)
    ctx = try Tools.context(".", &H.fake_env, try Approval.parse_rules([], []), started.tools)
    probe = ->(name: String) { Tools.run(ctx, "mcp__odd__probe", JSON.object({"text": JSON.from(name)})).text }
    key = probe.call("SECRET_API_KEY")
    greeting = probe.call("FAKE_MCP_GREETING")
    path = probe.call("PATH")
    McpTools.stop(started)
    try Test.eq(started.tools.map { |t| t.name }, ["mcp__odd__echo", "mcp__odd__probe"])
    try Test.eq(started.warnings.size, 2)
    try Test.eq([key, greeting], ["", "hi"])
    Test.assert(not path.empty?, "no PATH")
  end
end

# Slow servers list their tools at the same time and after the start: their tools come as they are listed.
def test_slow_servers_list_their_tools_in_the_background() -> Result[Void]
  within_dir do |dir|
    slow = JSON.object({"FAKE_MCP_SLOW_MS": JSON.from("3000")})
    try write_config(dir, {"one": try fake_server(slow), "two": try fake_server(slow)})
    began = Time.monotonic_ms()
    board = McpTools.background(try McpTools.servers(->(n) { config_env(dir, n) }, dir), ->(_w: String) { nil })
    at_start = McpTools.tools(board)
    started = McpTools.wait(board)
    took = Time.monotonic_ms() - began
    McpTools.stop(started)
    try Test.eq(at_start.size, 0)
    try Test.eq(started.tools.size, 18)
    Test.assert(took < 5000, "the listings took #{took} ms: one after the other")
  end
end

private

def within_dir(body: Fn[String, Result[Void]]) -> Result[Void]
  tmp = System.env("TMPDIR").unwrap_or("/tmp")
  dir = "#{tmp}/core-mcp-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  result = body.call(dir)
  _ = Path.remove(dir)
  result
end

def write_config(dir: String, servers: Map[String, JSON.Value]) -> Result[Void]
  File.write_text("#{dir}/mcp.json", JSON.encode(JSON.object({"mcpServers": JSON.object(servers)})))
end

def fake_server(env: JSON.Value) -> Result[JSON.Value]
  main = try Path.resolve(try existing(FAKES))
  ok(JSON.object({"command": JSON.from(binary()), "args": JSON.from([main]), "env": env}))
end

def within_mcp(body: Fn[McpTools.Started, Result[Void]]) -> Result[Void]
  within_dir do |dir| with_config(dir, body) end
end

def with_config(dir: String, body: Fn[McpTools.Started, Result[Void]]) -> Result[Void]
  try write_config(dir, {"fake": try fake_server(JSON.object({}))})
  read = ->(name) { config_env(dir, name) }
  started = McpTools.start(try McpTools.servers(read, dir))
  try Test.eq(started.warnings, [])
  result = body.call(started)
  McpTools.stop(started)
  result
end

def config_env(dir: String, name: String) -> Result[String]
  return ok("#{dir}/mcp.json") if name == "FINN_MCP_CONFIG"

  System.env(name)
end

def binary() -> String
  case System.env("AGENTICA")
    ok(path) if path != "" -> path
    _ -> "agentica"
  end
end

def existing(paths: List[String]) -> Result[String]
  case (paths.find { |path| File.stat(path).ok? })
    ok(path) -> ok(path)
    error(_) -> error("none of #{paths.join(", ")} exists")
  end
end

# The tools listed so far: one more on each call.
def growing(calls: Channel[Int], tools: List[Tools.Tool]) -> List[Tools.Tool]
  n = calls.recv(1000).unwrap_or(0)
  _ = calls.send(n + 1, 1000)
  (0..n).to_a.map { |i| tools[0].with(name: "#{tools[0].name}#{i}") }
end

def tool_names(request: Fake.Seen) -> List[String]
  json = JSON.parse(request.body).unwrap_or(JSON.object({}))
  listed: List[JSON.Value] = JSON.list(JSON.get(json, "tools").unwrap_or(JSON.array([]))).unwrap_or([])
  listed.map { |tool| JSON.encode(tool) }
end
