# Agent Skills: discovery from the session folder (trusted) and the home folder, the catalog in the system prompt,
# `activate_skill`, `/name` from the user, the marks a session keeps, and the frontmatter as other clients write it.

import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import Skills from "../src/skills"
import Tools from "../src/tools"
import H from "support/harness"

RELEASE = "---\nname: release\ndescription: Cut a release: tag, notes, publish.\n---\n\n# Release\n\nRun the steps.\n"
LINT_HOME = "---\nname: lint\ndescription: The user's <lint> & more.\n---\nUser lint.\n"
LINT_PROJECT = "---\nname: lint\ndescription: The project's lint.\n---\nProject lint.\n"
DEPLOY = "---\nname: deploy\ndescription: Deploy it.\ndisable-model-invocation: true\n---\nDeploy steps.\n"

# A skill loads once a session, by the model or by the user, and stays loaded after a restart; the model cannot load
# a skill that only the user loads.
def test_the_model_and_the_user_load_skills_once() -> Result[Void]
  replies = ["activate_skill.sse", "activate_skill.sse", "activate_deploy.sse", "text.sse", "text.sse", "text.sse"]
  setup = H.Setup(replies: replies, skills: true)
  H.using(setup) do |h|
    home = "#{h.base}/home"
    try write("#{home}/.agents/skills/release/SKILL.md", RELEASE)
    try write("#{home}/.agents/skills/release/references/steps.md", "1. tag\n")
    try write("#{home}/.claude/skills/lint/SKILL.md", LINT_HOME)
    try write("#{home}/.finn/skills/deploy/SKILL.md", DEPLOY)
    try write("#{h.work}/.finn/skills/lint/SKILL.md", LINT_PROJECT)
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Release it.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    first = try JSON.parse((try H.next_request(h)).body)
    system = try JSON.string(try JSON.get(try JSON.at(try JSON.get(first, "messages"), 0), "content"))
    try Test.assert(system.include?("<name>lint</name>\n    <description>The project's lint.</description>"), system)
    try Test.assert(not system.include?("deploy"), "a skill only the user loads is not listed")
    try Test.eq(enum_of(first), ok(["lint", "release"]))
    loaded = try last_content(h)
    try Test.assert(loaded.start_with?("<skill_content name=\"release\">\n# Release\n\nRun the steps."), loaded)
    try Test.assert(loaded.include?("<file>references/steps.md</file>"), loaded)
    try Test.assert(loaded.include?("Skill directory: #{home}/.agents/skills/release"), loaded)
    try Test.eq(last_content(h), ok("The skill release is already loaded in this session."))
    try Test.eq(last_content(h), ok("Error: unknown skill: deploy"))
    _ = try H.send(h, id, "/deploy /release now")
    a = try H.until(a.with(seen: []), Protocol.EventKind.TurnFinished)
    H.close(a)
    asked = try last_content(h)
    try Test.assert(asked.start_with?("<skill_content name=\"deploy\">\nDeploy steps."), asked)
    try Test.assert(asked.end_with?("</skill_content>\n\n/deploy /release now"), asked)
    try Test.assert(not asked.include?("<skill_content name=\"release\">"), asked)
    shown = (try H.session(h, id)).history.map { |m| m.text }.select { |t| t.include?("deploy") }
    try Test.eq(shown, ["/deploy /release now"])
    H.restarted(h, setup, "") do |r|
      b = try H.subscribe(r, id)
      _ = try H.send(r, id, "/release /deploy again")
      b = try H.until(b, Protocol.EventKind.TurnFinished)
      H.close(b)
      try Test.eq(last_content(r), ok("/release /deploy again"))
      Test.eq((try H.session(r, id)).history.map { |m| m.text }.select { |t| t.include?("deploy") }.size, 2)
    end
  end
end

# A folder is trusted only when it is one of the trusted folders or under one: not by a common prefix of names, and a
# trusted folder may be a link.
def test_project_skills_need_a_trusted_folder() -> Result[Void]
  nothing: List[String] = []
  for trust in [nothing, ["wor"], ["work-link"], ["work-link/../work"]]
    expected = trust == ["work-link"] or trust == ["work-link/../work"]
    try trusted_case(trust, expected)
  end

  ok()
end

def trusted_case(trust: List[String], expected: Bool) -> Result[Void]
  H.using(H.Setup(replies: ["text.sse"], skills: true, trust: some(trust))) do |h|
    try write("#{h.work}/.agents/skills/lint/SKILL.md", LINT_PROJECT)
    try link(h.work, "#{h.base}/work-link")
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Hi.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    first = try JSON.parse((try H.next_request(h)).body)
    system = try JSON.string(try JSON.get(try JSON.at(try JSON.get(first, "messages"), 0), "content"))
    Test.eq("#{trust} #{system.include?("<name>lint</name>")}", "#{trust} #{expected}")
  end
end

def test_discovery_skips_what_it_cannot_use_with_a_warning() -> Result[Void]
  base = try fresh()
  skills = "#{base}/home/.agents/skills"
  try write("#{base}/project/.agents/skills/lint/SKILL.md", LINT_PROJECT)
  try write("#{skills}/empty/SKILL.md", "---\nname: empty\n---\nNo description.\n")
  try write("#{skills}/broken/SKILL.md", "no frontmatter\n")
  try write("#{skills}/other/SKILL.md", "---\nname: renamed\ndescription: d\n---\n")
  try write("#{skills}/caps/SKILL.md", "---\nname: Caps\ndescription: d\n---\n")
  try write("#{skills}/.git/hidden/SKILL.md", RELEASE)
  try write("#{skills}/group/deep/SKILL.md", "---\ndescription: in a group\n---\n")
  try write("#{skills}/a/b/c/d/e/SKILL.md", "---\ndescription: too deep\n---\n")
  try write("#{skills}/big/SKILL.md", "---\ndescription: big\n---\n#{"x" * 1_000_000}")
  try File.append_text("#{skills}/big/SKILL.md", "x" * 100_000)
  try write("#{skills}/long/SKILL.md", "---\ndescription: #{"d" * 2000}\n---\n")
  try write("#{base}/elsewhere/linked/SKILL.md", "---\ndescription: behind a link\n---\n")
  try link("#{base}/elsewhere", "#{skills}/via-link")
  untrusted = Skills.discover("#{base}/project", "#{base}/home", false)
  trusted = Skills.discover("#{base}/project", "#{base}/home", true)
  _ = Path.remove(base)
  try Test.eq(untrusted.skills.map { |s| s.name }, ["deep", "long", "renamed"])
  try Test.eq(trusted.skills.map { |s| s.name }, ["deep", "lint", "long", "renamed"])
  try Test.eq(untrusted.skills[1].description.length, 1024)
  for problem in ["no description", "no frontmatter", "a-z, 0-9", "larger than", "is cut at"]
    try Test.assert(untrusted.warnings.any? { |w| w.include?(problem) }, "#{problem}: #{untrusted.warnings}")
  end

  ok()
end

# A skills root behind a link (`~/.claude -> ~/dot`) is resolved: the skill's folder is its real path, which
# `read_file` reads; only an absolute path reaches a skill's folder.
def test_read_file_reads_in_a_skill_folder_behind_a_link() -> Result[Void]
  base = try fresh()
  try write("#{base}/work/a.txt", "a\n")
  try write("#{base}/dot/skills/release/SKILL.md", RELEASE)
  try write("#{base}/dot/skills/release/references/steps.md", "1. tag\n")
  try link("#{base}/dot", "#{base}/home/.claude")
  skills = Skills.discover("#{base}/work", "#{base}/home", false).skills
  ctx = try Tools.context("#{base}/work", ->(_name: String) { error("unset") }, Tools.Rules(allow: [], deny: []))
  roots = ctx.with(read_roots: skills.map { |s| s.dir })
  read = ->(path: String, c: Tools.Context) { Tools.run(c, "read_file", JSON.object({"path": JSON.from(path)})) }
  steps = "#{skills[0].dir}/references/steps.md"
  results = [
    read.call(steps, ctx).is_error,
    read.call(steps, roots).is_error,
    read.call("#{base}/home/.claude/skills/release/references/steps.md", roots).is_error,
    read.call("../dot/skills/release/references/steps.md", roots).is_error,
  ]

  _ = Path.remove(base)
  try Test.eq(skills[0].dir, "#{base}/dot/skills/release")
  Test.eq(results, [true, false, false, true])
end

# The catalog escapes what it shows; a saved catalog decides which skills the model has after a restart; a fold puts
# back the skills it folded, but one an `activate_skill` call it keeps loads again.
def test_the_catalog_is_escaped_and_restricts_the_model_skills_and_a_fold_keeps_them() -> Result[Void]
  base = try fresh()
  try write("#{base}/home/.agents/skills/release/SKILL.md", RELEASE)
  try write("#{base}/home/.agents/skills/lint/SKILL.md", LINT_HOME)
  try write("#{base}/home/.agents/skills/deploy/SKILL.md", DEPLOY)
  skills = Skills.discover(base, "#{base}/home", false).skills
  catalog = Skills.catalog(skills)
  old = Skills.catalog(skills.select { |s| s.name != "lint" })
  fold = Skills.on_fold(skills)
  call = LLM.ToolCall(
    id: "c",
    name: "activate_skill",
    arguments: "",
    input: JSON.object({"name": JSON.from("release")}),
  )

  kept = [LLM.Message(role: LLM.Role.Assistant, content: [LLM.Block.ToolUse(call)])]
  folded = fold.call(["release", "deploy"], [])
  again = fold.call(["release"], kept)
  _ = Path.remove(base)
  try Test.assert(catalog.include?("The user's &lt;lint&gt; &amp; more."), catalog)
  try Test.eq(Skills.restrict(skills, old).map { |s| s.name }, ["deploy", "release"])
  try Test.assert(folded.include?("<skill_content name=\"release\">"), folded)
  try Test.assert(folded.include?("<skill_content name=\"deploy\">"), folded)
  Test.eq(again, "")
end

# Frontmatter that other clients write: colons in a plain value, quotes, block scalars, nested keys, CRLF.
def test_the_frontmatter_is_read_leniently() -> Result[Void]
  text = (
    "---\r\nname: 'pdf'\r\ndescription: Use this skill when: the user asks about PDFs\r\n" +
    "metadata:\r\n  author: me\r\nlicense: >\r\n  MIT\r\n  or not\r\nnote: \"a \\\"b\\\"\"\r\n---\r\n\r\nBody\r\n"
  )

  front = try Skills.parse(text)
  try Test.eq(front.fields["name"], "pdf")
  try Test.eq(front.fields["description"], "Use this skill when: the user asks about PDFs")
  try Test.eq(front.fields["license"], "MIT or not")
  try Test.eq(front.fields["note"], "a \"b\"")
  try Test.eq(front.fields.has_key?("author"), false)
  try Test.eq(front.body, "Body")
  try Test.error?(Skills.parse("---\nname: x\n"))
  Test.error?(Skills.parse("---\nname x\n---\n"))
end

def last_content(h: H.Harness) -> Result[String]
  messages = try JSON.list(try JSON.get(try JSON.parse((try H.next_request(h)).body), "messages"))
  JSON.string(try JSON.get(messages.last, "content"))
end

def enum_of(request: JSON.Value) -> Result[List[String]]
  for tool in try JSON.list(try JSON.get(request, "tools"))
    function = try JSON.get(tool, "function")
    if JSON.string(try JSON.get(function, "name")) == ok("activate_skill")
      name = try JSON.get(try JSON.get(try JSON.get(function, "parameters"), "properties"), "name")
      return ok((try JSON.list(try JSON.get(name, "enum"))).map { |n| JSON.string(n).unwrap_or("") })
    end
  end

  error("no activate_skill tool")
end

def link(target: String, path: String) -> Result[Void]
  try mkdirs(parent_of(path))
  code = try H.run("ln", ["-s", target, path])
  return error("ln failed") if code != 0

  ok()
end

def write(path: String, text: String) -> Result[Void]
  try mkdirs(parent_of(path))
  File.write_text(path, text)
end

def parent_of(path: String) -> String = path.slice(0, path.length - path.split("/").last.length - 1)

def mkdirs(dir: String) -> Result[Void]
  return ok() if File.stat(dir).ok?

  try mkdirs(parent_of(dir))
  Dir.mkdir(dir)
end

def fresh() -> Result[String]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/finn-skills-#{Random.int(0, 999_999_999)}"
  try Dir.mkdir(dir)
  Path.real(dir)
end
