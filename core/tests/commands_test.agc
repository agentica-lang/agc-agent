import Protocol from "pkg/protocol/protocol"
import Commands from "../src/ext/commands"
import H from "support/harness"

# `$ARGUMENTS` takes the text after the name; without it the text goes after the prompt; another name stays as typed.
def test_a_command_puts_its_prompt_in_place_of_its_name() -> Result[Void]
  with_args = try Commands.parse("r.md", "r", "---\ndescription: Review\n---\nReview $ARGUMENTS with care.\n", "user")
  plain = try Commands.parse("p.md", "p", "Plan the work.\n", "user")
  loaded = Commands.Loaded(commands: [with_args, plain])
  rows = [
    Commands.expanded(loaded, "/r src/a.agc"),
    Commands.expanded(loaded, "/p"),
    Commands.expanded(loaded, "/p first\nthen more"),
    Commands.expanded(loaded, "/other x"),
    Commands.expanded(loaded, "say /p"),
  ]

  try Test.eq(with_args.description, "Review")
  Test.eq(
    rows,
    ["Review src/a.agc with care.", "Plan the work.", "Plan the work.\n\nfirst\nthen more", "/other x", "say /p"],
  )
end

# Files that are not commands are skipped with a warning, a client command's name is not taken, a broken file or one
# over 64 KiB fails only its own name, a project command wins with a warning, and an untrusted project counts not.
def test_the_commands_of_the_folders() -> Result[Void]
  base = try fresh()
  user = "#{base}/user"
  try write("#{user}/README.md", "notes\n")
  try write("#{user}/model.md", "Pick a model.\n")
  try write("#{user}/bad.md", "---\ncolour: red\n---\nx\n")
  try write("#{user}/huge.md", "x" * 65_537)
  try write("#{user}/review.md", "Review it.\n")
  try write("#{base}/.finn/commands/review.md", "Review the project.\n")
  trusted = Commands.load(user, base, true)
  try Test.eq(trusted.commands.map { |c| "#{c.name}:#{c.source}" }, ["review:project"])
  try Test.eq(trusted.broken.keys.sort, ["bad", "huge"])
  try Test.eq(trusted.warnings.select { |w| w.name.empty? }.size, 2)
  try Test.assert(Commands.warnings_of(trusted, "review").join(" ").include?("replaces the user command"), "")
  Test.eq(Commands.load(user, base, false).commands.map { |c| c.source }, ["user"])
end

# The model gets the command's prompt and the history what was typed; a command wins over a skill of its name, and the
# listing says so.
def test_a_session_runs_a_command() -> Result[Void]
  setup = H.Setup(replies: ["text.sse"], profiles: true, skills: true)
  H.using(setup) do |h|
    try write("#{h.base}/config/finn/commands/review.md", "---\ndescription: Review\n---\nReview $ARGUMENTS.\n")
    try write("#{h.work}/.finn/skills/review/SKILL.md", "---\nname: review\ndescription: Skill.\n---\nSkill steps.\n")
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "/review src/a.agc")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    first = try H.request_messages(h, 1)
    try Test.eq(JSON.get(first.last, "content"), ok(JSON.from("Review src/a.agc.")))
    try Test.eq((try H.session(h, id)).history[0].text, "/review src/a.agc")
    listed = try Protocol.decode_command_list((try H.get(h, Protocol.commands_path(id))).text)
    try Test.eq(listed.commands.map { |c| "#{c.name}:#{c.source}:#{c.description}" }, ["review:user:Review"])
    Test.assert(
      listed.commands[0].warnings.join(" ").include?("the command wins"),
      listed.commands[0].warnings.join(" "),
    )
  end
end

def fresh() -> Result[String]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/finn-commands-#{Random.int(0, 999_999_999)}"
  try Dir.mkdir(dir)
  Path.real(dir)
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
