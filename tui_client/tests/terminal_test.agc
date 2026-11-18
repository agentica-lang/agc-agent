# The app on a fake terminal (TUI.Testing): events go in, the rows come out, and the calls it makes on a server go to a
# local one that only records them. What the terminal reads and draws is tested here, with no pseudo-terminal.

import HTTP from "std/http"
import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import Yolo from "pkg/client/yolo"
import TUI from "pkg/tui/tui"
import App from "../src/app"
import Approvals from "../src/approvals"
import Args from "../src/args"
import Logins from "../src/logins"

## The base URL of `local` when nothing sets another.
DEFAULT_URL = "http://127.0.0.1:8080/v1"
SSE_HEADERS = [HTTP.Header(name: "Content-Type", value: "text/event-stream")]

struct Rig
  fake: TUI.Testing.Fake
  feed: Channel[Client.Item]
  # The method and path of each call the app made on the server, and the body of each, in the same order.
  requests: Channel[String]
  bodies: Channel[String]
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
  )

  for change in option_list(first)
    model = change.call(model)
  end

  fake = TUI.Testing.fake(width, height)
  runner = Task.spawn(-> { App.drive(TUI.Testing.backend(fake), model) })
  result = body.call(Rig(fake: fake, feed: feed, requests: requests, bodies: bodies))
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
  fake = TUI.Testing.fake(80, 24)
  runner = Task.spawn(-> { App.drive_outcome(TUI.Testing.backend(fake), start) })
  outcome = try Task.await(runner)
  signals.close
  fake.events.close
  HTTP.close_server(http)
  _ = HTTP.wait(http)
  Task.sleep(300)
  try Test.eq(outcome.code, 1)
  try Test.assert(outcome.reason.unwrap_or("").include?("the ChatGPT login answered what is not read"), "#{outcome}")
  signalled = try App.outcome(start.with(exit: some(143)))
  Test.eq(["#{signalled.code}", signalled.reason.unwrap_or("").include?("signal").to_s], ["143", "true"])
end

# The warnings of the server are the last notes of a started app, and `/logs N` shows the end of the log.
def test_the_warnings_of_the_server_are_notes_and_logs_shows_the_log() -> Result[Void]
  log = Protocol.ServerLog(
    lines: ["2026-11-18T10:00:00.000Z INFO older", "2026-11-18T10:00:01.000Z WARNING bad skill"],
    warnings: ["2026-11-18T10:00:01.000Z WARNING bad skill"],
    warning_count: 4,
  )

  replies = {"GET /v1/logs": Protocol.encode_server_log(log)}
  within(100, 24, &logs_shown, replies: replies, first: some(&App.server_notes))
end

def logs_shown(rig: Rig) -> Result[Void]
  try shows(rig, "WARNING bad skill")
  try shows(rig, "4 warnings when the server started: /logs shows them")
  for char in "/logs 2".split("")
    try press(rig, TUI.Event.Char(char, TUI.Mods()))
  end

  try press(rig, TUI.Event.Key(TUI.Key.Enter, TUI.Mods()))
  try shows(rig, "INFO older")
  ok()
end
