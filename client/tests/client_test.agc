import Protocol from "pkg/protocol/protocol"
import Client from "../client"

# A port nothing listens on: the one of a server that was just closed.
CLOSED = Client.Server(url: "http://127.0.0.1:9", token: "t")

def test_the_state_folder_option_wins_and_is_resolved() -> Result[Void]
  launch = Client.Launch(main: "cli/main.agc", state_dir: some("/tmp/../tmp/finn-test-none"))
  Test.eq(Client.state_dir(launch), ok("/tmp/finn-test-none"))
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
  try Test.eq(Client.parse_command("/resume 2"), some(ok(Client.Command.Resume(some("2")))))
  try Test.eq(Client.parse_command("/model qwen3:8b"), some(ok(Client.Command.Model(some("qwen3:8b")))))
  try Test.eq(Client.parse_command("/thinking high"), some(ok(Client.Command.Thinking(some("high")))))
  try Test.eq(Client.parse_command("/thinking default"), some(ok(Client.Command.Thinking(some("default")))))
  try Test.eq(Client.parse_command("/tree 2+"), some(ok(Client.Command.Tree(some("2+")))))
  try Test.eq(Client.parse_command("/fork"), some(ok(Client.Command.Fork(none))))
  try Test.eq(Client.parse_command("/clone"), some(ok(Client.Command.Clone)))
  for text in ["/review-pr 12", "/etc/hosts has a bad entry", "/"]
    try Test.eq(Client.parse_command(text), none)
  end

  for bad in ["/thinking max", "/new now", "/model qwen3 8b", "/clone 2"]
    parsed = Client.parse_command(bad)
    case parsed
      some(error(e)) -> try Test.eq(e.kind, Client.KIND_COMMAND)
      _ -> return error("#{bad} gave #{parsed}")
    end
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

# A branch puts its messages a step in; the numbers name a message (before it) or, with `+`, its answer (after it).
def test_the_tree_is_listed_depth_first_and_picked_by_number() -> Result[Void]
  nodes = [
    Protocol.TreeNode(id: 1, text: "One.", answer: "A1", last: 7, active: true),
    Protocol.TreeNode(id: 8, parent: some(1), text: "Two.", answer: "A2", last: 14),
    Protocol.TreeNode(id: 9, parent: some(8), text: "Two more.\nsecond line", last: 20),
    Protocol.TreeNode(id: 21, parent: some(1), text: "Three.", answer: "A3", last: 27, active: true),
  ]

  tree = Protocol.SessionTree(nodes: nodes)
  listed = ["1. * One.  -> A1", "2.     Two.  -> A2", "3.     Two more.  -> ", "4.   * Three.  -> A3"]

  try Test.eq(Client.tree_listing(tree), listed)
  try Test.eq([Client.tree_entry(tree, "4"), Client.tree_entry(tree, "2+")], [ok(21), ok(14)])
  try Test.error?(Client.tree_entry(tree, "5"))
  Test.error?(Client.tree_entry(tree, "x+"))
end

# What a client echoes of another's text stays on one line, with no terminal escapes.
def test_printable_turns_control_characters_into_spaces() -> Result[Void]
  Test.eq(Client.printable("a#{String.from_code(27)}[2Jb\nc\td"), "a [2Jb c d")
end

# `/model provider/model` moves to a provider of the list; any other text (a name with a `/`) is the model alone.
def test_model_change_splits_a_known_provider() -> Result[Void]
  list = Protocol.ProviderList(
    provider: "local",
    providers: [Protocol.ProviderInfo(name: "fw", api: "openai", models: [])],
  )

  try Test.eq(Client.model_change(list, "fw/m"), Protocol.UpdateSession(provider: some("fw"), model: some("m")))
  try Test.eq(Client.model_change(list, "org/m"), Protocol.UpdateSession(model: some("org/m")))
  try Test.eq(Client.model_change(list, "fw/"), Protocol.UpdateSession(model: some("fw/")))
  Test.eq(Client.model_change(list, "m"), Protocol.UpdateSession(model: some("m")))
end
