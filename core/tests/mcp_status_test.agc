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

# A reconnect that is still starting when the board ends is waited for: its process stops with the others, and
# nothing of it runs after the stop.
def test_a_reconnect_that_overlaps_the_end_of_the_board_leaves_no_process() -> Result[Void]
  S.within_dir do |dir|
    pids = "#{dir}/pids"
    slow = JSON.object({"FAKE_MCP_SLOW_MS": JSON.from("1200"), "FAKE_MCP_PIDS": JSON.from(pids)})
    try S.write_config(dir, {"slow": try S.fake_server(slow)})
    mounted = try Builtins.mcp(Extensions.Served(registry: Extensions.Registry()), reader(dir), dir, [])
    result = H.using(wired(mounted)) do |h|
      try settled(h, "", 1)
      asking = Task.spawn { H.post(h, Protocol.mcp_reconnect_path("slow"), "") }
      try started(pids, 2)
      mounted.stop.call()
      pids_written = lines(pids)
      try Test.eq(pids_written.size, 2)
      try Test.eq(alive?(pids_written[1]), false)
      answer = try Task.await(asking)
      try Test.eq([200, 409].include?(answer.status), true)
      try gone(pids)
      Test.eq(lines(pids).size, 2)
    end

    result
  end
end

# One start of a server at a time: a second reconnect, or one on a server that is still on its first start, is refused
# with `mcp.starting`, and so is one while a reload restarts the servers.
def test_a_reconnect_is_refused_while_the_server_starts() -> Result[Void]
  S.within_dir do |dir|
    slow = JSON.object({"FAKE_MCP_SLOW_MS": JSON.from("1500")})
    try S.write_config(dir, {"slow": try S.fake_server(slow)})
    mounted = try Builtins.mcp(Extensions.Served(registry: Extensions.Registry()), reader(dir), dir, [])
    result = H.using(wired(mounted)) do |h|
      first = try H.post(h, Protocol.mcp_reconnect_path("slow"), "")
      try Test.eq(first.status, 409)
      try Test.assert(first.text.include?(Protocol.KIND_MCP_STARTING), first.text)
      try settled(h, "", 1)
      once = Task.spawn { H.post(h, Protocol.mcp_reconnect_path("slow"), "") }
      Task.sleep(300)
      twice = try H.post(h, Protocol.mcp_reconnect_path("slow"), "")
      try Test.eq(twice.status, 409)
      try Test.eq((try Task.await(once)).status, 200)
      other = JSON.object({"command": JSON.from("/nonexistent/finn-mcp")})
      try S.write_config(dir, {"slow": try S.fake_server(slow), "other": other})
      try reload(h)
      during = try H.post(h, Protocol.mcp_reconnect_path("slow"), "")
      try Test.eq(during.status, 409)
      try Test.assert(during.text.include?(Protocol.KIND_MCP_STARTING), during.text)
      Test.eq((try H.post(h, Protocol.mcp_reconnect_path("none"), "")).status, 404)
    end

    mounted.stop.call()
    result
  end
end

# A project server reconnects through its session's folder, the routes need the token, and a session that is none is a
# 404. An HTTP server shows its origin only: no user, path, query or header reaches the answer, not even in its error.
def test_the_routes_check_the_token_the_session_and_hide_the_url() -> Result[Void]
  S.within_dir do |dir|
    remote = JSON.object({
      "url": JSON.from("http://127.0.0.1:1/private/path?token=SECRETQUERY"),
      "headers": JSON.object({"Authorization": JSON.from("Bearer SECRETHEADER")}),
    })

    repo = try make_repo(dir, "repo", {"proj": try S.fake_server(JSON.object({}))})
    try S.write_config(dir, {"remote": remote})
    mounted = try Builtins.mcp(Extensions.Served(registry: Extensions.Registry()), reader(dir), dir, [repo])
    result = H.using(wired(mounted)) do |h|
      id = try H.new_session_in(h, repo)
      all = try settled(h, "?session=#{id}", 2)
      shown = all.servers[0]
      try Test.eq(
        [shown.name, shown.scope, shown.transport, shown.target, shown.state],
        ["remote", "user", "http", "http://127.0.0.1:1", "failed"],
      )

      body = JSON.encode(all)
      try Test.eq(
        [body.include?("SECRETQUERY"), body.include?("SECRETHEADER"), body.include?("private")],
        [false, false, false],
      )

      project = try H.post(h, "#{Protocol.mcp_reconnect_path("proj")}?session=#{id}", "")
      try Test.eq(project.status, 200)
      try Test.eq(
        (try Protocol.decode_mcp_status(project.text)).servers.map { |s| "#{s.scope}:#{s.state}" },
        ["project:connected"],
      )

      try Test.eq((try H.call(h, "GET", Protocol.MCP_PATH, "", [])).status, 401)
      try Test.eq((try H.call(h, "POST", Protocol.mcp_reconnect_path("proj"), "", [])).status, 401)
      Test.eq((try H.get(h, "#{Protocol.MCP_PATH}?session=nosuch")).status, 404)
    end

    mounted.stop.call()
    result
  end
end

# The log of a server is read by the server from the file its configuration names: the last lines, `lines` of them, and
# a name that is none is a 404. The client gives no path.
def test_the_log_of_a_server_comes_through_the_server() -> Result[Void]
  S.within_dir do |dir|
    try S.write_config(dir, {"good": try S.fake_server(JSON.object({}))})
    mounted = try Builtins.mcp(Extensions.Served(registry: Extensions.Registry()), reader(dir), dir, [])
    result = H.using(wired(mounted)) do |h|
      try settled(h, "", 1)
      try File.write_text("#{dir}/mcp/good.log", "one\ntwo\nthree\n")
      all = try H.get(h, Protocol.mcp_log_path("good"))
      try Test.eq(all.status, 200)
      try Test.eq((try Protocol.decode_mcp_log(all.text)).lines, ["one", "two", "three"])
      last = try H.get(h, "#{Protocol.mcp_log_path("good")}?lines=2")
      try Test.eq((try Protocol.decode_mcp_log(last.text)).lines, ["two", "three"])
      try Test.eq((try H.get(h, "#{Protocol.mcp_log_path("good")}?lines=-1")).status, 400)
      try Test.eq((try H.get(h, Protocol.mcp_log_path("none"))).status, 404)
      for name in ["..", "%2e%2e", "a%2Fb", "a%00b", "..%2F..%2Fmcp%2Fgood"]
        try Test.eq((try H.get(h, "/v1/mcp/#{name}/log")).status, 404)
      end

      Test.eq((try H.call(h, "GET", Protocol.mcp_log_path("good"), "", [])).status, 401)
    end

    mounted.stop.call()
    result
  end
end

# The log of a project server is read with its session; without one the server is not the user's, and is none.
def test_the_log_of_a_project_server_comes_with_its_session() -> Result[Void]
  S.within_dir do |dir|
    repo = try make_repo(dir, "repo", {"proj": try S.fake_server(JSON.object({}))})
    try S.write_config(dir, {})
    mounted = try Builtins.mcp(Extensions.Served(registry: Extensions.Registry()), reader(dir), dir, [repo])
    result = H.using(wired(mounted)) do |h|
      id = try H.new_session_in(h, repo)
      try settled(h, "?session=#{id}", 1)
      files = (try Dir.list("#{dir}/mcp")).select { |name| name.end_with?("-proj.log") }
      try Test.eq(files.size, 1)
      try File.write_text("#{dir}/mcp/#{files[0]}", "p1\np2\n")
      path = Protocol.mcp_log_path("proj")
      shown = try H.get(h, "#{path}?session=#{id}")
      try Test.eq(shown.status, 200)
      try Test.eq((try Protocol.decode_mcp_log(shown.text)).lines, ["p1", "p2"])
      try Test.eq((try H.get(h, path)).status, 404)
      Test.eq((try H.get(h, "#{path}?session=nosuch")).status, 404)
    end

    mounted.stop.call()
    result
  end
end

# Waits until the file `pids` has `count` lines: that many fake servers started.
def started(pids: String, count: Int) -> Result[Void]
  for _ in 0...300
    return ok() if lines(pids).size >= count

    Task.sleep(50)
  end

  error("the servers did not start")
end

# Waits until no process of `pids` runs.
def gone(pids: String) -> Result[Void]
  for _ in 0...100
    running = lines(pids).select { |pid| alive?(pid) }
    return ok() if running.empty?

    Task.sleep(50)
  end

  error("a server of #{pids} still runs")
end

def lines(path: String) -> List[String]
  case File.read_text(path)
    ok(text) -> text.split("\n").select { |line| line != "" }
    error(_) -> []
  end
end

# A process that exited but was not reaped yet is a zombie: it counts as gone.
def alive?(pid: String) -> Bool
  case File.read_text("/proc/#{pid}/stat")
    ok(stat) -> not stat.include?(") Z ")
    error(_) -> false
  end
end

def reload(h: H.Harness) -> Result[Void]
  answer = try H.post(h, Protocol.RELOAD_PATH, "")
  return error("reload: #{answer.status} #{answer.text}") if answer.status != 200

  ok()
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
