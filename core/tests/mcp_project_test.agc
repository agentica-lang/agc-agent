# The MCP config files: the user's file by default (`FINN_MCP_CONFIG` replaces it), and the `.finn/mcp.json` of
# a trusted
# session folder, whose servers belong to the sessions of that folder.

import Protocol from "pkg/protocol/protocol"
import Builtins from "../src/session/builtins"
import Extensions from "../src/config/registry"
import McpTools from "../src/ext/mcp"
import Tools from "../src/tools/tools"
import H from "support/harness"
import S from "support/mcp_fakes"

# The user's file is `mcp.json` of the config folder; `FINN_MCP_CONFIG` replaces it, an empty one means no servers, and
# a file it names that is not there is an error. A default file that is not there is none, and one that does not read
# is a warning at the start (the server starts without it), unlike the file the variable names. A project server starts
# in its folder and logs under `project-` and a hash of the folder.
def test_the_config_files_are_found_by_default_and_the_variable_replaces_the_default() -> Result[Void]
  S.within_dir do |dir|
    config = "#{dir}/xdg/finn"
    try Dir.mkdir_private("#{dir}/xdg")
    try Dir.mkdir_private(config)
    other = "#{dir}/other.json"
    try File.write_text("#{config}/mcp.json", servers_json(["user"]))
    try File.write_text(other, servers_json(["named"]))
    by_default = ->(name: String) { var("#{dir}/xdg", none, name) }
    named = ->(name: String) { var("#{dir}/xdg", some(other), name) }
    empty = ->(name: String) { var("#{dir}/xdg", some(""), name) }
    try Test.eq((try McpTools.servers(by_default, dir)).map { |s| s.name }, ["user"])
    try Test.eq((try McpTools.servers(named, dir)).map { |s| s.name }, ["named"])
    try Test.eq((try McpTools.servers(empty, dir)).size, 0)
    try Test.eq((try McpTools.servers(by_default, dir))[0].log, "#{dir}/mcp/user.log")
    try Test.eq((try McpTools.servers(->(n: String) { var("#{dir}/none", none, n) }, dir)).size, 0)
    missing = ->(n: String) { var(dir, some("#{dir}/missing.json"), n) }
    try Test.eq(McpTools.servers(missing, dir).ok?, false)
    try Test.eq(McpTools.configured?(missing), true)
    try Test.eq(McpTools.configured?(by_default), false)

    try File.write_text("#{config}/mcp.json", "{oops")
    try Test.eq(McpTools.servers(by_default, dir).ok?, false)
    mounted = try Builtins.mcp(Extensions.Served(registry: Extensions.Registry()), by_default, dir)
    mounted.stop.call()
    try File.write_text(other, "{oops")
    try Test.eq(Builtins.mcp(Extensions.Served(registry: Extensions.Registry()), named, dir).ok?, false)

    folder = "#{dir}/repo"
    try make_project_file(folder, servers_json(["proj"]))
    found = try McpTools.project(folder, by_default, dir, [])
    try Test.eq(found.servers[0].cwd, folder)
    log = found.servers[0].log
    try Test.assert(
      log.start_with?("#{dir}/mcp/project-") and
      log.end_with?("-proj.log") and
      log.length == "#{dir}/mcp/project-12345678-proj.log".length,
      log,
    )

    try Test.eq((try McpTools.project("#{dir}/none", by_default, dir, [])).servers.size, 0)
    Test.eq(McpTools.project_file("#{dir}/none"), "")
  end
end

# A project file cannot read the environment: a header with `${NAME}` leaves its server out with a warning that names
# the variable and never shows its value, and the others of the file stay. A server named like one of the user's is
# left out too.
def test_a_project_file_cannot_read_the_environment_or_take_a_users_name() -> Result[Void]
  S.within_dir do |dir|
    folder = "#{dir}/repo"
    leaky = JSON.object({
      "url": JSON.from("http://127.0.0.1:1/mcp"),
      "headers": JSON.object({"Authorization": JSON.from("Bearer ${LEAK_ME}")}),
    })

    plain = JSON.object({"command": JSON.from("true")})
    try make_project_file(
      folder,
      JSON.encode(JSON.object({"mcpServers": JSON.object({"leaky": leaky, "plain": plain, "mine": plain})})),
    )

    secret = "s3cr3t-value"
    read = ->(n: String) { if_leak(n, secret, dir) }
    found = try McpTools.project(folder, read, dir, ["mine"])
    try Test.eq(found.servers.map { |s| s.name }, ["plain"])
    try Test.eq(found.warnings.size, 2)
    try Test.assert(
      found.warnings[0].include?("${LEAK_ME}") and found.warnings[0].include?("leaky"),
      "#{found.warnings}",
    )

    try Test.assert(not found.warnings.any? { |w| w.include?(secret) }, "a warning shows the value of the variable")
    try Test.assert(found.warnings[1].include?("mine") and found.warnings[1].include?("rename"), "#{found.warnings}")
    # The same header in the user's file reads the variable, as it always did.
    try S.write_config(dir, {"ok": leaky})
    users = try McpTools.servers(->(n: String) { if_leak(n, secret, dir) }, dir)
    Test.eq(users[0].headers["Authorization"], "Bearer #{secret}")
  end
end

# The servers of a trusted folder start with its first session, its sessions share them, and the end of the last one
# stops them; a project server named like a user server is left out, so the user's rules never reach it; an untrusted
# folder gets nothing; the server starts in the folder.
def test_project_servers_belong_to_the_sessions_of_their_folder() -> Result[Void]
  S.within_dir do |dir|
    repo = try make_repo(dir, "repo", {"proj": try fake("project", dir), "shared": try fake("project-shared", dir)})
    stranger = try make_repo(dir, "stranger", {"proj": try fake("project", dir)})
    marker = try make_repo(dir, "marker", {"mark": try fake("mark", dir)})
    try S.write_config(dir, {"shared": try fake("user", dir)})
    mounted = try Builtins.mcp(Extensions.Served(registry: Extensions.Registry()), reader(dir), dir, [repo, marker])
    tools = Extensions.late_tools(mounted.served).unwrap!
    result = H.using(wired(mounted)) do |h|
      first = try H.new_session_in(h, repo)
      try wait_for(tools, repo, "mcp__proj__echo", true)
      held = tools.call(repo)
      try Test.eq(try said(tools, repo, "mcp__shared__greeting"), "user")
      try Test.eq(tools.call(repo).select { |t| t.name == "mcp__shared__greeting" }.size, 1)
      try Test.eq(try said(tools, repo, "mcp__proj__cwd"), repo)

      second = try H.new_session_in(h, repo)
      outside = try H.new_session_in(h, stranger)
      # The events of the observer come in order: once the marker's server is listed, those of the sessions before it
      # were handled.
      _ = try H.new_session_in(h, marker)
      try wait_for(tools, marker, "mcp__mark__echo", true)
      try Test.eq(tools.call(stranger).any? { |t| t.name == "mcp__proj__echo" }, false)
      try Test.eq(starts(dir, "project"), 1)

      try drop(h, first)
      try Test.eq(try echoes(held, "mcp__proj__echo"), true)
      try drop(h, outside)
      try drop(h, second)
      try wait_for(tools, repo, "mcp__proj__echo", false)
      try gone(held, "mcp__proj__echo")

      _ = try H.new_session_in(h, repo)
      try wait_for(tools, repo, "mcp__proj__echo", true)
      Test.eq(starts(dir, "project"), 2)
    end

    mounted.stop.call()
    result
  end
end

# Sessions that start and end at the same time share one set of servers while one stays, and none is left when the last
# one ends, also when it ends while its servers still start.
def test_sessions_that_start_and_end_together_share_the_servers() -> Result[Void]
  S.within_dir do |dir|
    slow = JSON.object({
      "FAKE_MCP_GREETING": JSON.from("slow"),
      "FAKE_MCP_SLOW_MS": JSON.from("600"),
      "FAKE_MCP_STARTS": JSON.from("#{dir}/starts-slow"),
    })

    repo = try make_repo(dir, "repo", {"proj": try S.fake_server(slow)})
    try S.write_config(dir, {})
    mounted = try Builtins.mcp(Extensions.Served(registry: Extensions.Registry()), reader(dir), dir, [repo])
    tools = Extensions.late_tools(mounted.served).unwrap!
    result = H.using(wired(mounted)) do |h|
      opened = [1, 2, 3].map { |_| Task.spawn { H.new_session_in(h, repo) } }
      ids: List[String] = []
      for task in opened
        ids = ids.push(try Task.await(task))
      end

      try wait_for(tools, repo, "mcp__proj__echo", true)
      held = tools.call(repo)
      closing = ids.drop(1).map { |id| Task.spawn { drop(h, id) } }
      for task in closing
        try Task.await(task)
      end

      try Test.eq(try echoes(held, "mcp__proj__echo"), true)
      try Test.eq(starts(dir, "slow"), 1)
      try drop(h, ids[0])
      try wait_for(tools, repo, "mcp__proj__echo", false)
      # A session that ends while its servers still start stops them once they started, and the next one starts them
      # again.
      quick = try H.new_session_in(h, repo)
      try drop(h, quick)
      _ = try H.new_session_in(h, repo)
      try wait_for(tools, repo, "mcp__proj__echo", true)
      Test.eq(try echoes(tools.call(repo), "mcp__proj__echo"), true)
    end

    mounted.stop.call()
    result
  end
end

# A folder that no session event named (they can be lost) gets its servers at the first read of its tools, when its
# file has any; with no session of its own, the end of the next session stops them.
def test_a_folder_without_a_session_event_gets_its_servers_when_its_tools_are_read() -> Result[Void]
  S.within_dir do |dir|
    repo = try make_repo(dir, "repo", {"proj": try fake("project", dir)})
    plain = try make_repo(dir, "plain", {})
    try S.write_config(dir, {})
    mounted = try Builtins.mcp(Extensions.Served(registry: Extensions.Registry()), reader(dir), dir, [repo, plain])
    tools = Extensions.late_tools(mounted.served).unwrap!
    try Test.eq(tools.call(repo).size, 0)
    try Test.eq(tools.call(plain).size, 0)
    try wait_for(tools, repo, "mcp__proj__echo", true)
    held = tools.call(repo)
    result = H.using(wired(mounted)) do |h|
      id = try H.new_session_in(h, plain)
      try drop(h, id)
      gone(held, "mcp__proj__echo")
    end

    mounted.stop.call()
    result
  end
end

# Readers of one project file at once make the log folder together: none of them fails because another was first.
def test_readers_of_a_project_file_at_once_all_get_its_servers() -> Result[Void]
  S.within_dir do |dir|
    repo = try make_repo(dir, "repo", {"proj": try fake("project", dir)})
    try S.write_config(dir, {})
    read = reader(dir)
    state = "#{dir}/state"
    try Dir.mkdir_private(state)
    readers = (0...8).to_a.map { |_| Task.spawn { McpTools.project(repo, read, state, []) } }
    found = readers.map { |reader| Task.await(reader) }
    Test.eq(found.map { |f| f.ok? and f.unwrap!.servers.size == 1 }, [true, true, true, true, true, true, true, true])
  end
end

# A file that is not trusted, or that does not read, says so when a session opens, and so does a server left out.
def test_a_project_file_that_does_not_count_is_warned_about() -> Result[Void]
  S.within_dir do |dir|
    repo = try make_repo(dir, "repo", {"shared": try fake("project", dir)})
    try S.write_config(dir, {"shared": try fake("user", dir)})
    mounted = try Builtins.mcp(Extensions.Served(registry: Extensions.Registry()), reader(dir), dir, [repo])
    opened = ->(trusted: Bool) {
      place = Extensions.Place(root: repo, home: "", trusted: trusted)
      Extensions.open(mounted.served, place, "").flat_map { |o| o.warnings }
    }

    untrusted = opened.call(false)
    try Test.eq(untrusted.size, 1)
    try Test.assert(
      untrusted[0].include?("#{repo}/.finn/mcp.json") and untrusted[0].include?("FINN_TRUSTED_DIRS"),
      "#{untrusted}",
    )

    clash = opened.call(true)
    try Test.eq(clash.size, 1)
    try Test.assert(clash[0].include?("shared is left out") and clash[0].include?("rename"), "#{clash}")
    try File.write_text("#{repo}/.finn/mcp.json", "{oops")
    broken = opened.call(true)
    try Test.eq(broken.size, 1)
    try Test.assert(broken[0].start_with?("mcp: "), "#{broken}")
    mounted.stop.call()
    ok()
  end
end

# `/reload` reads the project files of the folders with sessions again: a changed file stops and starts its servers
# (and says how many), and a file that does not read keeps them, with a warning.
def test_a_reload_reads_the_project_files_again() -> Result[Void]
  S.within_dir do |dir|
    repo = try make_repo(dir, "repo", {"before": try fake("project", dir)})
    try S.write_config(dir, {})
    mounted = try Builtins.mcp(Extensions.Served(registry: Extensions.Registry()), reader(dir), dir, [repo])
    tools = Extensions.late_tools(mounted.served).unwrap!
    result = H.using(wired(mounted)) do |h|
      _ = try H.new_session_in(h, repo)
      try wait_for(tools, repo, "mcp__before__echo", true)
      held = tools.call(repo)
      try write_project(repo, {"after": try fake("project", dir)})
      done = try reload(h)
      try Test.eq(done.extensions, ["project MCP servers: 1 stopped, 1 started"])
      try wait_for(tools, repo, "mcp__after__echo", true)
      try Test.eq(tools.call(repo).any? { |t| t.name == "mcp__before__echo" }, false)
      try gone(held, "mcp__before__echo")
      try File.write_text("#{repo}/.finn/mcp.json", "{oops")
      bad = try reload(h)
      try Test.assert(bad.warnings.any? { |w| w.start_with?("extensions:") }, "#{bad.warnings}")
      try wait_for(tools, repo, "mcp__after__echo", true)
      try write_project(repo, {})
      removed = try reload(h)
      try Test.eq(removed.extensions, ["project MCP servers: 1 stopped, 0 started"])
      wait_for(tools, repo, "mcp__after__echo", false)
    end

    mounted.stop.call()
    result
  end
end

def wired(mounted: Builtins.Mounted) -> H.Setup
  H.Setup(
    replies: [],
    registry: some(mounted.served.registry),
    late_tools: Extensions.late_tools(mounted.served),
    reloads: [mounted.reload],
  )
end

def reload(h: H.Harness) -> Result[Protocol.Reloaded]
  answer = try H.post(h, Protocol.RELOAD_PATH, "")
  return error("reload: #{answer.status} #{answer.text}") if answer.status != 200

  Protocol.decode_reloaded(answer.text)
end

def drop(h: H.Harness, id: String) -> Result[Void]
  answer = try H.call(h, "DELETE", Protocol.session_path(id), "", H.auth(h))
  return error("DELETE: #{answer.status} #{answer.text}") if answer.status >= 300

  ok()
end

# The environment of the server: the user's file is the one `S.write_config` wrote, and the config folder is empty.
def reader(dir: String) -> Fn[String, Result[String]]
  ->(name: String) { var("#{dir}/xdg", some("#{dir}/mcp.json"), name) }
end

# The environment: the config folder, and `FINN_MCP_CONFIG` as `file` gives it (none is not set).
def var(config: String, file: Optional[String], name: String) -> Result[String]
  return ok(config) if name == "XDG_CONFIG_HOME"
  return file.to_result("not set") if name == "FINN_MCP_CONFIG"

  System.env(name)
end

# The variable `LEAK_ME` is the secret; the others are the environment's.
def if_leak(name: String, secret: String, dir: String) -> Result[String]
  return ok(secret) if name == "LEAK_ME"

  S.config_env(dir, name)
end

def servers_json(names: List[String]) -> String
  entries: Map[String, JSON.Value] = {}
  for name in names
    entries = entries.put(name, JSON.object({"command": JSON.from("true")}))
  end

  JSON.encode(JSON.object({"mcpServers": JSON.object(entries)}))
end

# A fake server that greets with `greeting` and notes each start of its process in `starts-GREETING` of `dir`.
def fake(greeting: String, dir: String) -> Result[JSON.Value]
  env = JSON.object({
    "FAKE_MCP_GREETING": JSON.from(greeting),
    "FAKE_MCP_STARTS": JSON.from("#{dir}/starts-#{greeting}"),
  })

  S.fake_server(env)
end

def starts(dir: String, greeting: String) -> Int
  File.read_text("#{dir}/starts-#{greeting}").unwrap_or("").split("\n").select { |l| l == "start" }.size
end

def make_repo(dir: String, name: String, servers: Map[String, JSON.Value]) -> Result[String]
  folder = "#{dir}/#{name}"
  try make_project_file(folder, "")
  try write_project(folder, servers)
  Path.real(folder)
end

def make_project_file(folder: String, text: String) -> Result[Void]
  try Dir.mkdir_private(folder)
  try Dir.mkdir_private("#{folder}/.finn")
  File.write_text("#{folder}/.finn/mcp.json", text)
end

def write_project(folder: String, servers: Map[String, JSON.Value]) -> Result[Void]
  File.write_text("#{folder}/.finn/mcp.json", JSON.encode(JSON.object({"mcpServers": JSON.object(servers)})))
end

# The text a tool with no input gives, as a session in `root` sees it.
def said(tools: Fn[String, List[Tools.Tool]], root: String, name: String) -> Result[String]
  ctx = try Tools.context(".", &H.fake_env, true, tools.call(root))
  out = Tools.run(ctx, name, JSON.object({}))
  return error("#{name}: #{out.text}") if out.is_error

  ok(out.text)
end

# Whether the tool `name` among `held` runs.
def echoes(held: List[Tools.Tool], name: String) -> Result[Bool]
  ctx = try Tools.context(".", &H.fake_env, true, held)
  ok(not Tools.run(ctx, name, JSON.object({"text": JSON.from("hi")})).is_error)
end

# Waits until the tool `name` is among the tools of a session in `root` (or is not), up to 30 seconds.
def wait_for(tools: Fn[String, List[Tools.Tool]], root: String, name: String, wanted: Bool) -> Result[Void]
  for _ in 0...300
    present = tools.call(root).any? { |t| t.name == name }
    return ok() if present == wanted

    Task.sleep(100)
  end

  error("#{name} did not change in 30 seconds")
end

# Waits until a call of the tool `name` among `held` fails: its server is stopped aside, so it takes a moment.
def gone(held: List[Tools.Tool], name: String) -> Result[Void]
  for _ in 0...300
    return ok() if not try echoes(held, name)

    Task.sleep(100)
  end

  error("a call of #{name} still works")
end
