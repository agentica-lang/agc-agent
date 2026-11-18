# `POST /v1/reload`: the server reads its skills, config file and project instructions again; a session that runs
# uses them from its next turn, and a running turn keeps what it started with.

import Protocol from "pkg/protocol/protocol"
import Fake from "support/fake_llm"
import H from "support/harness"

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
