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
  try Test.eq(Client.parse_command("/model qwen3 8b"), some(ok(Client.Command.Model(some("qwen3 8b")))))
  try Test.eq(Client.parse_command("/thinking high"), some(ok(Client.Command.Thinking(some("high")))))
  for bad in ["/thinking max", "/new now", "/frobnicate"]
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
