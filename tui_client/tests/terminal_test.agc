# The app on a fake terminal (TUI.Testing): events go in, the rows come out, and the calls it makes on a server go to a
# local one that only records them. What the terminal reads and draws is tested here, with no pseudo-terminal.

import HTTP from "std/http"
import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import App from "../src/app"
import Approvals from "../src/approvals"
import Args from "../src/args"

struct Rig
  fake: TUI.Testing.Fake
  feed: Channel[Client.Item]
  # The method, path and body of each call the app made on the server.
  requests: Channel[String]
end

def test_a_tiny_terminal_draws_the_panel_and_a_resize_redraws_it() -> Result[Void] = within(24, 6, &tiny)

def tiny(rig: Rig) -> Result[Void]
  try ask(rig, "write_file", "hi")
  try shows(rig, "^Y allow")
  try TUI.Testing.resize(rig.fake, 10, 3)
  # No row of the panel is on the screen: the key answers nothing.
  try press(rig, TUI.Event.Key(TUI.Key.Ctrl("y"), TUI.Mods()))
  try TUI.Testing.resize(rig.fake, 80, 24)
  try shows(rig, "Tab to answer")
  try Test.error?(rig.requests.recv(0))
  try press(rig, TUI.Event.Key(TUI.Key.Ctrl("y"), TUI.Mods()))
  Test.eq(
    rig.requests.recv(2000),
    ok("POST #{Protocol.approval_path("s1", "a1")} #{approve(Protocol.Decision.Allow)}"),
  )
end

def test_clicks_on_the_content_or_twice_on_the_tab_answer_nothing() -> Result[Void] = within(80, 24, &clicked)

def clicked(rig: Rig) -> Result[Void]
  try ask(rig, "write_file", "a = 1\n^Y please")
  try shows(rig, "Tab to answer")
  for text in ["  a = 1", "  ^Y please"]
    try click(rig, try find(rig, text))
  end

  at = try find(rig, "Tab to answer")
  # A double click: two Tabs, so the panel is back where it was, and nothing answered.
  try click(rig, at)
  try click(rig, at)
  try shows(rig, "Tab to answer")
  try click(rig, [at[0], at[1] + 2])
  rows = try shows(rig, "Tab back to the prompt")
  try Test.assert(not rows.any? { |row| row.include?("allow_session") }, "nothing was answered")
  Test.error?(rig.requests.recv(0))
end

# Typed keys go to the prompt while the panel waits, and a paste never answers: its control bytes are dropped.
def test_typing_and_pasting_while_an_approval_waits_answer_nothing() -> Result[Void] = within(80, 24, &typed)

def typed(rig: Rig) -> Result[Void]
  try ask(rig, "write_file", "hi")
  try shows(rig, "Tab to answer")
  for char in ["p", "a", "y"]
    try press(rig, TUI.Event.Char(char, TUI.Mods()))
  end

  rows = try shows(rig, " pay")
  try Test.assert(rows.any? { |row| row.include?("Tab to answer") }, "the panel still waits")
  try press(rig, TUI.Event.Key(TUI.Key.Tab, TUI.Mods()))
  try shows(rig, "y allow · n deny")
  try press(rig, TUI.Event.Paste("y#{String.from_code(1)}a#{String.from_code(25)}n\nnext"))
  rows = try shows(rig, " next")
  try Test.assert(rows.include?(" payyan"), "the pasted line has no control bytes: #{rows}")
  try Test.assert(rows.any? { |row| row.include?("y allow · n deny") }, "the panel still waits")
  try Test.error?(rig.requests.recv(0))
  try press(rig, TUI.Event.Char("A", TUI.Mods()))
  Test.eq(
    rig.requests.recv(2000),
    ok("POST #{Protocol.approval_path("s1", "a1")} #{approve(Protocol.Decision.AllowSession)}"),
  )
end

def test_escape_while_idle_sends_no_stop() -> Result[Void] = within(80, 24, &idle_escape)

def idle_escape(rig: Rig) -> Result[Void]
  try press(rig, TUI.Event.Key(TUI.Key.Escape, TUI.Mods()))
  try press(rig, TUI.Event.Char("x", TUI.Mods()))
  rows = try shows(rig, " x")
  try Test.assert(not rows.any? { |row| row.include?("Stopping") }, "nothing is stopping")
  Test.error?(rig.requests.recv(0))
end

private

# The body of an answer to the approval.
def approve(decision: Protocol.Decision) -> String = Protocol.encode_approve(Protocol.Approve(decision: decision))

def options() -> Args.Options
  Args.Options(
    state_dir: none,
    server_command: none,
    session: none,
    cwd: none,
    model: none,
    api: none,
    thinking: false,
  )
end

# Runs `body` with the app on a fake terminal of `width` by `height` and a server that records its calls, then ends
# the app with Ctrl-C.
def within(width: Int, height: Int, body: Fn[Rig, Result[Void]]) -> Result[Void]
  requests: Channel[String] = Channel.new(32)
  handler = ->(request: HTTP.Request, sent: HTTP.RequestBody) {
    seen = String.from_bytes(HTTP.read_all(sent, 4096).unwrap_or("".bytes)).unwrap_or("")
    _ = requests.send("#{request.method} #{request.path} #{seen}", 0)
    ok(HTTP.Answer.Whole(HTTP.Response(status: 200, headers: [], body: "{}".bytes)))
  }

  http = try HTTP.serve("127.0.0.1", 0, handler)
  feed: Channel[Client.Item] = Channel.new(16)
  server = Client.Server(url: "http://127.0.0.1:#{HTTP.local_port(http)}", token: "t")
  start = App.seed(server, options(), Channel.new(1), width, height)
  # No guard time: these tests send a key right after the panel shows (the guard has its own tests).
  model = start.with(
    id: "s1",
    generation: 1,
    feed: some(feed),
    effects: [App.read_feed(1, feed)],
    approvals: Approvals.Panel(guard_ms: 0),
  )

  fake = TUI.Testing.fake(width, height)
  runner = Task.spawn(-> { App.drive(TUI.Testing.backend(fake), model) })
  result = body.call(Rig(fake: fake, feed: feed, requests: requests))
  _ = fake.events.send(TUI.Event.Key(TUI.Key.Ctrl("c"), TUI.Mods()), 1000)
  feed.close
  _ = Task.await(runner)
  HTTP.close_server(http)
  _ = HTTP.wait(http)
  result
end

def ask(rig: Rig, tool: String, detail: String) -> Result[Void]
  request = Protocol.ApprovalRequested(
    approval_id: "a1",
    call_id: "c1",
    tool: tool,
    preview: "hello.txt",
    detail: detail,
  )

  rig.feed.send(Client.Item.Event(some(1), Protocol.Event.ApprovalRequested(request)), 1000)
end

def press(rig: Rig, event: TUI.Event) -> Result[Void] = rig.fake.events.send(event, 1000)

def click(rig: Rig, at: List[Int]) -> Result[Void]
  try press(rig, TUI.Event.Mouse(TUI.Mouse.Left, at[1], at[0], TUI.Mods()))
  press(rig, TUI.Event.Mouse(TUI.Mouse.Release, at[1], at[0], TUI.Mods()))
end

# Waits until some row holds `text`: the rows.
def shows(rig: Rig, text: String) -> Result[List[String]]
  TUI.Testing.wait_for(rig.fake, ->(rows: List[String]) { rows.any? { |row| row.include?(text) } })
end

# The row and column of the first `text` on the screen, after waiting for it.
def find(rig: Rig, text: String) -> Result[List[Int]]
  rows = try shows(rig, text)
  y = rows.find_index { |row| row.include?(text) }.unwrap!
  ok([y, rows[y].index_of(text).unwrap!])
end
