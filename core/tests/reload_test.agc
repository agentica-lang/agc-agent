# `POST /v1/reload`: the server reads its skills, config file and project instructions again; a session that runs
# uses them from its next turn, and a running turn keeps what it started with.

import Protocol from "pkg/protocol/protocol"
import Builtins from "../src/session/builtins"
import Extensions from "../src/config/registry"
import Skills from "../src/ext/skills"
import Tools from "../src/tools/tools"
import Fake from "support/fake_llm"
import H from "support/harness"
import S from "support/mcp_fakes"

LINT = "---\nname: lint\ndescription: Run the linter.\n---\nLint it.\n"

def test_skill_paths_follow_config_on_reload() -> Result[Void]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/core-skill-config-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  config = "#{dir}/config.json"
  try File.write_text(config, "{}")
  setup = H.Setup(
    replies: ["text.sse", "text.sse", "text.sse", "text.sse", "text.sse", "text.sse"],
    skills: true,
    live: true,
    env: {"FINN_CONFIG": config, "FINN_STATE_DIR": dir, "FINN_DATA_DIR": dir},
  )

  result = H.using(setup) do |h|
    example = Skills.catalog([
      Skills.Skill(name: "example", description: "Example catalog", location: "", dir: "", for_model: true),
    ])

    instructions = "Keep these instructions.\n\n```text\n#{example}```\n"
    try File.write_text("#{h.work}/AGENTS.md", instructions)
    try write("#{h.base}/home/.agents/skills/lint/SKILL.md", LINT)
    id = try H.new_session(h)
    try Test.eq(try system_after(h, id, "Before."), false)
    try File.write_text(config, "{\"skills\":{\"user\":[\"~/.agents/skills\"]}}")
    added = try reload(h)
    try Test.eq(added.skills_added, ["lint"])
    try Test.eq(try system_after(h, id, "Enabled."), true)
    try File.write_text(config, "{\"skills\":{\"project\":[\"../outside\"]}}")
    invalid = try reload(h)
    try Test.assert(invalid.config.start_with?("kept"), invalid.config)
    try Test.eq(invalid.skills_removed, [])
    try File.write_text(config, "{}")
    H.restarted(h, setup, "") do |r|
      resumed = try request_after(r, id, "Resumed.")
      try Test.eq(system_has_lint(resumed), false)
      try Test.assert(system_text(resumed).include?(instructions), "the example catalog is still in AGENTS.md")
      try File.write_text(config, "{\"skills\":{\"user\":[\"~/.agents/skills\"]}}")
      try Test.eq((try reload(r)).skills_added, ["lint"])
      try Test.eq(try system_after(r, id, "Enabled again."), true)
      try Path.remove("#{r.base}/home/.agents/skills/lint")
      try Test.eq((try reload(r)).skills_removed, ["lint"])
      try write("#{r.base}/home/.agents/skills/lint/SKILL.md", LINT)
      fork = try H.post(r, Protocol.fork_path(id), "{}")
      forked = (try Protocol.decode_branched(fork.text)).id
      try Test.eq(try system_after(r, forked, "In the fork."), false)
      H.restarted(r, setup, "") do |again| Test.eq(try system_after(again, id, "After reload and restart."), false) end
    end
  end

  _ = Path.remove(dir)
  result
end

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
  ok(system_has_lint(try request_after(h, id, text)))
end

def request_after(h: H.Harness, id: String, text: String) -> Result[Fake.Seen]
  a = try H.subscribe(h, id)
  _ = try H.send(h, id, text)
  a = try H.until(a, Protocol.EventKind.TurnFinished)
  H.close(a)
  H.next_request(h)
end

def system_has_lint(request: Fake.Seen) -> Bool = system_text(request).include?("<name>lint</name>")

def system_text(request: Fake.Seen) -> String
  messages = JSON.list(JSON.get(JSON.parse(request.body).unwrap_or(JSON.null()), "messages").unwrap_or(JSON.null()))
  system = JSON.string(JSON.get(messages.unwrap_or([JSON.null()])[0], "content").unwrap_or(JSON.null()))
  system.unwrap_or("")
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
    try Test.eq(first.clipboard, some(Protocol.ClipboardSetting()))
    try Test.eq(first.keys, some([]))
    try Test.eq(first.statusline, none)
    command = JSON.from(["sh", "-c", "printf 'b.txt\\n'"])
    files = JSON.object({"command": command})
    try File.write_text(
      config,
      JSON.encode(
        JSON.object({
          "files": files,
          "mouse": JSON.from(false),
          "approvals": JSON.from(true),
          "clipboard": JSON.from("osc52"),
          "keys": JSON.object({"logs": JSON.from("f9")}),
          "status_line": JSON.object({"left": JSON.from(["chatgpt.quota", "state"]), "right": JSON.from(["model"])}),
        }),
      ),
    )

    done = try reload(h)
    try Test.eq(done.rules, 0)
    try Test.eq(done.approvals, true)
    after = try Protocol.decode_file_list((try H.get(h, Protocol.files_path(id))).text)
    second = try Protocol.decode_server_status((try H.get(h, Protocol.SERVER_PATH)).text)
    try Test.eq(after.files, ["b.txt"])
    try Test.eq([second.mouse, second.approvals], [some(false), some(true)])
    try Test.eq(second.keys, some([Protocol.KeySetting(action: "logs", key: "f9")]))
    try Test.eq(second.statusline, some(Protocol.StatusLine(left: ["chatgpt.quota", "state"], right: ["model"])))
    try Test.eq(second.clipboard, some(Protocol.ClipboardSetting(provider: "osc52")))
    try File.write_text(config, "{\"status_line\": 5}")
    bad = try reload(h)
    try Test.eq(bad.warnings.select { |w| w.include?("status_line") }.size, 1)
    Test.eq((try Protocol.decode_server_status((try H.get(h, Protocol.SERVER_PATH)).text)).statusline, none)
  end

  _ = Path.remove(dir)
  result
end

def test_a_reload_applies_denies_when_saving_the_prompt_fails() -> Result[Void]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/core-reload-deny-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  config = "#{dir}/config.json"
  try File.write_text(config, "{}")
  setup = H.Setup(
    replies: ["write_file.sse", "text.sse"],
    live: true,
    env: {"FINN_CONFIG": config, "FINN_STATE_DIR": dir, "FINN_DATA_DIR": dir},
  )

  result = H.using(setup) do |h|
    id = try H.new_session(h)
    prompt = "#{H.sessions(h)}/#{id}.prompt.json"
    try Dir.mkdir(prompt)
    try File.write_text("#{h.work}/AGENTS.md", "New project instructions.\n")
    try File.write_text(config, "{\"permission\":[\"deny write_file(hello.txt)\"]}")
    done = try reload(h)
    try Test.eq(done.rules, 1)
    try Test.eq(try wrote(h, id, "Write hello.txt."), false)
    try Test.assert(done.warnings.any? { |w| w.include?("session prompt") }, done.warnings.join("\n"))
    try Path.remove(prompt)
    _ = try reload(h)
    Test.eq((try File.stat(prompt)).kind, "file")
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
    old = tools.call(".")
    try S.write_config(dir, {"other": try S.fake_server(JSON.object({}))})
    setup = H.Setup(replies: [], late_tools: some(tools), reloads: [mounted.reload])
    result = H.using(setup) do |h|
      done = try reload(h)
      try Test.eq(done.extensions, ["restarting 1 MCP server(s)"])
      try listed(tools, "mcp__other__echo", true)
      try listed(tools, "mcp__fake__echo", false)
      try fails(old, "mcp__fake__echo")
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
def listed(tools: Fn[String, List[Tools.Tool]], name: String, wanted: Bool) -> Result[Void]
  for _ in 0...300
    present = tools.call(".").any? { |t| t.name == name }
    return ok() if present == wanted

    Task.sleep(100)
  end

  error("#{name} did not change in 30 seconds")
end

# Waits until a call of the old tool `name` fails: the old servers are stopped aside, so it takes a moment.
def fails(old: List[Tools.Tool], name: String) -> Result[Void]
  ctx = try Tools.context(".", &H.fake_env, true, old)
  for _ in 0...300
    return ok() if Tools.run(ctx, name, JSON.object({"text": JSON.from("hi")})).is_error

    Task.sleep(100)
  end

  error("a call of #{name} still works")
end

# A reload that finds another one running waits a while and then says so, with the kind that is a 409; the next one
# runs.
def test_a_reload_that_waits_too_long_for_another_is_refused() -> Result[Void]
  H.using(H.Setup(replies: [], reload_wait_ms: 200)) do |h|
    token = h.server.sessions.reloading.recv(0)
    try Test.eq(token.ok?, true)
    busy = try H.post(h, Protocol.RELOAD_PATH, "")
    try Test.eq(busy.status, 409)
    try Test.eq((try Protocol.decode_failure(busy.text)).kind, Protocol.KIND_RELOAD_BUSY)
    _ = h.server.sessions.reloading.send(true, 0)
    ok_again = try H.post(h, Protocol.RELOAD_PATH, "")
    Test.eq(ok_again.status, 200)
  end
end
