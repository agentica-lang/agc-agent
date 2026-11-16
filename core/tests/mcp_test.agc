import Protocol from "pkg/protocol/protocol"
import Approval from "../src/approval"
import McpTools from "../src/mcp_tools"
import Tools from "../src/tools"
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

private

def within_mcp(body: Fn[McpTools.Started, Result[Void]]) -> Result[Void]
  tmp = System.env("TMPDIR").unwrap_or("/tmp")
  dir = "#{tmp}/core-mcp-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  result = with_config(dir, body)
  _ = Path.remove(dir)
  result
end

def with_config(dir: String, body: Fn[McpTools.Started, Result[Void]]) -> Result[Void]
  main = try Path.resolve(try existing(FAKES))
  server = JSON.object({"command": JSON.from(binary()), "args": JSON.from([main])})
  config = JSON.object({"mcpServers": JSON.object({"fake": server})})
  try File.write_text("#{dir}/mcp.json", JSON.encode(config))
  read = ->(name) { config_env(dir, name) }
  started = McpTools.start(try McpTools.servers(read, dir))
  try Test.eq(started.warnings, [])
  result = body.call(started)
  McpTools.stop(started)
  result
end

def config_env(dir: String, name: String) -> Result[String]
  return ok("#{dir}/mcp.json") if name == "FINN_MCP_CONFIG"

  error("not set")
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
