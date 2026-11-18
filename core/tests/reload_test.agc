# `POST /v1/reload`: the server reads its skills, config file and project instructions again; a session that runs
# uses them from its next turn, and a running turn keeps what it started with.

import Protocol from "pkg/protocol/protocol"
import Builtins from "../src/session/builtins"
import Extensions from "../src/config/registry"
import Tools from "../src/tools/tools"
import Fake from "support/fake_llm"
import H from "support/harness"
import S from "support/mcp_fakes"

LINT = "---\nname: lint\ndescription: Run the linter.\n---\nLint it.\n"

# A skill added after a session started is in its system prompt from its next turn, and gone again once it is removed;
# the answer says which.
def test_a_reload_adds_and_removes_skills_for_the_next_turn() -> Result[Void]
  H.using(H.Setup(replies: ["text.sse", "text.sse", "text.sse"], skills: true)) do |h|
    skill = "#{h.base}/home/.agents/skills/lint"
    id = try H.new_session(h)
    try write("#{skill}/SKILL.md", LINT)
    added = try reload(h)
    try Test.eq([added.skills_added, added.skills_removed], [["lint"], []])
    try Test.eq(added.sessions, 1)
    try Test.eq(try system_after(h, id, "One."), true)
    try Path.remove(skill)
    removed = try reload(h)
    try Test.eq([removed.skills_added, removed.skills_removed], [[], ["lint"]])
    Test.eq(try system_after(h, id, "Two."), false)
  end
end

# A deny rule added to the config file applies to the next turn of a session that already runs.
def test_a_reload_applies_the_config_to_the_next_turn() -> Result[Void]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/core-reload-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  config = "#{dir}/config.json"
  try File.write_text(config, "{}")
  setup = H.Setup(
    replies: ["write_file.sse", "text.sse", "write_file.sse", "text.sse"],
    live: true,
    env: {"FINN_CONFIG": config, "FINN_STATE_DIR": dir, "FINN_DATA_DIR": dir},
  )

  result = H.using(setup) do |h|
    id = try H.new_session(h)
    try Test.eq(try wrote(h, id, "Write it."), true)
    try Path.remove("#{h.work}/hello.txt")
    try File.write_text(config, "{\"permission\": [\"deny write_file(hello.txt)\"]}")
    done = try reload(h)
    try Test.eq(done.config, "reloaded")
    try Test.eq(done.sessions, 1)
    try Test.eq(try wrote(h, id, "Write it again."), false)
    again = try reload(h)
    Test.eq(again.config, "unchanged")
  end

  _ = Path.remove(dir)
  result
end

# A config file that does not read is kept back with the reason: the rules of the last good read still apply.
def test_a_broken_config_is_kept_back_with_a_warning() -> Result[Void]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/core-reload-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  config = "#{dir}/config.json"
  try File.write_text(config, "{\"permission\": [\"deny write_file(hello.txt)\"]}")
  setup = H.Setup(
    replies: ["write_file.sse", "text.sse"],
    live: true,
    env: {"FINN_CONFIG": config, "FINN_STATE_DIR": dir, "FINN_DATA_DIR": dir},
  )

  result = H.using(setup) do |h|
    id = try H.new_session(h)
    try File.write_text(config, "{oops")
    done = try reload(h)
    try Test.assert(done.config.start_with?("kept"), done.config)
    try Test.assert(done.warnings.any? { |w| w.include?("config: kept") }, "#{done.warnings}")
    Test.eq(try wrote(h, id, "Write it."), false)
  end

  _ = Path.remove(dir)
  result
end

# A turn that runs keeps what it started with, and the reload does not wait for it: the next turn has the new skill.
def test_a_reload_while_a_turn_runs_applies_from_the_next_turn() -> Result[Void]
  H.using(H.Setup(replies: ["text.sse@hold", "text.sse"], skills: true)) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "One.")
    a = try H.until(a, Protocol.EventKind.TurnStarted)
    try write("#{h.base}/home/.agents/skills/lint/SKILL.md", LINT)
    done = try reload(h)
    try Test.eq(done.skills_added, ["lint"])
    try Test.eq(done.sessions, 1)
    H.release(h)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    try Test.eq(system_has_lint(try H.next_request(h)), false)
    _ = try H.send(h, id, "Two.")
    a = try H.until(a.with(seen: []), Protocol.EventKind.TurnFinished)
    H.close(a)
    Test.eq(system_has_lint(try H.next_request(h)), true)
  end
end

def reload(h: H.Harness) -> Result[Protocol.Reloaded]
  answer = try H.post(h, Protocol.RELOAD_PATH, "")
  return error("reload: #{answer.status} #{answer.text}") if answer.status != 200

  Protocol.decode_reloaded(answer.text)
end

# Sends a message and says whether the system prompt of its call lists the skill `lint`.
def system_after(h: H.Harness, id: String, text: String) -> Result[Bool]
  a = try H.subscribe(h, id)
  _ = try H.send(h, id, text)
  a = try H.until(a, Protocol.EventKind.TurnFinished)
  H.close(a)
  ok(system_has_lint(try H.next_request(h)))
end

def system_has_lint(request: Fake.Seen) -> Bool
  messages = JSON.list(JSON.get(JSON.parse(request.body).unwrap_or(JSON.null()), "messages").unwrap_or(JSON.null()))
  system = JSON.string(JSON.get(messages.unwrap_or([JSON.null()])[0], "content").unwrap_or(JSON.null()))
  system.unwrap_or("").include?("<name>lint</name>")
end

# Whether the turn wrote `hello.txt`: a call that a deny rule refuses does not.
def wrote(h: H.Harness, id: String, text: String) -> Result[Bool]
  a = try H.subscribe(h, id)
  _ = try H.send(h, id, text)
  a = try H.until(a, Protocol.EventKind.TurnFinished)
  H.close(a)
  ok(File.stat("#{h.work}/hello.txt").ok?)
end

def write(path: String, text: String) -> Result[Void]
  try mkdirs(path.slice(0, path.length - path.split("/").last.length - 1))
  File.write_text(path, text)
end

def mkdirs(path: String) -> Result[Void]
  return ok() if File.stat(path).ok?

  parts = path.split("/")
  try mkdirs(parts.take(parts.size - 1).join("/"))
  Dir.mkdir(path)
end

# The files program, the mouse and the approvals of a reload apply to the server at once: the files of a session and
# the status the clients read.
def test_a_reload_changes_the_files_program_the_mouse_and_the_approvals() -> Result[Void]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/core-reload-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  config = "#{dir}/config.json"
  try File.write_text(config, "{}")
  setup = H.Setup(replies: [], live: true, env: {"FINN_CONFIG": config, "FINN_STATE_DIR": dir, "FINN_DATA_DIR": dir})
  result = H.using(setup) do |h|
    try File.write_text("#{h.work}/a.txt", "a")
    try File.write_text("#{h.work}/b.txt", "b")
    id = try H.new_session(h)
    before = try Protocol.decode_file_list((try H.get(h, Protocol.files_path(id))).text)
    first = try Protocol.decode_server_status((try H.get(h, Protocol.SERVER_PATH)).text)
    try Test.eq(before.files.size > 1, true)
    try Test.eq([first.mouse, first.approvals], [some(true), some(false)])
    command = JSON.from(["sh", "-c", "printf 'b.txt\\n'"])
    files = JSON.object({"command": command})
    try File.write_text(
      config,
      JSON.encode(JSON.object({"files": files, "mouse": JSON.from(false), "approvals": JSON.from(true)})),
    )

    done = try reload(h)
    try Test.eq(done.rules, 0)
    try Test.eq(done.approvals, true)
    after = try Protocol.decode_file_list((try H.get(h, Protocol.files_path(id))).text)
    second = try Protocol.decode_server_status((try H.get(h, Protocol.SERVER_PATH)).text)
    try Test.eq(after.files, ["b.txt"])
    Test.eq([second.mouse, second.approvals], [some(false), some(true)])
  end

  _ = Path.remove(dir)
  result
end

# A request without the token is refused.
def test_a_reload_needs_the_token() -> Result[Void]
  H.using(H.Setup(replies: [])) do |h| Test.eq((try H.call(h, "POST", Protocol.RELOAD_PATH, "", [])).status, 401) end
end

# A reload swaps the MCP servers at once and stops the old ones aside: the tools of the new list come, a call on an old
# tool fails with an error result, and a config of servers that does not read keeps the ones that run, with a warning.
def test_a_reload_swaps_the_mcp_servers_and_keeps_them_when_the_file_is_bad() -> Result[Void]
  S.within_dir do |dir|
    try S.write_config(dir, {"fake": try S.fake_server(JSON.object({}))})
    read = ->(name: String) { S.config_env(dir, name) }
    mounted = try Builtins.mcp(Extensions.Served(registry: Extensions.Registry()), read, dir)
    tools = Extensions.late_tools(mounted.served).unwrap!
    try listed(tools, "mcp__fake__echo", true)
    old = tools.call()
    try S.write_config(dir, {"other": try S.fake_server(JSON.object({}))})
    setup = H.Setup(replies: [], late_tools: some(tools), reloads: [mounted.reload])
    result = H.using(setup) do |h|
      done = try reload(h)
      try Test.eq(done.extensions, ["restarting 1 MCP server(s)"])
      try listed(tools, "mcp__other__echo", true)
      try listed(tools, "mcp__fake__echo", false)
      ctx = try Tools.context(".", &H.fake_env, true, old)
      gone = Tools.run(ctx, "mcp__fake__echo", JSON.object({"text": JSON.from("hi")}))
      try Test.eq(gone.is_error, true)
      try File.write_text("#{dir}/mcp.json", "{oops")
      bad = try reload(h)
      try Test.assert(bad.warnings.any? { |w| w.start_with?("extensions:") }, "#{bad.warnings}")
      try listed(tools, "mcp__other__echo", true)
      try S.write_config(dir, {})
      try reload(h)
      listed(tools, "mcp__other__echo", false)
    end

    mounted.stop.call()
    result
  end
end

# Waits until the tool `name` is in the tools (or is not), up to 30 seconds.
def listed(tools: Fn[List[Tools.Tool]], name: String, wanted: Bool) -> Result[Void]
  for _ in 0...300
    present = tools.call().any? { |t| t.name == name }
    return ok() if present == wanted

    Task.sleep(100)
  end

  error("#{name} did not change in 30 seconds")
end
