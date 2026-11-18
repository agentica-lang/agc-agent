# Agent Skills: discovery from the session folder (trusted) and the home folder, the catalog in the system prompt,
# `activate_skill`, `/name` from the user, the marks a session keeps, and the frontmatter as other clients write it.

import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import Core from "../core"
import Skills from "../src/ext/skills"
import Tools from "../src/tools/tools"
import H from "support/harness"

RELEASE = "---\nname: release\ndescription: Cut a release: tag, notes, publish.\n---\n\n# Release\n\nRun the steps.\n"
LINT_HOME = "---\nname: lint\ndescription: The user's <lint> & more.\n---\nUser lint.\n"
LINT_PROJECT = "---\nname: lint\ndescription: The project's lint.\n---\nProject lint.\n"
HEADING = "\n\nThe skills loaded in this session:\n\n"
DEPLOY = "---\nname: deploy\ndescription: Deploy it.\ndisable-model-invocation: true\n---\nDeploy steps.\n"
EXTENSIONS_PAGE = (
  "---\ntitle: Extensions\ndescription: Extend Finn with a program of your own.\n---\n\n# Extensions\n\n" +
  "Serve the core with your tools.\n"
)
TOOLS_PAGE = "---\ntitle: Tools\ndescription: What the model can call.\n---\n\n# Tools\n"
OWN_FINN = "---\nname: finn\ndescription: My own notes on Finn.\n---\nMine.\n"

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

# Finn's own pages are the resources of the built-in skill `finn`: a task about extending Finn makes the model load
# it and read the page, in place; its index has a line a page, without the home page.
def test_the_model_reads_the_docs_of_finn_through_the_built_in_skill() -> Result[Void]
  replies = ["activate_finn.sse", "read_docs_page.sse", "read_docs_link.sse", "text.sse"]
  H.using(H.Setup(replies: replies, docs: true)) do |h|
    docs = "#{h.base}/docs"
    try write("#{docs}/extensions.md", EXTENSIONS_PAGE)
    try write("#{docs}/tools.md", TOOLS_PAGE)
    try write("#{h.base}/outside.md", "outside the docs\n")
    try link("#{h.base}/outside.md", "#{docs}/secret.md")
    try write("#{docs}/_index.md", "---\ntitle: Finn\ndescription: The home page.\n---\n")
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write an extension that adds a tool.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    first = try JSON.parse((try H.next_request(h)).body)
    system = try JSON.string(try JSON.get(try JSON.at(try JSON.get(first, "messages"), 0), "content"))
    try Test.assert(system.include?("<name>finn</name>"), system)
    try Test.eq(enum_of(first), ok(["finn"]))
    loaded = try last_content(h)
    try Test.assert(loaded.start_with?("<skill_content name=\"finn\">\n"), loaded)
    try Test.assert(
      loaded.include?(
        "- extensions.md: Extend Finn with a program of your own.\n- tools.md: What the model can call.",
      ),
      loaded,
    )

    try Test.assert(not loaded.include?("_index") and not loaded.include?("secret"), loaded)
    try Test.assert(loaded.include?("Skill directory: #{docs}"), loaded)
    try Test.eq(last_content(h), ok(EXTENSIONS_PAGE))
    refused = try last_content(h)
    Test.assert(refused.start_with?("Error:") and not refused.include?("outside the docs"), refused)
  end
end

# A skill of the user or the project named `finn` hides the built-in one; without a folder of pages there is none.
def test_a_skill_of_the_same_name_hides_the_built_in_one() -> Result[Void]
  base = try fresh()
  try write("#{base}/docs/extensions.md", EXTENSIONS_PAGE)
  try write("#{base}/home/.agents/skills/finn/SKILL.md", OWN_FINN)
  mine = Skills.discover("#{base}/work", "#{base}/home", false, "#{base}/docs").skills
  try Test.eq(mine.map { |skill| skill.description }, ["My own notes on Finn."])
  built_in = Skills.discover("#{base}/work", "#{base}/nohome", false, "#{base}/docs").skills
  try Test.eq(built_in.map { |skill| skill.name }, ["finn"])
  Test.eq(Skills.discover("#{base}/work", "#{base}/nohome", false, "#{base}/nodocs").skills.size, 0)
end

# A `Message` handler of an extension gets the message after the skills it names are expanded.
def test_a_message_handler_gets_the_skills_a_message_names() -> Result[Void]
  mark = ->(text: String) { "#{text} [#{text.start_with?("<skill_content name=\"release\">")}]" }
  registry = Core.registry() |> Core.on(Core.Event.Message(mark))
  H.using(H.Setup(replies: ["text.sse"], skills: true, registry: some(registry))) do |h|
    try write("#{h.base}/home/.agents/skills/release/SKILL.md", RELEASE)
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "/release now")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    asked = try last_content(h)
    Test.assert(asked.end_with?("</skill_content>\n\n/release now [true]"), asked)
  end
end

# A message queued into a turn loads the skills it names before the turn reads it, before a tool round or a final
# answer, and the session keeps them loaded.
def test_a_queued_message_loads_its_skills() -> Result[Void]
  replies = ["write_file.sse", "write_file.sse", "text.sse", "text.sse"]
  H.using(H.Setup(replies: replies, skills: true)) do |h|
    try write("#{h.base}/home/.agents/skills/release/SKILL.md", RELEASE)
    try write("#{h.base}/home/.claude/skills/lint/SKILL.md", LINT_HOME)
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    _ = try H.send(h, id, "/release also")
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    a = try H.until(a.with(seen: []), Protocol.EventKind.ApprovalRequested)
    _ = try H.send(h, id, "/lint too")
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    _ = try H.send(h, id, "/release /lint again")
    a = try H.until(a.with(seen: []), Protocol.EventKind.TurnFinished)
    H.close(a)
    _ = try H.next_request(h)
    release = try last_content(h)
    try Test.assert(release.start_with?("<skill_content name=\"release\">"), release)
    try Test.assert(release.end_with?("</skill_content>\n\n/release also"), release)
    lint = try last_content(h)
    try Test.assert(lint.start_with?("<skill_content name=\"lint\">\nUser lint."), lint)
    try Test.eq(last_content(h), ok("/release /lint again"))
    shown = (try H.session(h, id)).history.map { |m| m.text }.select { |t| t.start_with?("/") }
    Test.eq(shown, ["/release also", "/lint too", "/release /lint again"])
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
  try write("#{skills}/n64/SKILL.md", "---\nname: #{"a" * 64}\ndescription: d\n---\n")
  try write("#{skills}/n65/SKILL.md", "---\nname: #{"b" * 65}\ndescription: d\n---\n")
  try write("#{base}/elsewhere/linked/SKILL.md", "---\ndescription: behind a link\n---\n")
  try link("#{base}/elsewhere", "#{skills}/via-link")
  untrusted = Skills.discover("#{base}/project", "#{base}/home", false)
  trusted = Skills.discover("#{base}/project", "#{base}/home", true)
  _ = Path.remove(base)
  try Test.eq(untrusted.skills.map { |s| s.name }, ["a" * 64, "deep", "long", "renamed"])
  try Test.eq(trusted.skills.map { |s| s.name }, ["a" * 64, "deep", "lint", "long", "renamed"])
  try Test.eq(untrusted.skills[2].description.length, 1024)
  for problem in ["no description", "no frontmatter", "a-z, 0-9", "larger than", "is cut at"]
    try Test.assert(untrusted.warnings.any? { |w| w.include?(problem) }, "#{problem}: #{untrusted.warnings}")
  end

  ok()
end

# At most 100 skills are used, the first by name; a warning says how many there were.
def test_discovery_keeps_at_most_100_skills() -> Result[Void]
  base = try fresh()
  for i in 0...101
    name = "s#{(1000 + i).to_s}"
    try write("#{base}/home/.agents/skills/#{name}/SKILL.md", "---\ndescription: d\n---\n")
  end

  found = Skills.discover(base, "#{base}/home", false)
  _ = Path.remove(base)
  try Test.eq([found.skills.size.to_s, found.skills.last.name], ["100", "s1099"])
  Test.assert(found.warnings.any? { |w| w.include?("101 skills") }, "#{found.warnings}")
end

# The built-in skill takes the room that the user's and the project's skills leave: with 100 of them it is not added,
# and with 99 it is.
def test_the_built_in_skill_never_takes_the_place_of_another() -> Result[Void]
  base = try fresh()
  try write("#{base}/docs/extensions.md", EXTENSIONS_PAGE)
  for i in 0...100
    name = "s#{(1000 + i).to_s}"
    try write("#{base}/home/.agents/skills/#{name}/SKILL.md", "---\ndescription: d\n---\n")
  end

  full = Skills.discover(base, "#{base}/home", false, "#{base}/docs")
  try Test.eq([full.skills.size.to_s, full.skills.any? { |skill| skill.name == "finn" }.to_s], ["100", "false"])
  try Test.eq(full.warnings, [])
  _ = Path.remove("#{base}/home/.agents/skills/s1099")
  room = Skills.discover(base, "#{base}/home", false, "#{base}/docs")
  _ = Path.remove(base)
  try Test.eq([room.skills.size.to_s, room.skills.any? { |skill| skill.name == "finn" }.to_s], ["100", "true"])
  Test.eq(room.skills.map { |skill| skill.name }, room.skills.map { |skill| skill.name }.sort)
end

# Only regular files of the folder are pages: a link (that could lead out of it) is neither listed nor read, and a
# folder with no page gives no skill.
def test_the_built_in_skill_lists_only_regular_pages() -> Result[Void]
  base = try fresh()
  try write("#{base}/outside.md", "secret\n")
  try write("#{base}/docs/extensions.md", EXTENSIONS_PAGE)
  try link("#{base}/outside.md", "#{base}/docs/secret.md")
  skills = Skills.discover("#{base}/work", "", false, "#{base}/docs").skills
  loaded = Skills.on_message("/finn", skills, []).text
  try Test.assert(loaded.include?("- extensions.md:"), loaded)
  try Test.assert(not loaded.include?("secret"), loaded)
  try write("#{base}/only/_index.md", "---\ndescription: Home.\n---\n")
  try link("#{base}/outside.md", "#{base}/only/secret.md")
  Test.eq(Skills.discover("#{base}/work", "", false, "#{base}/only").skills.size, 0)
end

# A session reads a loaded skill's files by their absolute path, not a relative one; a `/name` marks the skill at once,
# so the model's `activate_skill` of it in that turn is a note. After a restart the session keeps the catalog it had:
# a skill added since is not offered to the model.
def test_the_server_wires_skills_into_a_session() -> Result[Void]
  replies = ["activate_skill.sse", "read_skill_file.sse", "read_relative.sse", "text.sse", "text.sse"]
  setup = H.Setup(replies: replies, skills: true)
  H.using(setup) do |h|
    home = "#{h.base}/home"
    try write("#{home}/.agents/skills/release/SKILL.md", RELEASE)
    try write("#{home}/.agents/skills/release/references/steps.md", "1. tag\n")
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "/release go")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    _ = try H.next_request(h)
    try Test.eq(last_content(h), ok("The skill release is already loaded in this session."))
    try Test.eq(last_content(h), ok("1. tag\n"))
    try Test.assert((try last_content(h)).start_with?("Error:"), "a relative path is read in the session folder")
    try write("#{home}/.agents/skills/notes/SKILL.md", "---\ndescription: Take notes.\n---\nNotes.\n")
    H.restarted(h, setup, "") do |r|
      b = try H.subscribe(r, id)
      _ = try H.send(r, id, "Hi.")
      b = try H.until(b, Protocol.EventKind.TurnFinished)
      H.close(b)
      Test.eq(enum_of(try JSON.parse((try H.next_request(r)).body)), ok(["release"]))
    end
  end
end

# A fold of a round that loaded a skill puts its content after the summary, then the text of the `Fold` handlers of
# the extensions, which get the texts that stay.
def test_a_fold_puts_back_the_skill_it_folded() -> Result[Void]
  replies = ["activate_skill.sse", "bash_echo.sse", "summary.sse", "text.sse"]
  registry = Core.registry() |> Core.on(Core.Event.Fold(->(staying: List[String]) { "kept: #{staying.join("|")}" }))
  H.using(H.Setup(replies: replies, context_window: 120, skills: true, registry: some(registry))) do |h|
    try write("#{h.base}/home/.agents/skills/release/SKILL.md", RELEASE)
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Release it, then echo.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    _ = try H.approve(h, id, (try H.approval(a)).approval_id, Protocol.Decision.Allow)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    for _i in 1..3
      _ = try H.next_request(h)
    end

    after = try JSON.list(try JSON.get(try JSON.parse((try H.next_request(h)).body), "messages"))
    summary = try JSON.string(try JSON.get(after[2], "content"))
    try Test.assert(summary.start_with?("Summary of the session so far:"), summary)
    try Test.assert(
      summary.include?("The skills loaded in this session:\n\n<skill_content name=\"release\">"),
      summary,
    )

    Test.assert(summary.include?("</skill_content>\n\nkept: "), summary)
  end
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
  ctx = try Tools.context("#{base}/work", ->(_name: String) { error("unset") })
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
# back the skills it folded, but those a kept message loads: not a note that it was loaded, nor a file that quotes it.
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

  use = LLM.Message(role: LLM.Role.Assistant, content: [LLM.Block.ToolUse(call)])
  noted = LLM.Message(role: LLM.Role.User, content: [result("The skill release is already loaded in this session.")])
  folded = fold.call(["release", "deploy"], [])
  only_noted = fold.call(["release"], [use, noted])
  blocks = folded.slice(HEADING.length, folded.length - HEADING.length)
  loaded = LLM.Message(role: LLM.Role.User, content: [result(blocks)])
  again = fold.call(["release"], [use, loaded])
  first = LLM.Message(role: LLM.Role.User, content: [LLM.Block.Text(LLM.TextPart(text: "#{blocks}\n\n/release go"))])
  in_first = fold.call(["release", "deploy"], [first])
  read = LLM.ToolCall(id: "r", name: "read_file", arguments: "", input: JSON.object({"path": JSON.from("notes.md")}))
  quoting = [
    LLM.Message(role: LLM.Role.Assistant, content: [LLM.Block.ToolUse(read)]),
    LLM.Message(
      role: LLM.Role.User,
      content: [LLM.Block.ToolResult(LLM.ToolOutput(tool_use_id: "r", content: blocks))],
    ),
  ]

  quoted = fold.call(["release"], quoting)
  _ = Path.remove(base)
  try Test.assert(folded.start_with?(HEADING), folded)
  try Test.assert(only_noted.include?("<skill_content name=\"release\">"), "a note is not the content: #{only_noted}")
  try Test.assert(quoted.include?("<skill_content name=\"release\">"), "a quote of the marker is not the content")
  try Test.eq(in_first, "")
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

def result(text: String) -> LLM.Block = LLM.Block.ToolResult(LLM.ToolOutput(tool_use_id: "c", content: text))

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
