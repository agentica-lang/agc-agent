# `GET /v1/mcp` and the reconnect: the states of the servers of the user's file and of the session's folder, and a
# server started again.

import Protocol from "pkg/protocol/protocol"
import Builtins from "../src/session/builtins"
import Extensions from "../src/config/registry"
import H from "support/harness"
import S from "support/mcp_fakes"

# A server that starts is `connected` with its tools, one that does not is `failed` with the reason, and the project
# servers of a session's folder come with `?session=`, marked `project`. The program of a stdio server shows, its
# environment does not.
def test_the_status_lists_the_servers_of_the_user_and_of_the_folder() -> Result[Void]
  S.within_dir do |dir|
    repo = try make_repo(dir, "repo", {"proj": try S.fake_server(JSON.object({"SECRET_VAR": JSON.from("hush")}))})
    bad = JSON.object({"command": JSON.from("/nonexistent/finn-mcp")})
    try S.write_config(dir, {"good": try S.fake_server(JSON.object({})), "bad": bad})
    mounted = try Builtins.mcp(Extensions.Served(registry: Extensions.Registry()), reader(dir), dir, [repo])
    result = H.using(wired(mounted)) do |h|
      id = try H.new_session_in(h, repo)
      all = try settled(h, "?session=#{id}", 3)
      try Test.eq(
        all.servers.map { |s| "#{s.scope}:#{s.name}:#{s.state}" },
        ["user:bad:failed", "user:good:connected", "project:proj:connected"],
      )

      good = all.servers[1]
      try Test.eq(good.transport, "stdio")
      try Test.eq(good.tools.map { |tool| tool.name }.include?("echo"), true)
      try Test.eq(all.servers[0].error.empty?, false)
      try Test.eq(all.servers[2].tools.size > 0, true)
      try Test.eq(JSON.encode(all).include?("hush"), false)
      alone = try settled(h, "", 2)
      Test.eq(alone.servers.map { |s| s.name }, ["bad", "good"])
    end

    mounted.stop.call()
    result
  end
end

# A server that failed to start (its program was not there yet) is `failed`; after a reconnect that finds it, it is
# `connected` with its tools, the model gets them, and a name that is none is `mcp.not_found`.
def test_a_reconnect_starts_a_failed_server_again() -> Result[Void]
  S.within_dir do |dir|
    fake = try S.fake_server(JSON.object({}))
    script = "#{dir}/late.sh"
    late = JSON.object({"command": JSON.from("/bin/sh"), "args": JSON.from([script])})
    try S.write_config(dir, {"late": late})
    mounted = try Builtins.mcp(Extensions.Served(registry: Extensions.Registry()), reader(dir), dir, [])
    tools = Extensions.late_tools(mounted.served).unwrap!
    result = H.using(wired(mounted)) do |h|
      first = try settled(h, "", 1)
      try Test.eq(first.servers[0].state, "failed")
      try Test.eq(tools.call(dir).size, 0)
      program = try JSON.string(JSON.get(fake, "command").unwrap_or(JSON.from("")))
      given = try JSON.list(JSON.get(fake, "args").unwrap_or(JSON.array([])))
      launch = "exec #{program} #{try JSON.string(given[0])}\n"
      try File.write_text(script, launch)
      answer = try H.post(h, Protocol.mcp_reconnect_path("late"), "")
      try Test.eq(answer.status, 200)
      one = (try Protocol.decode_mcp_status(answer.text)).servers
      try Test.eq(one.map { |s| "#{s.name}:#{s.state}:#{s.error}" }, ["late:connected:"])
      try Test.eq(tools.call(dir).any? { |t| t.name == "mcp__late__echo" }, true)
      missing = try H.post(h, Protocol.mcp_reconnect_path("none"), "")
      try Test.eq(missing.status, 404)
      Test.assert(missing.text.include?(Protocol.KIND_MCP_NOT_FOUND), missing.text)
    end

    mounted.stop.call()
    result
  end
end

# Waits until `count` servers stopped connecting, and gives the list.
def settled(h: H.Harness, query: String, count: Int) -> Result[Protocol.McpStatus]
  for _ in 0...300
    answer = try H.get(h, "#{Protocol.MCP_PATH}#{query}")
    return error("GET /v1/mcp: #{answer.status} #{answer.text}") if answer.status != 200

    status = try Protocol.decode_mcp_status(answer.text)
    pending = status.servers.select { |s| s.state == "connecting" }
    return ok(status) if status.servers.size == count and pending.empty?

    Task.sleep(100)
  end

  error("the servers did not settle in 30 seconds")
end

def wired(mounted: Builtins.Mounted) -> H.Setup
  H.Setup(
    replies: [],
    registry: some(mounted.served.registry),
    late_tools: Extensions.late_tools(mounted.served),
    reloads: [mounted.reload],
    mcp: some(mounted.control),
  )
end

def reader(dir: String) -> Fn[String, Result[String]]
  ->(name: String) {
    return ok("#{dir}/xdg") if name == "XDG_CONFIG_HOME"
    return ok("#{dir}/mcp.json") if name == "FINN_MCP_CONFIG"

    System.env(name)
  }
end

def make_repo(dir: String, name: String, servers: Map[String, JSON.Value]) -> Result[String]
  folder = "#{dir}/#{name}"
  try Dir.mkdir_private(folder)
  try Dir.mkdir_private("#{folder}/.finn")
  try File.write_text("#{folder}/.finn/mcp.json", JSON.encode(JSON.object({"mcpServers": JSON.object(servers)})))
  Path.real(folder)
end
