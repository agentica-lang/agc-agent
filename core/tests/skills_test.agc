# Agent Skills: discovery from the session folder (trusted) and the home folder, the catalog in the system prompt,
# `activate_skill`, `/name` from the user, and the frontmatter as other clients write it.

import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import Compaction from "../src/compaction"
import Skills from "../src/skills"
import Tools from "../src/tools"
import H from "support/harness"

RELEASE = "---\nname: release\ndescription: Cut a release: tag, notes, publish.\n---\n\n# Release\n\nRun the steps.\n"
LINT_HOME = "---\nname: lint\ndescription: The user's lint.\n---\nUser lint.\n"
LINT_PROJECT = "---\nname: lint\ndescription: The project's lint.\n---\nProject lint.\n"
DEPLOY = "---\nname: deploy\ndescription: Deploy it.\ndisable-model-invocation: true\n---\nDeploy steps.\n"

def test_the_model_sees_a_catalog_and_loads_a_skill_and_the_user_names_one() -> Result[Void]
  H.using(H.Setup(replies: ["activate_skill.sse", "text.sse", "text.sse"], skills: true)) do |h|
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
    try Test.assert(
      system.index_of("<name>lint</name>").unwrap! < system.index_of("<name>release</name>").unwrap!,
      system,
    )

    try Test.assert(not system.include?("deploy"), "a skill only the user loads is not listed")
    try Test.eq(enum_of(first), ok(["lint", "release"]))
    second = try JSON.list(try JSON.get(try JSON.parse((try H.next_request(h)).body), "messages"))
    result = try JSON.string(try JSON.get(second.last, "content"))
    try Test.assert(result.start_with?("<skill_content name=\"release\">\n# Release\n\nRun the steps."), result)
    try Test.assert(result.include?("<file>references/steps.md</file>"), result)
    try Test.assert(result.include?("Skill directory: #{home}/.agents/skills/release"), result)
    _ = try H.send(h, id, "/deploy now")
    a = try H.until(a.with(seen: []), Protocol.EventKind.TurnFinished)
    H.close(a)
    third = try JSON.list(try JSON.get(try JSON.parse((try H.next_request(h)).body), "messages"))
    asked = try JSON.string(try JSON.get(third.last, "content"))
    try Test.assert(asked.start_with?("<skill_content name=\"deploy\">\nDeploy steps."), asked)
    try Test.assert(asked.end_with?("</skill_content>\n\n/deploy now"), asked)
    session = try H.session(h, id)
    Test.eq(session.history.map { |m| m.text }.select { |t| t.include?("deploy") }, ["/deploy now"])
  end
end

def test_project_skills_need_a_trusted_folder_and_bad_ones_are_skipped_with_a_warning() -> Result[Void]
  base = try fresh()
  try write("#{base}/project/.agents/skills/lint/SKILL.md", LINT_PROJECT)
  try write("#{base}/home/.agents/skills/empty/SKILL.md", "---\nname: empty\n---\nNo description.\n")
  try write("#{base}/home/.agents/skills/broken/SKILL.md", "no frontmatter\n")
  try write("#{base}/home/.agents/skills/other/SKILL.md", "---\nname: renamed\ndescription: d\n---\n")
  try write("#{base}/home/.agents/skills/.git/hidden/SKILL.md", RELEASE)
  try write("#{base}/home/.agents/skills/group/deep/SKILL.md", "---\ndescription: in a group\n---\n")
  untrusted = Skills.discover("#{base}/project", "#{base}/home", false)
  trusted = Skills.discover("#{base}/project", "#{base}/home", true)
  _ = Path.remove(base)
  try Test.eq(untrusted.skills.map { |s| s.name }, ["deep", "renamed"])
  try Test.eq(trusted.skills.map { |s| s.name }, ["deep", "lint", "renamed"])
  try Test.eq(untrusted.warnings.size, 3)
  Test.assert(untrusted.warnings.any? { |w| w.include?("no description") }, "#{untrusted.warnings}")
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

# What `expand` writes before a message, `typed` takes off again, and `loaded` names.
def test_a_message_with_skills_reads_back_as_typed() -> Result[Void]
  base = try fresh()
  try write("#{base}/home/.agents/skills/release/SKILL.md", RELEASE)
  skills = Skills.discover(base, "#{base}/home", false).skills
  text = Skills.expand("Do /release\nnow", skills, [])
  _ = Path.remove(base)
  try Test.eq(Skills.typed(text), "Do /release\nnow")
  try Test.eq(Skills.loaded([text]), ["release"])
  Test.eq(Skills.expand("Do /release", skills, ["release"]), "Do /release")
end

def test_compaction_keeps_the_skills_of_the_folded_span() -> Result[Void]
  block = "<skill_content name=\"release\">\nSteps.\n</skill_content>"
  history = [
    message(LLM.Role.User, "first task"),
    message(LLM.Role.Assistant, "ok"),
    message(LLM.Role.User, "#{block}\n\n/release"),
    message(LLM.Role.Assistant, "done"),
    message(LLM.Role.User, "next"),
  ]

  compacted = Compaction.apply(history, Compaction.Compaction(from: 1, to: 4, summary: "It was released."))
  summary = summary_of(compacted[1])
  try Test.assert(summary.end_with?("The skills loaded in this session:\n\n#{block}"), summary)
  Test.eq(compacted.size, 3)
end

# A skill's folder is readable by `read_file` though it is outside the session folder.
def test_read_file_reads_in_a_skill_folder() -> Result[Void]
  base = try fresh()
  try write("#{base}/work/a.txt", "a\n")
  try write("#{base}/skill/references/steps.md", "1. tag\n")
  ctx = try Tools.context("#{base}/work", ->(_name: String) { error("unset") }, Tools.Rules(allow: [], deny: []))
  input = JSON.object({"path": JSON.from("#{base}/skill/references/steps.md")})
  refused = Tools.run(ctx, "read_file", input)
  allowed = Tools.run(ctx.with(read_roots: ["#{base}/skill"]), "read_file", input)
  _ = Path.remove(base)
  try Test.eq(refused.is_error, true)
  Test.eq([allowed.is_error, allowed.text.include?("1. tag")], [false, true])
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

def message(role: LLM.Role, text: String) -> LLM.Message
  LLM.Message(role: role, content: [LLM.Block.Text(LLM.TextPart(text: text))])
end

def summary_of(m: LLM.Message) -> String = m.content.map { |b| text_part(b) }.join("")

def text_part(block: LLM.Block) -> String
  case block
    LLM.Block.Text(part) -> part.text
    _ -> ""
  end
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
