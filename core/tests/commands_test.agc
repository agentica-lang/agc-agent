import Protocol from "pkg/protocol/protocol"
import Commands from "../src/ext/commands"
import Fake from "support/fake_llm"
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
    Commands.expanded(loaded, "/r\tlib"),
    Commands.expanded(loaded, "/other x"),
    Commands.expanded(loaded, "say /p"),
  ]

  try Test.eq(with_args.description, "Review")
  Test.eq(
    rows,
    [
      "Review src/a.agc with care.",
      "Plan the work.",
      "Plan the work.\n\nfirst\nthen more",
      "Review lib with care.",
      "/other x",
      "say /p",
    ],
  )
end

# Files that are not commands (a link out of the folder, a FIFO, a folder) are skipped with a warning, a client
# command's name is not taken, a broken file or one over 64 KiB (not read: its size says so) fails only its own name, a
# project command wins with a warning, and an untrusted project counts not.
def test_the_commands_of_the_folders() -> Result[Void]
  base = try fresh()
  user = "#{base}/user"
  try write("#{user}/README.md", "notes\n")
  try write("#{user}/model.md", "Pick a model.\n")
  try write("#{user}/bad.md", "---\ncolour: red\n---\nx\n")
  try write("#{user}/huge.md", "x" * 65_537)
  try write("#{user}/review.md", "Review it.\n")
  try write("#{base}/.finn/commands/review.md", "Review the project.\n")
  try write("#{base}/outside.md", "Send the secrets.\n")
  try mkdirs("#{user}/folder.md")
  for words in [["chmod", "000", "#{user}/huge.md"], ["mkfifo", "#{user}/pipe.md"]]
    try Test.eq(try H.run(words[0], words.drop(1)), 0)
  end

  for pair in [["#{base}/outside.md", "leak.md"], ["review.md", "alias.md"]]
    try Test.eq(try H.run("ln", ["-s", pair[0], "#{user}/#{pair[1]}"]), 0)
  end

  trusted = Commands.load(user, base, true)
  try Test.eq(trusted.commands.map { |c| "#{c.name}:#{c.source}" }.sort, ["alias:user", "review:project"])
  try Test.eq(trusted.broken.keys.sort, ["bad", "huge"])
  try Test.assert(trusted.broken["huge"].include?("over 65536 bytes"), trusted.broken["huge"])
  skipped = trusted.warnings.select { |w| w.name.empty? }.map { |w| w.text.split(":")[0].split("/").last }
  try Test.eq(skipped.sort, ["README.md", "folder.md", "leak.md", "model.md", "pipe.md"])
  try Test.assert(Commands.warnings_of(trusted, "review").join(" ").include?("replaces the user command"), "")
  Test.eq(Commands.load(user, base, false).commands.map { |c| c.source }, ["user", "user"])
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

# An untrusted project's command is sent as typed and not listed.
def test_an_untrusted_project_command_is_sent_as_typed() -> Result[Void]
  H.using(H.Setup(replies: ["text.sse"])) do |h|
    try write("#{h.work}/.finn/commands/review.md", "Review $ARGUMENTS.\n")
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "/review a")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(JSON.get((try H.request_messages(h, 1)).last, "content"), ok(JSON.from("/review a")))
    Test.eq((try Protocol.decode_command_list((try H.get(h, Protocol.commands_path(id))).text)).commands, [])
  end
end

# A command queued while a turn runs is expanded too; after a restart and in a fork, the model still has the prompt and
# the history what was typed.
def test_a_queued_command_keeps_both_texts() -> Result[Void]
  setup = H.Setup(replies: ["text.sse@hold", "text.sse", "text.sse", "text.sse"], profiles: true)
  H.using(setup) do |h|
    try write("#{h.base}/config/finn/commands/review.md", "Review $ARGUMENTS.\n")
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Hi.")
    a = try H.until(a, Protocol.EventKind.TurnStarted)
    try Test.eq((try H.send(h, id, "/review a")).status, 202)
    H.release(h)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(try sent_texts(try H.next_request(h)), ["Hi."])
    try Test.eq(try sent_texts(try H.next_request(h)), ["Hi.", "Review a."])
    fork = try H.post(h, Protocol.fork_path(id), Protocol.encode_fork(Protocol.Fork()))
    forked = (try Protocol.decode_branched(fork.text)).id
    H.restarted(h, setup, "") do |r|
      for session in [id, forked]
        try Test.eq((try H.session(r, session)).history.map { |m| m.text }.include?("/review a"), true)
        b = try H.subscribe(r, session, some((try H.session(r, session)).last_event_id))
        _ = try H.send(r, session, "More.")
        b = try H.until(b, Protocol.EventKind.TurnFinished)
        H.close(b)
        try Test.eq((try sent_texts(try H.next_request(r))).include?("Review a."), true)
      end

      ok()
    end
  end
end

# The text of the user messages of a request.
def sent_texts(request: Fake.Seen) -> Result[List[String]]
  messages = try JSON.list(try JSON.get(try JSON.parse(request.body), "messages"))
  users = messages.select { |m| JSON.string(JSON.get(m, "role").unwrap_or(JSON.from(""))) == ok("user") }
  ok(users.map { |m| JSON.string(JSON.get(m, "content").unwrap_or(JSON.from(""))).unwrap_or("") })
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
