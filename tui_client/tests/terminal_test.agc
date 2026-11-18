# The app on a fake terminal (TUI.Testing): events go in, the rows come out, and the calls it makes on a server go to a
# local one that only records them. What the terminal reads and draws is tested here, with no pseudo-terminal.

import HTTP from "std/http"
import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import Yolo from "pkg/client/yolo"
import TUI from "pkg/tui/tui"
import App from "../src/app"
import Editor from "../src/editor"
import Select from "../src/select"
import Selecting from "../src/selecting"
import Terminal from "../src/terminal"
import Transcript from "../src/transcript"
import Approvals from "../src/approvals"
import Args from "../src/args"
import Logins from "../src/logins"

## The base URL of `local` when nothing sets another.
DEFAULT_URL = "http://127.0.0.1:8080/v1"
ESC = String.from_code(27)
BEL = String.from_code(7)
TEXT = "alpha beta gamma delta epsilon zeta eta theta"
SSE_HEADERS = [HTTP.Header(name: "Content-Type", value: "text/event-stream")]

struct Rig
  fake: TUI.Testing.Fake
  feed: Channel[Client.Item]
  # The method and path of each call the app made on the server, and the body of each, in the same order.
  requests: Channel[String]
  bodies: Channel[String]
  # What the app wrote to the terminal outside the grid: the copies and the mouse reporting.
  written: Channel[String]
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
  answered(rig, Protocol.Decision.Allow)
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
  answered(rig, Protocol.Decision.AllowSession)
end

def test_escape_while_idle_sends_no_stop() -> Result[Void] = within(80, 24, &idle_escape)

def idle_escape(rig: Rig) -> Result[Void]
  try press(rig, TUI.Event.Key(TUI.Key.Escape, TUI.Mods()))
  try press(rig, TUI.Event.Char("x", TUI.Mods()))
  rows = try shows(rig, " x")
  try Test.assert(not rows.any? { |row| row.include?("Stopping") }, "nothing is stopping")
  Test.error?(rig.requests.recv(0))
end

# /tree opens the picker of the session's tree; Enter on a message asks for the branch, and the session is drawn again
# from its history with exactly one new event stream, the message it went back before in the prompt.
def test_a_move_opens_one_new_stream_and_fills_the_prompt() -> Result[Void] = within(80, 24, &moved, tree_replies())

def moved(rig: Rig) -> Result[Void]
  for char in "/tree".split("")
    try press(rig, TUI.Event.Char(char, TUI.Mods()))
  end

  try press(rig, TUI.Event.Key(TUI.Key.Enter, TUI.Mods()))
  try shows(rig, "2. ├   Two.")
  try press(rig, TUI.Event.Key(TUI.Key.Down, TUI.Mods()))
  try press(rig, TUI.Event.Key(TUI.Key.Down, TUI.Mods()))
  try press(rig, TUI.Event.Key(TUI.Key.Enter, TUI.Mods()))
  rows = try shows(rig, "went back before a message")
  try Test.assert(rows.any? { |row| row.strip == "Two." }, "the message is in the prompt: #{rows}")
  calls = ["GET #{Protocol.tree_path("s1")}", "POST #{Protocol.branch_path("s1")}"]
  # The first session drawn reads the slash commands of its folder.
  calls = calls + ["GET #{Protocol.session_path("s1")}", "GET #{Protocol.commands_path("s1")}"]
  calls = calls.push("GET #{Protocol.events_path("s1")}")
  for call in calls
    try Test.eq(rig.requests.recv(2000), ok(call))
  end

  Test.error?(rig.requests.recv(500))
end

private

def tree_replies() -> Map[String, String]
  nodes = [
    Protocol.TreeNode(id: 1, text: "One.", answer: "A1", last: 7, active: true),
    Protocol.TreeNode(id: 8, parent: some(1), text: "Two.", answer: "A2", last: 14),
    Protocol.TreeNode(id: 15, parent: some(1), text: "Three.", last: 20, active: true),
  ]

  history = [
    Protocol.Message(role: Protocol.Role.User, text: "One."),
    Protocol.Message(role: Protocol.Role.Assistant, text: "A1"),
  ]

  session = Protocol.Session(
    id: "s1",
    cwd: "/w",
    model: "m",
    last_event_id: 9,
    turn_id: none,
    turn_from_event_id: none,
    pending_approvals: [],
    history: history,
  )

  {
    "GET #{Protocol.tree_path("s1")}": Protocol.encode_session_tree(Protocol.SessionTree(nodes: nodes)),
    "POST #{Protocol.branch_path("s1")}": Protocol.encode_branched(Protocol.Branched(id: "s1", text: "Two.")),
    "GET #{Protocol.session_path("s1")}": Protocol.encode_session(session),
  }
end

# The app sent the decision to the approval a1.
def answered(rig: Rig, decision: Protocol.Decision) -> Result[Void]
  try Test.eq(rig.requests.recv(2000), ok("POST #{Protocol.approval_path("s1", "a1")}"))
  Test.eq(rig.bodies.recv(2000), ok(Protocol.encode_approve(Protocol.Approve(decision: decision))))
end

# The first start with no provider set up opens the login picker. The key is drawn as dots, and goes once, in the
# body of the login; the answer says the provider is set up.
def test_the_first_start_offers_a_login_with_a_hidden_key() -> Result[Void]
  replies = {
    "GET #{Protocol.AUTH_PATH}": Protocol.encode_login_list(logins()),
    "POST #{Protocol.auth_path("groq")}": Protocol.encode_login_status(groq("stored")),
  }

  within(80, 24, &first_login, replies, some(&App.welcomed))
end

def first_login(rig: Rig) -> Result[Void]
  try shows(rig, "set up a provider")
  try Test.eq(rig.requests.recv(2000), ok("GET #{Protocol.AUTH_PATH}"))
  _ = try rig.bodies.recv(2000)
  for char in ["g", "r"]
    try press(rig, TUI.Event.Char(char, TUI.Mods()))
  end

  try press(rig, TUI.Event.Key(TUI.Key.Enter, TUI.Mods()))
  try shows(rig, "the key of groq")
  for char in "sk-9".split("")
    try press(rig, TUI.Event.Char(char, TUI.Mods()))
  end

  rows = try shows(rig, "key of groq: ••••")
  try Test.eq(rows.any? { |row| row.include?("sk-9") }, false)
  try press(rig, TUI.Event.Key(TUI.Key.Enter, TUI.Mods()))
  try Test.eq(rig.requests.recv(2000), ok("POST #{Protocol.auth_path("groq")}"))
  try Test.eq(rig.bodies.recv(2000), ok("{\"key\":\"sk-9\"}"))
  shown = try shows(rig, "groq is set up")
  Test.eq(shown.any? { |row| row.include?("sk-9") }, false)
end

# The login of a local server asks for its base URL, shown as typed (the note says the one it uses now); Enter sends it
# as a URL, not a key.
def test_a_local_login_asks_for_the_base_url() -> Result[Void]
  set_up = local("stored", "http://127.0.0.1:9090/v1")
  replies = {
    "GET #{Protocol.AUTH_PATH}": Protocol.encode_login_list(
      Protocol.LoginList(providers: [local("", DEFAULT_URL)], first: false),
    ),
    "POST #{Protocol.auth_path("local")}": Protocol.encode_login_status(set_up),
  }

  within(80, 24, &local_login, replies)
end

def local_login(rig: Rig) -> Result[Void]
  for char in "/login local".split("")
    try press(rig, TUI.Event.Char(char, TUI.Mods()))
  end

  try press(rig, TUI.Event.Key(TUI.Key.Enter, TUI.Mods()))
  try shows(rig, "now #{DEFAULT_URL}")
  for char in "http://127.0.0.1:9090/v1".split("")
    try press(rig, TUI.Event.Char(char, TUI.Mods()))
  end

  try press(rig, TUI.Event.Key(TUI.Key.Enter, TUI.Mods()))
  try Test.eq(rig.requests.recv(2000), ok("GET #{Protocol.AUTH_PATH}"))
  try Test.eq(rig.requests.recv(2000), ok("POST #{Protocol.auth_path("local")}"))
  _ = try rig.bodies.recv(2000)
  try Test.eq(
    rig.bodies.recv(2000),
    ok(Protocol.encode_login_url(Protocol.LoginUrl(base_url: "http://127.0.0.1:9090/v1"))),
  )

  _ = try shows(rig, "local is set up at http://127.0.0.1:9090/v1")
  ok()
end

def local(from: String, url: String) -> Protocol.LoginStatus
  Protocol.LoginStatus(
    name: "local",
    label: "a local server of the OpenAI API (llama.cpp)",
    key_env: "FINN_BASE_URL",
    from: from,
    coming: false,
    asks: Protocol.ASKS_URL,
    base_url: url,
  )
end

# Closing the first-start picker makes an empty key file when there is none (PUT), so the login is offered once.
def test_closing_the_first_login_stores_no_key() -> Result[Void]
  replies = {"GET #{Protocol.AUTH_PATH}": Protocol.encode_login_list(logins())}
  within(80, 24, &first_closed, replies, some(&App.welcomed))
end

def first_closed(rig: Rig) -> Result[Void]
  try shows(rig, "set up a provider")
  try press(rig, TUI.Event.Key(TUI.Key.Escape, TUI.Mods()))
  try shows(rig, "/login sets up a provider later")
  try Test.eq(rig.requests.recv(2000), ok("GET #{Protocol.AUTH_PATH}"))
  Test.eq(rig.requests.recv(2000), ok("PUT #{Protocol.AUTH_PATH}"))
end

# A key typed in the place of the name, or after it, leaves the screen: an unknown name is not shown again, and a
# `/login` line with more words is cleared.
def test_a_key_typed_as_a_login_name_is_not_shown() -> Result[Void]
  within(80, 24, &misplaced_key, {"GET #{Protocol.AUTH_PATH}": Protocol.encode_login_list(logins())})
end

def misplaced_key(rig: Rig) -> Result[Void]
  for line in ["/login sk-abc123", "/login groq sk-def456"]
    for char in line.split("")
      try press(rig, TUI.Event.Char(char, TUI.Mods()))
    end

    try press(rig, TUI.Event.Key(TUI.Key.Enter, TUI.Mods()))
  end

  try shows(rig, "no login has that name")
  rows = try shows(rig, "give the provider alone")
  try Test.eq(rows.any? { |row| row.include?("sk-abc123") or row.include?("sk-def456") }, false)
  Test.eq(rig.requests.recv(2000), ok("GET #{Protocol.AUTH_PATH}"))
end

def logins() -> Protocol.LoginList
  coming = Protocol.LoginStatus(name: "claude", label: "Claude Pro/Max", key_env: "", from: "", coming: true)
  Protocol.LoginList(providers: [groq(""), coming], first: true)
end

def groq(from: String) -> Protocol.LoginStatus
  Protocol.LoginStatus(name: "groq", label: "", key_env: "GROQ_API_KEY", from: from, coming: false)
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end

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

# A long output is folded; a click on the call's row shows all of it.
def test_a_click_on_a_tool_call_shows_its_whole_output() -> Result[Void] = within(80, 24, &tool_click)

def tool_click(rig: Rig) -> Result[Void]
  started = Protocol.ToolStarted(call_id: "c1", name: "bash", summary: "seq 10")
  output = (1..10).to_a.map { |i| "line #{i}" }.join("\n")
  finished = Protocol.ToolFinished(call_id: "c1", ok: true, summary: "exit 0", duration_ms: 5, output: some(output))
  try rig.feed.send(Client.Item.Event(some(1), Protocol.Event.ToolStarted(started)), 1000)
  try rig.feed.send(Client.Item.Event(some(2), Protocol.Event.ToolFinished(finished)), 1000)
  rows = try shows(rig, "6 more lines (click or ^O shows them)")
  try Test.assert(not rows.any? { |row| row.include?("line 10") }, "the output is folded")
  try click(rig, try find(rig, "$ seq 10"))
  rows = try shows(rig, "line 10")
  Test.assert(not rows.any? { |row| row.include?("more lines") }, "the whole output shows")
end

# Typing `/` and part of a name lists the commands under the editor; Tab completes the selected one.
def test_slash_suggests_the_commands_and_tab_completes() -> Result[Void] = within(80, 24, &slash)

def slash(rig: Rig) -> Result[Void]
  for char in ["/", "m", "o"]
    try press(rig, TUI.Event.Char(char, TUI.Mods()))
  end

  rows = try shows(rig, " /model [PROVIDER/]NAME")
  try Test.assert(not rows.any? { |row| row.include?("/new ") }, "the list narrows: #{rows}")
  try press(rig, TUI.Event.Key(TUI.Key.Tab, TUI.Mods()))
  rows = try TUI.Testing.wait_for(
    rig.fake,
    ->(shown: List[String]) { not shown.any? { |row| row.include?("[PROVIDER/]") } },
  )

  Test.assert(rows.any? { |row| row == " /model" }, "the prompt holds the command: #{rows}")
end

# `@` asks the server for the files of the session's folder; Tab puts the selected one in place of the word.
def test_at_lists_the_files_the_server_gives() -> Result[Void]
  listed = Protocol.encode_file_list(Protocol.FileList(files: ["README.md", "notes/thinking.sse"]))
  within(80, 24, &mention, {"GET #{Protocol.files_path("s1")}": listed})
end

def mention(rig: Rig) -> Result[Void]
  try press(rig, TUI.Event.Char("@", TUI.Mods()))
  try Test.eq(rig.requests.recv(2000), ok("GET #{Protocol.files_path("s1")}"))
  try shows(rig, " notes/thinking.sse")
  for char in ["t", "h", "k"]
    try press(rig, TUI.Event.Char(char, TUI.Mods()))
  end

  try press(rig, TUI.Event.Key(TUI.Key.Tab, TUI.Mods()))
  rows = try shows(rig, "@notes/thinking.sse")
  Test.assert(not rows.any? { |row| row.include?("README.md") }, "the list closed: #{rows}")
end

# Esc before the reply of a message that went into another client's turn stops that turn by its id, so a later turn
# is not stopped.
def test_an_early_stop_names_the_turn() -> Result[Void] = within(80, 24, &early_stop, {}, some(&queued_with_stop))

def queued_with_stop(app: App.Model) -> App.Model
  accepted = Protocol.MessageAccepted(turn_id: "t9", message_id: some("t9.1"))
  opened = app.opened
  reply = TUI.Cmd.Run(-> { App.Msg.Sent(opened, "hi", ok(accepted)) })
  app.with(outbox: ["hi"], stop_wanted: true, effects: app.effects.push(reply))
end

# Esc while a turn runs stops it by the id its `turn_started` gave.
def test_escape_stops_the_running_turn_by_its_id() -> Result[Void]
  within(
    80,
    24,
    &running_stop,
    {},
    some(->(app: App.Model) { app.with(turn: true, yolo: Yolo.running(app.yolo, some("t5"))) }),
  )
end

def running_stop(rig: Rig) -> Result[Void]
  try press(rig, TUI.Event.Key(TUI.Key.Escape, TUI.Mods()))
  try Test.eq(rig.requests.recv(2000), ok("POST #{Protocol.stop_path("s1")}"))
  Test.eq(rig.bodies.recv(2000), ok(Protocol.encode_stop_turn(Protocol.StopTurn(turn_id: some("t5")))))
end

# Esc after the reply that started this client's turn, before its `turn_started`, stops it by the reply's id.
def test_escape_before_turn_started_names_the_turn_of_the_reply() -> Result[Void]
  within(80, 24, &own_stop, {}, some(&own_turn_accepted))
end

def own_turn_accepted(app: App.Model) -> App.Model
  accepted = Protocol.MessageAccepted(turn_id: "t3")
  opened = app.opened
  reply = TUI.Cmd.Run(-> { App.Msg.Sent(opened, "hi there", ok(accepted)) })
  app.with(outbox: ["hi there"], effects: app.effects.push(reply))
end

def own_stop(rig: Rig) -> Result[Void]
  try shows(rig, "hi there")
  try press(rig, TUI.Event.Key(TUI.Key.Escape, TUI.Mods()))
  try Test.eq(rig.requests.recv(2000), ok("POST #{Protocol.stop_path("s1")}"))
  Test.eq(rig.bodies.recv(2000), ok(Protocol.encode_stop_turn(Protocol.StopTurn(turn_id: some("t3")))))
end

def early_stop(rig: Rig) -> Result[Void]
  try Test.eq(rig.requests.recv(2000), ok("POST #{Protocol.stop_path("s1")}"))
  Test.eq(rig.bodies.recv(2000), ok(Protocol.encode_stop_turn(Protocol.StopTurn(turn_id: some("t9")))))
end

# Runs `body` with the app on a fake terminal of `width` by `height` and a server that records its calls, then ends
# the app with Ctrl-C. The server answers a call with its body in `replies` ("{}" when none), and an event stream
# with one that stays open until the end.
def within(
  width: Int,
  height: Int,
  body: Fn[Rig, Result[Void]],
  replies: Map[String, String] = {},
  first: Optional[Fn[App.Model, App.Model]] = none,
) -> Result[Void]
  requests: Channel[String] = Channel.new(32)
  streams: Channel[Channel[Bytes]] = Channel.new(8)
  bodies: Channel[String] = Channel.new(32)
  written: Channel[String] = Channel.new(32)
  handler = ->(request: HTTP.Request, sent: HTTP.RequestBody) {
    call = "#{request.method} #{request.path}"
    _ = requests.send(call, 0)
    _ = bodies.send(String.from_bytes(HTTP.read_all(sent, 4096).unwrap_or("".bytes)).unwrap_or(""), 0)
    if request.path.end_with?("/events")
      out: Channel[Bytes] = Channel.new(1)
      _ = streams.send(out, 0)
      return ok(HTTP.Answer.Stream(HTTP.StreamResponse(status: 200, headers: SSE_HEADERS, body: out)))
    end

    ok(HTTP.Answer.Whole(HTTP.Response(status: 200, headers: [], body: replies.get(call, "{}").bytes)))
  }

  http = try HTTP.serve("127.0.0.1", 0, handler)
  feed: Channel[Client.Item] = Channel.new(16)
  server = Client.Server(url: "http://127.0.0.1:#{HTTP.local_port(http)}", token: "t")
  start = App.seed(Client.http_backend(server), options(), Channel.new(1), width, height)
  # No guard time: these tests send a key right after the panel shows (the guard has its own tests).
  model = start.with(
    id: "s1",
    generation: 1,
    feed: some(feed),
    effects: [App.read_feed(1, feed)],
    approvals: Approvals.Panel(guard_ms: 0),
    write: ->(text: String) { _ = written.send(text, 1000) },
  )

  for change in option_list(first)
    model = change.call(model)
  end

  fake = TUI.Testing.fake(width, height)
  runner = Task.spawn(-> { App.drive(TUI.Testing.backend(fake), model) })
  result = body.call(Rig(fake: fake, feed: feed, requests: requests, bodies: bodies, written: written))
  _ = fake.events.send(TUI.Event.Key(TUI.Key.Ctrl("c"), TUI.Mods()), 1000)
  _ = Task.await(runner)
  feed.close
  while true
    case streams.recv(0)
      ok(out) -> out.close
      error(_) -> break
    end
  end

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

# `finn login` of a provider whose login the server refuses ends with 1, and the reason is not left on the screen that
# the end wipes: the outcome carries it, for the line written once the screen is closed. A signal says so too.
def test_a_login_the_server_refuses_ends_with_a_reason() -> Result[Void]
  chatgpt = Protocol.LoginStatus(
    name: "chatgpt",
    label: "ChatGPT Plus or Pro (Codex)",
    key_env: "",
    from: "",
    coming: false,
    asks: Protocol.ASKS_DEVICE,
  )

  listed = Protocol.encode_login_list(Protocol.LoginList(providers: [chatgpt], first: false))
  refusal = Protocol.Failure(
    kind: Protocol.KIND_LOGIN_REJECTED,
    message: "the ChatGPT login answered what is not read",
  )

  handler = ->(request: HTTP.Request, _sent: HTTP.RequestBody) {
    if request.method == "POST"
      return ok(
        HTTP.Answer.Whole(HTTP.Response(status: 400, headers: [], body: Protocol.encode_failure(refusal).bytes)),
      )
    end

    ok(HTTP.Answer.Whole(HTTP.Response(status: 200, headers: [], body: listed.bytes)))
  }

  http = try HTTP.serve("127.0.0.1", 0, handler)
  server = Client.Server(url: "http://127.0.0.1:#{HTTP.local_port(http)}", token: "t")
  signals: Channel[System.Signal] = Channel.new(1)
  seeded = App.seed(Client.http_backend(server), options(), signals, 80, 24)
  start = try Logins.login_only(seeded, some("chatgpt"))
  # No signal comes: the wait for one ends at once, so no task of it is left.
  signals.close
  fake = TUI.Testing.fake(80, 24)
  runner = Task.spawn(-> { App.drive_outcome(TUI.Testing.backend(fake), start) })
  outcome = try Task.await(runner)
  fake.events.close
  HTTP.shutdown(http, 1000)
  try Test.eq(outcome.code, 1)
  try Test.assert(outcome.reason.unwrap_or("").include?("the ChatGPT login answered what is not read"), "#{outcome}")
  signalled = try App.outcome(start.with(exit: some(143)))
  Test.eq(["#{signalled.code}", signalled.reason.unwrap_or("").include?("signal").to_s], ["143", "true"])
end

# The warnings of the server are a yellow banner at the top of a started app, not notes of the transcript: the last of
# them, each text once with its times, and the count. A click on it, or Esc with an empty prompt, closes it, and a
# click below it still reaches the transcript.
def test_the_warnings_of_the_server_are_a_banner_that_a_click_or_esc_closes() -> Result[Void]
  replies = {"GET /v1/logs": Protocol.encode_server_log(warned_log(4))}
  try within(100, 16, &banner_closed_by_a_click, replies: replies, first: some(&App.server_notes))
  within(100, 16, &banner_closed_by_esc, replies: replies, first: some(&App.server_notes))
end

def warned_log(count: Int) -> Protocol.ServerLog
  warnings = ["2026-11-18T10:00:01.000Z WARNING pr-reviewer is shadowed (×3)"]
  if count == 0
    warnings = []
  end

  Protocol.ServerLog(
    lines: ["2026-11-18T10:00:00.000Z INFO older", "2026-11-18T10:00:01.000Z WARNING bad skill"],
    warnings: warnings,
    warning_count: count,
  )
end

def banner_closed_by_a_click(rig: Rig) -> Result[Void]
  rows = try shows(rig, "pr-reviewer is shadowed (×3)")
  try Test.eq(rows.filter { |row| row.include?("pr-reviewer is shadowed") }.size, 1)
  try Test.assert(
    rows[0].include?("4 warnings when the server started (/logs shows all)"),
    "the head is first: #{rows[0]}",
  )

  try Test.assert(rows[0].strip.end_with?("x"), "the first row ends with the x: #{rows[0]}")
  started = Protocol.ToolStarted(call_id: "c1", name: "bash", summary: "seq 10")
  output = (1..10).to_a.map { |i| "line #{i}" }.join("\n")
  finished = Protocol.ToolFinished(call_id: "c1", ok: true, summary: "exit 0", duration_ms: 5, output: some(output))
  try rig.feed.send(Client.Item.Event(some(1), Protocol.Event.ToolStarted(started)), 1000)
  try rig.feed.send(Client.Item.Event(some(2), Protocol.Event.ToolFinished(finished)), 1000)
  try shows(rig, "6 more lines")
  try click(rig, try find(rig, "$ seq 10"))
  rows = try shows(rig, "line 10")
  try Test.assert(rows[0].include?("when the server started"), "a click below the banner leaves it: #{rows[0]}")
  try click(rig, [1, 5])
  gone(rig)
end

def banner_closed_by_esc(rig: Rig) -> Result[Void]
  try shows(rig, "pr-reviewer is shadowed (×3)")
  try press(rig, TUI.Event.Char("a", TUI.Mods()))
  try press(rig, TUI.Event.Key(TUI.Key.Escape, TUI.Mods()))
  rows = try shows(rig, "pr-reviewer is shadowed (×3)")
  try Test.assert(rows[0].include?("when the server started"), "Esc with text in the prompt keeps the banner")
  try press(rig, TUI.Event.Key(TUI.Key.Backspace, TUI.Mods()))
  try press(rig, TUI.Event.Key(TUI.Key.Escape, TUI.Mods()))
  try gone(rig)
  for char in "/logs 2".split("")
    try press(rig, TUI.Event.Char(char, TUI.Mods()))
  end

  try press(rig, TUI.Event.Key(TUI.Key.Enter, TUI.Mods()))
  try shows(rig, "INFO older")
  ok()
end

# Waits until the banner is not on the screen.
def gone(rig: Rig) -> Result[Void]
  _ = try TUI.Testing.wait_for(
    rig.fake,
    ->(rows: List[String]) { not rows.any? { |row| row.include?("when the server started") } },
  )

  ok()
end

# `/reload` asks the server to read its config, skills and MCP servers again: one note says what changed, and each
# warning has its own.
def test_reload_notes_what_the_server_read_again() -> Result[Void]
  done = Protocol.Reloaded(skills_added: ["lint"], skills_removed: ["old"], config: "unchanged", warnings: ["w"])
  within(120, 24, &reloaded, {"POST /v1/reload": Protocol.encode_reloaded(done)})
end

def reloaded(rig: Rig) -> Result[Void]
  for char in "/reload".split("")
    try press(rig, TUI.Event.Char(char, TUI.Mods()))
  end

  try press(rig, TUI.Event.Key(TUI.Key.Enter, TUI.Mods()))
  try shows(rig, "skills: 1 added (lint), 1 removed (old); config unchanged (0 rules, approvals off)")
  try shows(rig, "warning: w")
  ok()
end

# What the console gets after the screen closes: the warnings of the server, then how to come back.
def test_the_report_of_the_warnings_comes_before_the_hint_that_follows() -> Result[Void]
  try Test.eq(App.joined(some("report"), some("hint")), some("report\nhint"))
  try Test.eq(App.joined(some("report"), none), some("report"))
  try Test.eq(App.joined(none, some("hint")), some("hint"))
  Test.eq(App.joined(none, none), none)
end

def said(text: String) -> Fn[App.Model, App.Model]
  ->(model: App.Model) {
    model.with(entries: Transcript.from_history([Protocol.Message(role: Protocol.Role.User, text: text)]))
  }
end

def mouse(button: TUI.Mouse, at: List[Int], motion: Bool = false) -> TUI.Event
  TUI.Event.Mouse(button, at[0], at[1], TUI.Mods(motion: motion))
end

def reversed_at?(fake: TUI.Testing.Fake, x: Int, y: Int) -> Bool
  case TUI.Testing.style_at(fake, x, y)
    some(style) -> style.reverse
    none -> false
  end
end

# A drag over wrapped rows selects them and the release copies the text as it was written, with no gutter and no break
# where the screen cut it, as an OSC 52 sequence; a note says how much. Esc clears the selection.
def test_a_drag_copies_the_text_across_wrapped_rows_and_esc_clears_the_selection() -> Result[Void]
  within(20, 12, &dragged, first: some(said(TEXT)))
end

def dragged(rig: Rig) -> Result[Void]
  start = try find(rig, "alpha beta gamma")
  last = try find(rig, "eta theta")
  try press(rig, mouse(TUI.Mouse.Left, [start[1], start[0]]))
  try press(rig, mouse(TUI.Mouse.Left, [last[1] + 8, last[0]], motion: true))
  try TUI.Testing.wait_for(rig.fake, ->(_rows: List[String]) { reversed_at?(rig.fake, start[1], start[0]) })
  try press(rig, mouse(TUI.Mouse.Release, [last[1] + 8, last[0]]))
  try Test.eq(try rig.written.recv(2000), Terminal.osc52(TEXT))
  try shows(rig, "copied #{TEXT.length}")
  try press(rig, TUI.Event.Key(TUI.Key.Escape, TUI.Mods()))
  try TUI.Testing.wait_for(rig.fake, ->(_rows: List[String]) { not reversed_at?(rig.fake, start[1], start[0]) })
  ok()
end

# The selection keeps the rows it was made on when the transcript scrolls under the drag, and runs from the earlier
# row to the later one whichever way the button went.
def test_a_drag_across_a_scroll_copies_the_rows_between() -> Result[Void]
  texts = (10...30).to_a.map { |n| "m#{n}" }
  entries = ->(model: App.Model) {
    model.with(
      entries: Transcript.from_history(texts.map { |text| Protocol.Message(role: Protocol.Role.User, text: text) }),
    )
  }

  within(30, 12, &scrolled, first: some(entries))
end

def scrolled(rig: Rig) -> Result[Void]
  bottom = try find(rig, "m29")
  try press(rig, mouse(TUI.Mouse.Left, [bottom[1] + 2, bottom[0]]))
  try press(rig, mouse(TUI.Mouse.WheelUp, [0, 0]))
  top = try find(rig, "m25")
  try press(rig, mouse(TUI.Mouse.Left, [top[1], top[0]], motion: true))
  try press(rig, mouse(TUI.Mouse.Release, [top[1], top[0]]))
  Test.eq(try rig.written.recv(2000), Terminal.osc52("m25\n\nm26\n\nm27\n\nm28\n\nm29"))
end

# A double click selects the word under it and copies it.
def test_a_double_click_copies_the_word() -> Result[Void] = within(40, 12, &doubled, first: some(said(TEXT)))

def doubled(rig: Rig) -> Result[Void]
  at = try find(rig, "alpha beta gamma")
  cell = [at[1] + 12, at[0]]
  for _ in 0...2
    try press(rig, mouse(TUI.Mouse.Left, cell))
    try press(rig, mouse(TUI.Mouse.Release, cell))
  end

  Test.eq(try rig.written.recv(2000), Terminal.osc52("gamma"))
end

# `/mouse` turns the mouse reporting off and on again, and the terminal is told each time.
def test_mouse_turns_the_reporting_off_and_on() -> Result[Void] = within(60, 12, &toggled)

def toggled(rig: Rig) -> Result[Void]
  for text in ["/mouse", "/mouse"]
    for char in text.split("")
      try press(rig, TUI.Event.Char(char, TUI.Mods()))
    end

    try press(rig, TUI.Event.Key(TUI.Key.Enter, TUI.Mods()))
  end

  try Test.eq(try rig.written.recv(2000), Terminal.mouse(false))
  try shows(rig, "mouse off: the terminal selects text")
  try Test.eq(try rig.written.recv(2000), Terminal.mouse(true))
  try shows(rig, "mouse on: drag to select and copy")
  ok()
end

# `"mouse": false` in the config of the server (its status says so) turns the reporting off when the app starts.
def test_the_config_can_turn_the_mouse_off() -> Result[Void]
  status = Protocol.ServerStatus(
    pid: 1,
    version: "v",
    started_s: 0,
    sessions: 0,
    running_turns: 0,
    stopping: false,
    mouse: some(false),
  )

  replies = {"GET #{Protocol.SERVER_PATH}": Protocol.encode_server_status(status)}
  within(60, 12, &configured, replies: replies, first: some(&App.configured))
end

def configured(rig: Rig) -> Result[Void] = Test.eq(try rig.written.recv(2000), Terminal.mouse(false))

# A word longer than the row is cut where it must: the copy joins its pieces with nothing, and the rows cut at a space
# with one space. The sequence is the literal OSC 52 one, base64 of the UTF-8 bytes, wide characters whole.
def test_a_copy_joins_a_long_word_whole_and_writes_the_literal_sequence() -> Result[Void]
  url = "https://example.com/a/very/long/path/to/file.txt"
  within(20, 14, &long_word, first: some(said("see #{url} ok")))
end

def long_word(rig: Rig) -> Result[Void]
  start = try find(rig, "see")
  last = try find(rig, "ok")
  try press(rig, mouse(TUI.Mouse.Left, [start[1], start[0]]))
  try press(rig, mouse(TUI.Mouse.Left, [last[1] + 5, last[0]], motion: true))
  try press(rig, mouse(TUI.Mouse.Release, [last[1] + 5, last[0]]))
  Test.eq(try rig.written.recv(2000), Terminal.osc52("see https://example.com/a/very/long/path/to/file.txt ok"))
end

def test_the_copy_is_the_literal_sequence_and_keeps_wide_characters() -> Result[Void]
  within(40, 8, &wide, first: some(said("héllo 日本")))
end

def wide(rig: Rig) -> Result[Void]
  start = try find(rig, "héllo")
  try press(rig, mouse(TUI.Mouse.Left, [start[1], start[0]]))
  try press(rig, mouse(TUI.Mouse.Left, [start[1] + 30, start[0]], motion: true))
  try press(rig, mouse(TUI.Mouse.Release, [start[1] + 30, start[0]]))
  try Test.eq(try rig.written.recv(2000), "#{ESC}]52;c;aMOpbGxvIOaXpeacrA==#{BEL}")
  # A drag that ends on the left cell of a wide character takes it whole.
  try press(rig, mouse(TUI.Mouse.Left, [start[1], start[0]]))
  try press(rig, mouse(TUI.Mouse.Left, [start[1] + 6, start[0]], motion: true))
  try press(rig, mouse(TUI.Mouse.Release, [start[1] + 6, start[0]]))
  Test.eq(try rig.written.recv(2000), "#{ESC}]52;c;aMOpbGxvIOaXpQ==#{BEL}")
end

# Rows added under the transcript while the button is down do not move the selection off its text.
def test_a_selection_stays_on_its_text_while_the_transcript_grows() -> Result[Void]
  within(20, 30, &growing, first: some(said(TEXT)))
end

def growing(rig: Rig) -> Result[Void]
  start = try find(rig, "alpha beta gamma")
  try press(rig, mouse(TUI.Mouse.Left, [start[1], start[0]]))
  for number in 1...4
    started = Protocol.ToolStarted(call_id: "c#{number}", name: "bash", summary: "echo #{number}")
    try rig.feed.send(Client.Item.Event(some(number), Protocol.Event.ToolStarted(started)), 1000)
  end

  try shows(rig, "echo 3")
  last = try find(rig, "eta theta")
  try press(rig, mouse(TUI.Mouse.Left, [last[1] + 8, last[0]], motion: true))
  try press(rig, mouse(TUI.Mouse.Release, [last[1] + 8, last[0]]))
  Test.eq(try rig.written.recv(2000), Terminal.osc52(TEXT))
end

# A resize drops the selection, and a key does too (the copy leaves it shown until then).
def test_a_resize_or_a_key_clears_the_selection() -> Result[Void] = within(20, 12, &cleared, first: some(said(TEXT)))

def cleared(rig: Rig) -> Result[Void]
  start = try find(rig, "alpha beta gamma")
  try press(rig, mouse(TUI.Mouse.Left, [start[1], start[0]]))
  try press(rig, mouse(TUI.Mouse.Left, [start[1] + 5, start[0]], motion: true))
  try press(rig, mouse(TUI.Mouse.Release, [start[1] + 5, start[0]]))
  try rig.written.recv(2000)
  try TUI.Testing.wait_for(rig.fake, ->(_rows: List[String]) { reversed_at?(rig.fake, start[1], start[0]) })
  try press(rig, TUI.Event.Char("x", TUI.Mods()))
  try TUI.Testing.wait_for(rig.fake, ->(_rows: List[String]) { not reversed_at?(rig.fake, start[1], start[0]) })
  try press(rig, mouse(TUI.Mouse.Left, [start[1], start[0]]))
  try press(rig, mouse(TUI.Mouse.Left, [start[1] + 5, start[0]], motion: true))
  try TUI.Testing.wait_for(rig.fake, ->(_rows: List[String]) { reversed_at?(rig.fake, start[1], start[0]) })
  try TUI.Testing.resize(rig.fake, 24, 12)
  try TUI.Testing.wait_for(rig.fake, ->(_rows: List[String]) { not reversed_at?(rig.fake, start[1], start[0]) })
  ok()
end

# A double click on a call's row selects its word but leaves the call as it was: the first click folded or unfolded it,
# and the second puts it back.
def test_a_double_click_on_a_tool_call_leaves_it_folded() -> Result[Void] = within(80, 24, &double_on_tool)

def double_on_tool(rig: Rig) -> Result[Void]
  started = Protocol.ToolStarted(call_id: "c1", name: "bash", summary: "seq 10")
  output = (1..10).to_a.map { |i| "line #{i}" }.join("\n")
  finished = Protocol.ToolFinished(call_id: "c1", ok: true, summary: "exit 0", duration_ms: 5, output: some(output))
  try rig.feed.send(Client.Item.Event(some(1), Protocol.Event.ToolStarted(started)), 1000)
  try rig.feed.send(Client.Item.Event(some(2), Protocol.Event.ToolFinished(finished)), 1000)
  try shows(rig, "6 more lines")
  at = try find(rig, "seq 10")
  for _ in 0...2
    try press(rig, mouse(TUI.Mouse.Left, [at[1] + 1, at[0]]))
    try press(rig, mouse(TUI.Mouse.Release, [at[1] + 1, at[0]]))
  end

  try Test.eq(try rig.written.recv(2000), Terminal.osc52("seq"))
  rows = try shows(rig, "6 more lines")
  Test.assert(not rows.any? { |row| row.include?("line 10") }, "the call stayed folded")
end

# A selection over the cap is not sent: terminals and multiplexers cut a longer sequence.
def test_a_selection_too_large_to_copy_says_so() -> Result[Void]
  written: Channel[String] = Channel.new(4)
  word = (0...39).to_a.map { |_| "é" }.join("")
  text = (0...1000).to_a.map { |_| word }.join(" ")
  model = App.seed(Client.unreachable_backend(), options(), Channel.new(1), 40, 12).with(
    entries: Transcript.from_history([Protocol.Message(role: Protocol.Role.User, text: text)]),
    write: ->(sent: String) { _ = written.send(sent, 0) },
  )

  everything = Select.Selection(anchor: Select.Cell(row: 0, col: 0), head: Select.Cell(row: 100_000, col: 0))
  done = Selecting.copied(model.with(selection: some(everything)))
  try Test.error?(written.recv(0))
  Test.assert(done.entries.last.text.include?("selection too large to copy"), done.entries.last.text)
end

# The terminal library turns the mouse reporting on again when the editor ends: with `/mouse` off it is turned
# off again.
def test_the_editor_ending_keeps_the_mouse_off_when_it_was_off() -> Result[Void]
  written: Channel[String] = Channel.new(4)
  seeded = App.seed(Client.unreachable_backend(), options(), Channel.new(1), 40, 12)
  model = seeded.with(write: ->(sent: String) { _ = written.send(sent, 0) })
  _ = Editor.closed(model.with(mouse: false), ok("text"))
  try Test.eq(written.recv(0), ok(Terminal.mouse(false)))
  _ = Editor.closed(model, ok("text"))
  Test.error?(written.recv(0))
end

# The indent that a list item draws under its first row is not text: a long word cut over its rows copies without it.
def test_a_list_item_copies_without_the_indent_of_its_continued_rows() -> Result[Void]
  url = "https://very.example.com/a/long/path/x"
  within(16, 14, &list_item, first: some(assistant_said("- see #{url} now")))
end

def assistant_said(text: String) -> Fn[App.Model, App.Model]
  ->(model: App.Model) {
    model.with(entries: Transcript.from_history([Protocol.Message(role: Protocol.Role.Assistant, text: text)]))
  }
end

def list_item(rig: Rig) -> Result[Void]
  start = try find(rig, "• see")
  last = try find(rig, "now")
  try press(rig, mouse(TUI.Mouse.Left, [start[1], start[0]]))
  try press(rig, mouse(TUI.Mouse.Left, [last[1] + 5, last[0]], motion: true))
  try press(rig, mouse(TUI.Mouse.Release, [last[1] + 5, last[0]]))
  Test.eq(try rig.written.recv(2000), Terminal.osc52("• see https://very.example.com/a/long/path/x now"))
end
