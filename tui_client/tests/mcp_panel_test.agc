# The `/mcp` panel with a cursor: Up, Down, j and k move it; while the panel has the keys, `r` starts the server
# under it
# again, `t` or Enter shows its tools, `l` its log, and Esc goes back; and a letter typed in the prompt never does any
# of that.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import App from "../src/app"
import Args from "../src/args"

# The cursor starts on the first server, moves with the arrows and with j and k, and stops at the ends.
def test_the_cursor_moves_over_the_servers() -> Result[Void]
  opened = ran(model_of(Channel.new(4)), "/mcp")
  try Test.eq(opened.side.unwrap!.title, "MCP servers")
  try Test.eq(marked(opened), ["> fs", "  web", "  db"])
  try Test.eq(marked(App.update(opened, char("j")).model), ["  fs", "> web", "  db"])
  try Test.eq(
    marked(App.update(App.update(opened, key(TUI.Key.Down)).model, key(TUI.Key.Down)).model),
    ["  fs", "  web", "> db"],
  )

  try Test.eq(
    marked(App.update(App.update(opened, key(TUI.Key.Down)).model, char("k")).model),
    ["> fs", "  web", "  db"],
  )

  try Test.eq(marked(App.update(opened, key(TUI.Key.Up)).model), ["> fs", "  web", "  db"])
  Test.eq(
    marked(
      App.update(
        App.update(App.update(App.update(opened, char("j")).model, char("j")).model, char("j")).model,
        char("j"),
      ).model,
    ),
    ["  fs", "  web", "> db"],
  )
end

# `r` starts the server under the cursor again in a task, and the answer brings the servers read after it.
def test_r_reconnects_the_selected_server() -> Result[Void]
  asked: Channel[String] = Channel.new(4)
  opened = ran(model_of(asked), "/mcp")
  moved = App.update(opened, char("j"))
  step = App.update(moved.model, char("r"))
  try Test.eq(step.cmds.size > 0, true)
  results = step.cmds.flat_map { |cmd| run_one(cmd) }
  try Test.eq(drain(asked), ["web"])
  try Test.eq(results.size, 1)
  after = App.update(step.model, results[0]).model
  try Test.eq(marked(after), ["  fs", "> web", "  db"])
  Test.assert(after.entries.last.text.include?("web ("), after.entries.last.text)
end

# `t` shows the tools of the server, Esc goes back to the list with the cursor where it was, and Enter does what `t`
# does; `l` shows the log lines that the server gave, and Backspace goes back.
def test_tools_and_log_open_and_go_back() -> Result[Void]
  opened = ran(model_of(Channel.new(4)), "/mcp")
  tools = App.update(opened, char("t"))
  try Test.eq(tools.model.side.unwrap!.title, "MCP fs tools")
  try Test.eq(tools.model.side.unwrap!.lines, ["- **read**"])

  try Test.eq(tools.cmds.size > 0, true)
  back = App.update(tools.model, key(TUI.Key.Escape)).model
  try Test.eq(back.side.unwrap!.title, "MCP servers")
  try Test.eq(back.side.some?, true)
  entered = App.update(App.update(back, char("j")).model, key(TUI.Key.Enter)).model
  try Test.eq(entered.side.unwrap!.title, "MCP web tools")
  logged = App.update(App.update(entered, key(TUI.Key.Backspace)).model, char("l"))
  try Test.eq(logged.model.side.unwrap!.title, "MCP web log")
  read = logged.cmds.flat_map { |cmd| run_one(cmd) }
  shown = App.update(logged.model, read[0]).model
  try Test.eq(shown.side.unwrap!.lines, ["line one", "line two"])
  closed = App.update(App.update(shown, key(TUI.Key.Escape)).model, key(TUI.Key.Escape)).model
  Test.eq(closed.side.none?, true)
end

def test_the_modal_has_a_border_and_keeps_focus_until_escape() -> Result[Void]
  asked: Channel[String] = Channel.new(4)
  opened = ran(model_of(asked), "/mcp")
  cells = TUI.layout(App.view(opened), opened.screen_width, opened.height)
  try Test.assert(cells.any? { |c| c.x > 0 and c.y == 2 and c.char == "┌" }, "the frame is inset")
  footer = cells.select { |c| c.y == opened.height - 1 }.map { |c| c.char }.join("")
  try Test.assert(footer.include?("Enter send"), "the session footer stays visible below the dialog")
  away = App.update(opened, key(TUI.Key.F(6))).model
  typed = App.update(away, char("x")).model
  try Test.eq(typed.prompt, "")
  try Test.eq(marked(App.update(typed, char("j")).model), ["  fs", "> web", "  db"])
  closed = App.update(typed, key(TUI.Key.Escape)).model
  try Test.eq(closed.mcp.none?, true)
  Test.eq(App.update(closed, char("x")).model.prompt, "x")
end

# The panel scrolls with the cursor: with more servers than rows, and with rows that wrap, the marked row stays on the
# screen however far the cursor goes.
def test_the_panel_follows_the_cursor() -> Result[Void] = cursor_follows(120)

def test_the_narrow_panel_follows_the_cursor() -> Result[Void] = cursor_follows(40)

def cursor_follows(width: Int) -> Result[Void]
  moved = ran(model_of(Channel.new(4), width, 14, 10), "/mcp")
  for _ in 1..9
    moved = App.update(moved, char("j")).model
  end

  try Test.assert(screen(moved).include?("> srv10"), "srv10 shows at #{width}")
  for _ in 1..9
    moved = App.update(moved, char("k")).model
  end

  Test.assert(screen(moved).include?("> srv1 "), "srv1 shows again at #{width}")
end

# `t` and `l` switch between the views of a server, and `r` in the log view reads the log again after it.
def test_the_views_switch_with_t_and_l_and_r_reads_the_log_again() -> Result[Void]
  opened = ran(model_of(Channel.new(4)), "/mcp")
  tools = App.update(opened, char("t")).model
  logged = App.update(tools, char("l"))
  try Test.eq(logged.model.side.unwrap!.title, "MCP fs log")
  back = App.update(logged.model, char("t")).model
  try Test.eq(back.side.unwrap!.title, "MCP fs tools")
  inlog = App.update(back, char("l")).model
  step = App.update(inlog, char("r"))
  results = step.cmds.flat_map { |cmd| run_one(cmd) }
  after = App.update(step.model, results[0])
  again = after.cmds.flat_map { |cmd| run_one(cmd) }
  try Test.eq(again.size, 1)
  Test.eq(App.update(after.model, again[0]).model.side.unwrap!.lines, ["line one", "line two"])
end

# A refresh that no longer has the server under the cursor puts the cursor on a row that is there; an empty list takes
# no key.
def test_a_refresh_without_the_server_and_an_empty_list() -> Result[Void]
  opened = ran(model_of(Channel.new(4)), "/mcp")
  moved = App.update(App.update(opened, char("j")).model, char("j")).model
  fewer = Protocol.McpStatus(servers: [status().servers[0]])
  after = App.update(moved, App.Msg.McpRead(moved.side_serial, ok(fewer))).model
  try Test.eq(marked(after), ["> fs"])
  empty = ran(model_of(Channel.new(4), 100, 20, 0), "/mcp")
  for letter in ["j", "k", "r", "t", "l"]
    step = App.update(empty, char(letter))
    try Test.eq(step.cmds.empty?, true)
    try Test.eq(step.model.prompt, "")
  end

  ok()
end

# The characters of the screen in order, rows one after the other.
def screen(app: App.Model) -> String
  TUI.layout(App.view(app), app.screen_width, app.height).map { |cell| cell.char }.join("")
end

def marked(app: App.Model) -> List[String]
  app.side.unwrap!.lines.map { |line| line.slice(0, line.index_of(" (").unwrap_or(line.length)) }
end

def many(count: Int) -> Protocol.McpStatus
  return status() if count == 3
  return Protocol.McpStatus(servers: []) if count == 0

  Protocol.McpStatus(servers: (1..count).to_a.map { |at| server("srv#{at}", "connected", []) })
end

def status() -> Protocol.McpStatus
  Protocol.McpStatus(
    servers: [
      server("fs", "connected", [Protocol.McpTool(name: "read", description: "Reads a file")]),
      server("web", "failed", []),
      server("db", "connected", []),
    ],
  )
end

def server(name: String, state: String, tools: List[Protocol.McpTool]) -> Protocol.McpServer
  Protocol.McpServer(name: name, scope: "user", transport: "stdio", target: "npx", state: state, tools: tools)
end

def model_of(asked: Channel[String], width: Int = 100, height: Int = 20, count: Int = 3) -> App.Model
  options = Args.Options(
    state_dir: none,
    server_command: none,
    session: none,
    cwd: none,
    model: none,
    api: none,
    thinking: false,
  )

  backend = Client.unreachable_backend().with(
    mcp: ->(_id: String) { ok(many(count)) },
    mcp_reconnect: ->(_id: String, name: String) {
      _ = asked.send(name, 0)
      ok(status().servers[1])
    },
    mcp_log: ->(_id: String, _name: String, _lines: Int) { ok(Protocol.McpLog(lines: ["line one", "line two"])) },
  )

  App.seed(backend, options, Channel.new(1), width, height).with(id: "s1")
end

def ran(model: App.Model, line: String) -> App.Model
  App.update(model.with(prompt: line, cursor: line.length), key(TUI.Key.Enter)).model
end

def run_one(cmd: TUI.Cmd[App.Msg]) -> List[App.Msg]
  case cmd
    TUI.Cmd.Run(work) -> [work.call()]
    _ -> []
  end
end

def drain(channel: Channel[String]) -> List[String]
  out: List[String] = []
  while true
    case channel.recv(0)
      ok(item) -> out = out.push(item)
      error(_) -> break
    end
  end

  out
end

def key(k: TUI.Key) -> App.Msg = App.Msg.Key(TUI.Event.Key(k, TUI.Mods()))

def char(c: String) -> App.Msg = App.Msg.Key(TUI.Event.Char(c, TUI.Mods()))
