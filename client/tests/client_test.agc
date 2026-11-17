import Protocol from "pkg/protocol/protocol"
import Client from "../client"
import Http from "../src/http"

# A port nothing listens on: the one of a server that was just closed.
CLOSED = Client.Server(url: "http://127.0.0.1:9", token: "t")

def test_the_state_folder_option_wins_and_is_resolved() -> Result[Void]
  launch = Client.Launch(main: "cli/main.agc", state_dir: some("/tmp/../tmp/finn-test-none"))
  Test.eq(Client.state_dir(launch), ok("/tmp/finn-test-none"))
end

# An event stream is quiet while the model thinks: its limits are a day, not the 30 s of a call.
def test_an_event_stream_is_never_cut_by_a_timeout() -> Result[Void]
  options = Http.events_options()
  try Test.assert(options.timeout_ms >= 3_600_000, "timeout #{options.timeout_ms}")
  Test.assert(options.idle_timeout_ms >= 3_600_000, "idle #{options.idle_timeout_ms}")
end

def test_a_server_that_does_not_listen_is_unreachable() -> Result[Void]
  case Client.health(CLOSED)
    ok(_) -> error("a closed port answered")
    error(e) -> Test.eq(e.kind, Client.KIND_UNREACHABLE)
  end
end

def test_a_stream_that_cannot_open_ends_with_its_reason() -> Result[Void]
  items: Channel[Client.Item] = Channel.new(4)
  feed = Client.Feed(server: CLOSED, session_id: "s1", last_event_id: 0, tell: ->(item) { items.send(item, 1000) })
  Task.await(Client.start(feed))
  item = try items.recv(1000)
  case item
    Client.Item.Ended(reason) -> Test.assert(reason.include?("cannot reach the server"), reason)
    _ -> error("not an end: #{item}")
  end
end

def test_commands_parse_with_their_arguments() -> Result[Void]
  try Test.eq(Client.parse_command("hello /new"), none)
  try Test.eq(Client.parse_command("  /new "), some(ok(Client.Command.New)))
  try Test.eq(Client.parse_command("/resume"), some(ok(Client.Command.Resume(none))))
  try Test.eq(Client.parse_command("/export"), some(ok(Client.Command.Export(none, false))))
  try Test.eq(Client.parse_command("/export --force a b.md"), some(ok(Client.Command.Export(some("a b.md"), true))))
  try Test.eq(Client.parse_command("/resume 2"), some(ok(Client.Command.Resume(some("2")))))
  try Test.eq(Client.parse_command("/model qwen3:8b"), some(ok(Client.Command.Model(some("qwen3:8b")))))
  try Test.eq(Client.parse_command("/thinking high"), some(ok(Client.Command.Thinking(some("high")))))
  try Test.eq(Client.parse_command("/thinking default"), some(ok(Client.Command.Thinking(some("default")))))
  try Test.eq(Client.parse_command("/tree 2+"), some(ok(Client.Command.Tree(some("2+")))))
  try Test.eq(Client.parse_command("/fork"), some(ok(Client.Command.Fork(none))))
  try Test.eq(Client.parse_command("/clone"), some(ok(Client.Command.Clone)))
  try Test.eq(Client.parse_command("/login"), some(ok(Client.Command.Login(none))))
  try Test.eq(Client.parse_command("/login groq"), some(ok(Client.Command.Login(some("groq")))))
  try Test.eq(Client.parse_command("/logout"), some(ok(Client.Command.Logout(none))))
  for text in ["/review-pr 12", "/etc/hosts has a bad entry", "/"]
    try Test.eq(Client.parse_command(text), none)
  end

  for bad in ["/thinking max", "/new now", "/model qwen3 8b", "/clone 2", "/login groq sk-1"]
    parsed = Client.parse_command(bad)
    case parsed
      some(error(e)) -> try Test.eq(e.kind, Client.KIND_COMMAND)
      _ -> return error("#{bad} gave #{parsed}")
    end
  end

  # Every command of the table parses, and the help lists those the suggestions list.
  for usage in Client.COMMANDS
    try Test.assert(Client.parse_command(usage.name).some?, usage.name)
  end

  help = Client.help()
  try Test.eq(help[0], "/new                       a new session in this folder")
  Test.assert(Client.listed().all? { |usage| help.any? { |line| line.start_with?("#{usage.name} ") } }, "#{help}")
end

def test_a_bang_line_is_a_shell_command() -> Result[Void]
  try Test.eq(Client.parse_shell(" !git status "), some(Protocol.RunShell(command: "git status", context: true)))
  try Test.eq(Client.parse_shell("!! ls -a"), some(Protocol.RunShell(command: "ls -a", context: false)))
  for text in ["!", "!! ", "hi !ls"]
    try Test.eq(Client.parse_shell(text), none)
  end

  ok()
end

def test_resume_picks_by_number_or_id() -> Result[Void]
  sessions = ["a1", "b2"].map { |id| Protocol.SessionSummary(id: id, cwd: "/w", model: "m", api: "openai") }
  list = Protocol.SessionList(sessions: sessions)
  try Test.eq(Client.listing(list), ["1. a1  m  /w", "2. b2  m  /w"])
  try Test.eq(Client.pick(list, "2"), ok("b2"))
  try Test.eq(Client.pick(list, "a1"), ok("a1"))
  Test.error?(Client.pick(list, "3"))
end

# A branch puts its messages a step in with a guide; a single next message stays under the one before. The numbers name
# a message (before it) or, with `+`, its answer (after it).
def test_the_tree_is_listed_depth_first_and_picked_by_number() -> Result[Void]
  nodes = [
    Protocol.TreeNode(id: 1, text: "One.", answer: "A1", last: 7, active: true),
    Protocol.TreeNode(id: 8, parent: some(1), text: "Two.", answer: "A2", last: 14),
    Protocol.TreeNode(id: 9, parent: some(8), text: "Two more.\nsecond line", last: 20),
    Protocol.TreeNode(id: 21, parent: some(1), text: "Three.", answer: "A3", last: 27, active: true),
  ]

  tree = Protocol.SessionTree(nodes: nodes)
  listed = ["1. * One.  -> A1", "2. ├   Two.  -> A2", "3.     Two more.  -> ", "4. └ * Three.  -> A3"]

  try Test.eq(Client.tree_listing(tree), listed)
  try Test.eq([Client.tree_entry(tree, "4"), Client.tree_entry(tree, "2+")], [ok(21), ok(14)])
  try Test.error?(Client.tree_entry(tree, "5"))
  Test.error?(Client.tree_entry(tree, "x+"))
end

# What a client echoes of another's text stays on one line, with no terminal escapes or bidi controls.
def test_printable_turns_control_characters_into_spaces() -> Result[Void]
  try Test.eq(Client.printable("a#{String.from_code(27)}[2Jb\nc\td"), "a [2Jb c d")
  bidi = [0x202E, 0x2067, 0x200F, 0x061C].map { |code| String.from_code(code) }.join("")
  Test.eq(Client.printable("main#{bidi}live#{String.from_code(0x85)}"), "main    live ")
end

# `/model provider/model` moves to a provider of the list, unless the session's provider lists that name; any other
# text (a name with a `/`) is the model alone.
def test_model_change_splits_a_known_provider() -> Result[Void]
  list = Protocol.ProviderList(
    provider: "local",
    providers: [
      Protocol.ProviderInfo(name: "fw", api: "openai", models: []),
      Protocol.ProviderInfo(name: "or", api: "openai", models: ["fw/m"]),
    ],
  )

  try Test.eq(
    Client.model_change(list, "local", "fw/m"),
    Protocol.UpdateSession(provider: some("fw"), model: some("m")),
  )

  try Test.eq(Client.model_change(list, "or", "fw/m"), Protocol.UpdateSession(model: some("fw/m")))
  try Test.eq(
    Client.model_change(list, "or", "or/fw/m"),
    Protocol.UpdateSession(provider: some("or"), model: some("fw/m")),
  )

  try Test.eq(Client.model_change(list, "local", "org/m"), Protocol.UpdateSession(model: some("org/m")))
  try Test.eq(Client.model_change(list, "local", "fw/"), Protocol.UpdateSession(model: some("fw/")))
  Test.eq(Client.model_change(list, "local", "m"), Protocol.UpdateSession(model: some("m")))
end

# A replay starts at the running turn unless the server lost that start; a new session without a folder takes the
# client's; a compaction says whether it folded anything.
def test_the_session_rules_both_clients_share() -> Result[Void]
  idle = Protocol.Session(
    id: "s1",
    cwd: "/w",
    model: "m",
    last_event_id: 9,
    turn_id: none,
    turn_from_event_id: none,
    pending_approvals: [],
    history: [],
  )

  running = idle.with(turn_id: some("t1"), turn_from_event_id: some(4))
  try Test.eq(
    [Client.replay_from(idle, false), Client.replay_from(running, false), Client.replay_from(running, true)],
    [9, 4, 9],
  )

  try Test.eq((try Client.new_session(none, some("m"), none, none)).cwd, try Path.cwd())
  try Test.eq((try Client.new_session(some("/w"), none, none, none)).cwd, "/w")
  try Test.eq([Client.compacted(true), Client.compacted(false)], ["compacted", "nothing to compact yet"])

  Test.eq(Client.thinking(running.with(effort: some("high"))), "thinking high")
end

# The backend of a test fails every call it does not replace, as an unreachable server, and its stream ends at once.
def test_an_unreachable_backend_fails_and_ends() -> Result[Void]
  backend = Client.unreachable_backend()
  try Test.eq(error_kind_of(backend.session.call("s1")), Client.KIND_UNREACHABLE)
  told: Channel[Client.Item] = Channel.new(1)
  Task.await(backend.subscribe.call("s1", 0, ->(item) { told.send(item, 1000) }))
  Test.eq(told.recv(1000), ok(Client.Item.Ended("no server")))
end

def error_kind_of[T](result: Result[T]) -> String
  case result
    ok(_) -> "ok"
    error(e) -> e.kind
  end
end

# The Markdown of an export: the title and date, each message under its role, the tool calls of an answer as a list
# with their result, and the todo list. An escape or bidi character is written as its code.
def test_an_export_is_markdown_with_its_tools_and_todos() -> Result[Void]
  text = Client.markdown(sample())
  expected = [
    "# Fix it",
    "Session `s1`, started 2026-06-12T10:55:02Z.",
    "## User",
    "Fix it\nnow \\u001b[2J and \\u202eevil",
    "- `read_file` a.txt (ok)\n- `bash` make (error)\n- `bash` sleep 9 (no result)",
    "## Assistant",
    "Done.",
    "## Todos",
    "- [x] Write the test\n- [ ] Fix the bug (in progress)\n- [ ] Ship",
  ]

  Test.eq(text, expected.join("\n\n") + "\n")
end

# The file is made 0600 at `ID.md` by default; one that exists is refused unless --force, which replaces only a file.
def test_an_export_file_is_private_and_never_replaced_without_force() -> Result[Void]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/finn-export-#{Random.int(0, 999_999_999)}"
  try Dir.mkdir_private(dir)
  path = Client.export_path("s1", some("#{dir}/out.md"))
  first = Client.saved(sample(), path, false)
  mode = (try File.stat(path)).mode
  again = Client.saved(sample().with(title: "Other"), path, false)
  kept = try File.read_text(path)
  forced = Client.saved(sample().with(title: "Other"), path, true)
  replaced = try File.read_text(path)
  folder = Client.saved(sample(), dir, true)
  _ = Path.remove(dir)
  try Test.eq([first, forced], [ok(path), ok(path)])
  try Test.eq([mode.to_s, Client.export_path("s1", none)], ["384", "s1.md"])
  try Test.eq([again.ok?, kept.start_with?("# Fix it"), replaced.start_with?("# Other")], [false, true, true])
  Test.eq(
    [message_of(again), message_of(folder)],
    ["#{path} exists: add --force to replace it", "#{dir} is not a file"],
  )
end

def message_of(result: Result[String]) -> String
  case result
    ok(_) -> "ok"
    error(e) -> e.message
  end
end

def sample() -> Protocol.SessionExport
  Protocol.SessionExport(
    id: "s1",
    title: "Fix it",
    created_ms: 1_781_261_702_345,
    entries: [
      Protocol.ExportEntry(
        kind: "user",
        text: "Fix it\nnow #{String.from_code(0x1B)}[2J and #{String.from_code(0x202E)}evil",
      ),
      Protocol.ExportEntry(kind: "tool", tool: "read_file", text: "a.txt", ok: some(true)),
      Protocol.ExportEntry(kind: "tool", tool: "bash", text: "make", ok: some(false)),
      Protocol.ExportEntry(kind: "tool", tool: "bash", text: "sleep 9"),
      Protocol.ExportEntry(kind: "assistant", text: "Done."),
    ],
    todos: [
      Protocol.Todo(content: "Write the test", status: "completed"),
      Protocol.Todo(content: "Fix the bug", status: "in_progress"),
      Protocol.Todo(content: "Ship", status: "pending"),
    ],
  )
end

# A client names a profile other than the built-in `build`, then the server's warnings about it, printable.
def test_the_lines_of_a_profile() -> Result[Void]
  plan = Protocol.Profile(name: "plan", source: "built-in")
  broken = Protocol.Profile(name: "x", source: "", warnings: ["x.md: bad#{String.from_code(27)}[2J"])
  try Test.eq(Client.profile_lines(some(Protocol.Profile(name: "build", source: "built-in"))), [])
  try Test.eq(Client.profile_lines(some(plan)), ["profile plan (built-in)"])
  Test.eq(Client.profile_lines(some(broken)), ["profile x (does not load)", "warning: x.md: bad [2J"])
end

# `/profile` with a name changes the profile, alone lists them: `*` before the session's, and why one does not load.
def test_the_profile_command_and_listing() -> Result[Void]
  try Test.eq(Client.parse_command("/profile plan"), some(ok(Client.Command.Profile(some("plan")))))
  try Test.eq(Client.parse_command("/profile"), some(ok(Client.Command.Profile(none))))
  list = Protocol.ProfileList(
    profiles: [
      Protocol.Profile(name: "build", source: "built-in", description: "every tool"),
      Protocol.Profile(name: "bad", source: "", warnings: ["bad.md: unknown key colour"]),
    ],
  )

  Test.eq(
    Client.profile_listing(list, "build"),
    ["* build (built-in) every tool", "  bad: does not load: bad.md: unknown key colour"],
  )
end
