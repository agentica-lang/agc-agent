import Protocol from "pkg/protocol/protocol"
import Profiles from "../src/config/profiles"
import Profile from "../src/session/profile"
import Fake from "support/fake_llm"
import H from "support/harness"

# `tools_allow` shows only its names, `tools_deny` all but its names, and `*` covers an MCP server's tools.
def test_a_profile_shows_the_tools_of_its_list() -> Result[Void]
  allow = try Profiles.parse("a.md", "a", "---\ntools_allow: [read_file, \"mcp__github__*\"]\n---\n")
  deny = try Profiles.parse("d.md", "d", "---\ntools_deny:\n  - bash\n  - mcp__*  # every server\n---\nBe brief.\n")
  plan = try Profiles.find(Profiles.Loaded(profiles: Profiles.builtins()), "plan")
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

# A stray file is skipped with a warning and a broken one fails only its own name; a BOM is fine, an
# empty `tools_allow`
# and a project file that replaces a profile warn, and a profile only an untrusted project has says so.
def test_a_stray_or_broken_file_fails_only_its_own_name() -> Result[Void]
  base = try fresh()
  user = "#{base}/user"
  try write("#{user}/README.md", "# notes\n")
  try write("#{user}/.hidden.md", "---\n---\n")
  try mkdirs("#{user}/folder.md")
  try write("#{user}/bad.md", "---\ncolour: red\n---\n")
  try write("#{user}/bom.md", "#{String.from_code(0xFEFF)}---\ndescription: with a BOM\n---\n")
  try write("#{user}/empty.md", "---\ntools_allow:\n---\n")
  try write("#{base}/.finn/profiles/plan.md", "---\ntools_deny: [bash]\n---\n")
  try write("#{base}/.finn/profiles/mine.md", "---\n---\n")
  loaded = Profiles.load(user, base, true)
  try Test.eq(loaded.warnings.select { |w| w.name.empty? }.size, 3)
  try Test.eq((try Profiles.find(loaded, "bom")).description, "with a BOM")
  try Test.eq((try Profiles.find(loaded, "build")).source, "built-in")
  plan = try Profiles.find(loaded, "plan")
  try Test.eq(plan.source, "project")
  try Test.assert(Profiles.warnings_of(loaded, plan, []).join(" ").include?("replaces the built-in profile plan"), "")
  empty = Profiles.warnings_of(loaded, try Profiles.find(loaded, "empty"), [])
  try Test.assert(empty.join(" ").include?("tools_allow is empty"), empty.join(" "))
  try failed(Profiles.find(loaded, "bad"), "bad.md")
  try Test.eq((try Profiles.find(Profiles.load(user, base, false), "plan")).source, "built-in")
  failed(Profiles.find(Profiles.load(user, base, false), "mine"), "not trusted")
end

# A saved session whose profile file is gone or broken refuses turns and shows no tool, also after a provider switch.
def test_a_session_whose_profile_does_not_load_fails_closed() -> Result[Void]
  setup = H.Setup(replies: [], profiles: true, providers: ["other"])
  H.using(setup) do |h|
    dir = "#{h.base}/config/finn/profiles"
    try write("#{dir}/gone.md", "---\ntools_deny: [bash]\n---\n")
    try write("#{dir}/bad.md", "---\ntools_deny: [bash]\n---\n")
    ids = [
      try H.new_session_in(h, h.work, profile: some("gone")),
      try H.new_session_in(h, h.work, profile: some("bad")),
    ]

    try Path.remove("#{dir}/gone.md")
    try File.write_text("#{dir}/bad.md", "---\ncolour: red\n---\n")
    H.restarted(h, setup, "") do |r|
      change = Protocol.encode_update_session(Protocol.UpdateSession(provider: some("other")))
      for id in ids
        try Test.eq((try H.send(r, id, "Hi.")).status, 503)
        try Test.eq((try H.call(r, "PATCH", Protocol.session_path(id), change, H.auth(r))).status, 200)
        try Test.eq((try H.send(r, id, "Hi.")).status, 503)
        profile = (try H.session(r, id)).profile
        try Test.eq(profile.map { |p| [p.source, p.warnings.size.to_s] }, some(["", "1"]))
      end

      Test.eq(Profile.shows_of(error("gone")).call("read_file"), false)
    end
  end
end

# `plan` on the Responses API offers no `apply_patch`, which `build` offers there.
def test_plan_hides_apply_patch_on_the_responses_api() -> Result[Void]
  H.using(H.Setup(api: "openai_responses", replies: ["text.sse", "text.sse"])) do |h|
    for profile in ["build", "plan"]
      id = try H.new_session_in(h, h.work, profile: some(profile))
      a = try H.subscribe(h, id)
      _ = try H.send(h, id, "Hi.")
      a = try H.until(a, Protocol.EventKind.TurnFinished)
      H.close(a)
      try Test.eq(names(try H.next_request(h)).include?("apply_patch"), profile == "build")
    end

    ok()
  end
end

# The snapshot names the profile and where it comes from, and a fork keeps it.
def test_a_fork_keeps_the_profile() -> Result[Void]
  H.using(H.Setup(replies: ["text.sse"])) do |h|
    id = try H.new_session_in(h, h.work, profile: some("plan"))
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Hi.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    fork = try H.post(h, Protocol.fork_path(id), Protocol.encode_fork(Protocol.Fork()))
    forked = (try Protocol.decode_branched(fork.text)).id
    for session in [id, forked]
      profile = (try H.session(h, session)).profile
      try Test.eq(profile.map { |p| [p.name, p.source] }, some(["plan", "built-in"]))
    end

    ok()
  end
end

def failed[T](result: Result[T], part: String) -> Result[Void]
  case result
    ok(_) -> error("no error with #{part}")
    error(e) -> Test.assert(e.message.include?(part), e.message)
  end
end

def fresh() -> Result[String]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/finn-profiles-#{Random.int(0, 999_999_999)}"
  try Dir.mkdir(dir)
  Path.real(dir)
end

def names(request: Fake.Seen) -> List[String]
  json = JSON.parse(request.body).unwrap_or(JSON.object({}))
  listed: List[JSON.Value] = JSON.list(JSON.get(json, "tools").unwrap_or(JSON.array([]))).unwrap_or([])
  listed.map { |tool| name_of(tool) }
end

def name_of(tool: JSON.Value) -> String
  case JSON.get(tool, "name")
    ok(name) -> return JSON.string(name).unwrap_or("")
    error(_) -> nil
  end

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
