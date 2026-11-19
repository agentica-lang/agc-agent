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

# The user's file is `mcp.json` of the config folder; `FINN_MCP_CONFIG` replaces it, and a file it names that is not
# there is an error. A project server starts in its folder and logs under `project-`.
def test_the_config_files_are_found_by_default_and_the_variable_replaces_the_default() -> Result[Void]
  S.within_dir do |dir|
    config = "#{dir}/xdg/finn"
    try Dir.mkdir_private("#{dir}/xdg")
    try Dir.mkdir_private(config)
    other = "#{dir}/other.json"
    try File.write_text("#{config}/mcp.json", servers_json(["user"]))
    try File.write_text(other, servers_json(["named"]))
    by_default = ->(name: String) { var("#{dir}/xdg", "", name) }
    named = ->(name: String) { var("#{dir}/xdg", other, name) }
    try Test.eq((try McpTools.servers(by_default, dir)).map { |s| s.name }, ["user"])
    try Test.eq((try McpTools.servers(named, dir)).map { |s| s.name }, ["named"])
    try Test.eq((try McpTools.servers(by_default, dir))[0].log, "#{dir}/mcp/user.log")
    try Test.eq((try McpTools.servers(->(n: String) { var("#{dir}/none", "", n) }, dir)).size, 0)
    try Test.eq(McpTools.servers(->(n: String) { var(dir, "#{dir}/missing.json", n) }, dir).ok?, false)

    folder = "#{dir}/repo"
    try Dir.mkdir_private(folder)
    try Dir.mkdir_private("#{folder}/.finn")
    try File.write_text("#{folder}/.finn/mcp.json", servers_json(["proj"]))
    found = try McpTools.project(folder, by_default, dir)
    try Test.eq([found[0].cwd, found[0].log], [folder, "#{dir}/mcp/project-proj.log"])
    Test.eq((try McpTools.project("#{dir}/none", by_default, dir)).size, 0)
  end
end

# The servers of a trusted folder start with its first session, its sessions share them, and the end of the last one
# stops them; a project server of the name of a user server takes its place in that folder; an untrusted folder gets
# nothing; the server starts in the folder.
def test_project_servers_belong_to_the_sessions_of_their_folder() -> Result[Void]
  S.within_dir do |dir|
    repo = try make_repo(dir, "repo", {"proj": try fake("project", dir), "shared": try fake("project-shared", dir)})
    stranger = try make_repo(dir, "stranger", {"proj": try fake("project", dir)})
    try S.write_config(dir, {"shared": try fake("user", dir)})
    mounted = try Builtins.mcp(Extensions.Served(registry: Extensions.Registry()), reader(dir), dir, [repo])
    tools = Extensions.late_tools(mounted.served).unwrap!
    result = H.using(wired(mounted)) do |h|
      first = try H.new_session_in(h, repo)
      try wait_for(tools, repo, "mcp__proj__echo", true)
      held = tools.call(repo)
      try Test.eq(try said(tools, repo, "mcp__shared__greeting"), "project-shared")
      try Test.eq(try said(tools, ".", "mcp__shared__greeting"), "user")
      try Test.eq(try said(tools, repo, "mcp__proj__cwd"), repo)

      second = try H.new_session_in(h, repo)
      outside = try H.new_session_in(h, stranger)
      Task.sleep(300)
      try Test.eq(tools.call(stranger).any? { |t| t.name == "mcp__proj__echo" }, false)
      try Test.eq(try said(tools, stranger, "mcp__shared__greeting"), "user")
      try Test.eq(starts(dir, "project"), 1)

      try drop(h, first)
      try Test.eq(try echoes(held, "mcp__proj__echo"), true)
      try drop(h, outside)
      try drop(h, second)
      try wait_for(tools, repo, "mcp__proj__echo", false)
      try gone(held, "mcp__proj__echo")
      try Test.eq(try said(tools, repo, "mcp__shared__greeting"), "user")

      _ = try H.new_session_in(h, repo)
      try wait_for(tools, repo, "mcp__proj__echo", true)
      Test.eq(starts(dir, "project"), 2)
    end

    mounted.stop.call()
    result
  end
end

# A file that is not trusted, that does not read, or that names a user server says so when a session opens.
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
    try Test.assert(clash[0].include?("replaces the user's server shared"), "#{clash}")
    try File.write_text("#{repo}/.finn/mcp.json", "{oops")
    broken = opened.call(true)
    try Test.eq(broken.size, 1)
    try Test.assert(broken[0].start_with?("mcp: "), "#{broken}")
    mounted.stop.call()
    ok()
  end
end

# `/reload` reads the project files of the folders with sessions again: a changed file restarts its servers, and a file
# that does not read keeps them, with a warning.
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
      try Test.eq(done.extensions, ["restarting 1 project MCP server(s)"])
      try wait_for(tools, repo, "mcp__after__echo", true)
      try Test.eq(tools.call(repo).any? { |t| t.name == "mcp__before__echo" }, false)
      try gone(held, "mcp__before__echo")
      try File.write_text("#{repo}/.finn/mcp.json", "{oops")
      bad = try reload(h)
      try Test.assert(bad.warnings.any? { |w| w.start_with?("extensions:") }, "#{bad.warnings}")
      try wait_for(tools, repo, "mcp__after__echo", true)
      try write_project(repo, {"again": try fake("project", dir)})
      try reload(h)
      wait_for(tools, repo, "mcp__again__echo", true)
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
def reader(dir: String) -> Fn[String, Result[String]] = ->(name: String) { var("#{dir}/xdg", "#{dir}/mcp.json", name) }

def var(config: String, file: String, name: String) -> Result[String]
  return ok(config) if name == "XDG_CONFIG_HOME"
  return ok(file) if name == "FINN_MCP_CONFIG" and not file.empty?
  return error("not set") if name == "FINN_MCP_CONFIG"

  System.env(name)
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
  try Dir.mkdir_private(folder)
  try Dir.mkdir_private("#{folder}/.finn")
  try write_project(folder, servers)
  Path.real(folder)
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
