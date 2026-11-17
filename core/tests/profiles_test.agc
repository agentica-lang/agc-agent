import Protocol from "pkg/protocol/protocol"
import Profiles from "../src/config/profiles"
import Fake from "support/fake_llm"
import H from "support/harness"

# `tools_allow` shows only its names, `tools_deny` all but its names, and `*` covers an MCP server's tools.
def test_a_profile_shows_the_tools_of_its_list() -> Result[Void]
  allow = try Profiles.parse("a.md", "a", "---\ntools_allow: [read_file, \"mcp__github__*\"]\n---\n")
  deny = try Profiles.parse("d.md", "d", "---\ntools_deny:\n  - bash\n  - mcp__*  # every server\n---\nBe brief.\n")
  plan = try Profiles.find(Profiles.builtins(), "plan")
  tools = [
    "read_file", "bash", "write_file", "edit_file", "apply_patch", "run_script", "mcp__github__issue", "mcp__x__y",
  ]

  try Test.eq(tools.select { |t| Profiles.exposes?(allow, t) }, ["read_file", "mcp__github__issue"])
  try Test.eq(
    tools.select { |t| Profiles.exposes?(deny, t) },
    ["read_file", "write_file", "edit_file", "apply_patch", "run_script"],
  )

  try Test.eq(tools.select { |t| Profiles.exposes?(plan, t) }, ["read_file"])
  try Test.eq(deny.prompt, "Be brief.")
  Test.eq(
    Profiles.unknown(allow.with(allow: some(["read_fil", "grep", "mcp__x__y", "g*"])), ["read_file", "grep"]),
    ["read_fil"],
  )
end

# A bad file is an error that names the file and the key.
def test_a_bad_profile_names_its_file_and_key() -> Result[Void]
  rows = [
    ["---\ncolour: red\n---\n", "colour"],
    ["---\ntools_allow: [bash]\ntools_deny: [grep]\n---\n", "tools_deny"],
    ["---\ntools_allow: bash\n---\n", "tools_allow"],
    ["no front matter\n", "---"],
  ]

  for row in rows
    case Profiles.parse("p.md", "p", row[0])
      ok(_) -> return error("parsed: #{row[0]}")
      error(e) -> try Test.assert(e.message.include?("p.md") and e.message.include?(row[1]), e.message)
    end
  end

  ok()
end

# Under `plan` the model sees no bash and no writes, a call to bash is refused without asking, and the profile stays
# after a restart.
def test_plan_hides_bash_and_writes_and_refuses_a_call() -> Result[Void]
  setup = H.Setup(replies: ["bash_echo.sse", "text.sse"])
  H.using(setup) do |h|
    id = try H.new_session_in(h, h.work, profile: some("plan"))
    H.restarted(h, setup, "") do |r|
      a = try H.subscribe(r, id)
      _ = try H.send(r, id, "Echo it.")
      a = try H.until(a, Protocol.EventKind.TurnFinished)
      H.close(a)
      try Test.eq(H.kinds(a.seen).include?("approval_requested"), false)
      try Test.eq(names(try H.next_request(r)), ["read_file", "glob", "grep", "todo_write"])
      second = try H.request_messages(r, 1)
      Test.eq(JSON.get(second.last, "content"), ok(JSON.from("Error: the session's profile hides bash")))
    end
  end
end

# A user profile that shows bash does not get past a deny rule of the config.
def test_a_deny_rule_wins_over_a_profile() -> Result[Void]
  setup = H.Setup(replies: ["bash_echo.sse", "text.sse"], deny: ["bash(*)"], profiles: true)
  H.using(setup) do |h|
    try write("#{h.base}/config/finn/profiles/shell.md", "---\ntools_allow: [bash]\n---\n")
    id = try H.new_session_in(h, h.work, profile: some("shell"))
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Echo it.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(names(try H.next_request(h)), ["bash"])
    second = try H.request_messages(h, 1)
    Test.eq(JSON.get(second.last, "content"), ok(JSON.from("Error: denied by a rule of the config")))
  end
end

# A project's profiles count only in a trusted folder; an unknown name is an error.
def test_an_untrusted_project_profile_is_not_read() -> Result[Void]
  for trusted in [false, true]
    try H.using(H.Setup(replies: [], skills: trusted)) do |h|
      try write("#{h.work}/.finn/profiles/mine.md", "---\ndescription: mine\n---\n")
      try Test.eq(H.new_session_in(h, h.work, profile: some("mine")).ok?, trusted)
      Test.eq(H.new_session_in(h, h.work, profile: some("nope")).ok?, false)
    end
  end

  ok()
end

def names(request: Fake.Seen) -> List[String]
  json = JSON.parse(request.body).unwrap_or(JSON.object({}))
  listed: List[JSON.Value] = JSON.list(JSON.get(json, "tools").unwrap_or(JSON.array([]))).unwrap_or([])
  listed.map { |tool| name_of(tool) }
end

def name_of(tool: JSON.Value) -> String
  case JSON.get(tool, "function")
    ok(function) -> JSON.string(JSON.get(function, "name").unwrap_or(JSON.from(""))).unwrap_or("")
    error(_) -> ""
  end
end

def write(path: String, text: String) -> Result[Void]
  try mkdirs(path.slice(0, path.length - path.split("/").last.length - 1))
  File.write_text(path, text)
end

def mkdirs(dir: String) -> Result[Void]
  return ok() if File.stat(dir).ok?

  try mkdirs(dir.slice(0, dir.length - dir.split("/").last.length - 1))
  Dir.mkdir(dir)
end
