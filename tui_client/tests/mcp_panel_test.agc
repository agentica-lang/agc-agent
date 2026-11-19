# The `/mcp` panel with a cursor: Up, Down, j and k move it; while the panel has the keys, `r` starts the server
# under it
# again, `t` or Enter shows its tools, `l` its log, and Esc goes back; and a letter typed in the prompt never does any
# of that.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import App from "../src/app"
import Args from "../src/args"
import Side from "../src/side"

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
  try Test.assert(
    tools.model.side.unwrap!.lines.any? { |line| line.include?("mcp__fs__read: Reads a file") },
    "#{tools.model.side}",
  )

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

# With the panel on the transcript's side (F6) the prompt has the keys: a letter goes into it and does nothing to the
# servers, and the title and the footer name the panel's keys only while it has them.
def test_a_letter_typed_in_the_prompt_does_nothing_to_the_servers() -> Result[Void]
  asked: Channel[String] = Channel.new(4)
  opened = ran(model_of(asked), "/mcp")
  try Test.assert(title_of(opened).include?("r reconnect"), title_of(opened))
  try Test.assert(footer(opened).include?("r reconnect"), footer(opened))
  away = App.update(opened, key(TUI.Key.F(6))).model
  try Test.eq(away.side.unwrap!.focused, false)
  try Test.eq(title_of(away).include?("r reconnect"), false)
  try Test.eq(footer(away).include?("r reconnect"), false)
  typed = away
  for letter in ["r", "t", "l", "j"]
    step = App.update(typed, char(letter))
    try Test.eq(step.cmds.empty?, true)
    typed = step.model
  end

  try Test.eq(typed.prompt, "rtlj")
  try Test.eq(drain(asked), [])
  try Test.eq(marked(typed), ["> fs", "  web", "  db"])
  plain = App.update(model_of(Channel.new(4)), char("r"))
  try Test.eq(plain.model.prompt, "r")
  Test.eq(plain.cmds.empty?, true)
end

def marked(app: App.Model) -> List[String]
  app.side.unwrap!.lines.map { |line| line.slice(0, line.index_of(" (").unwrap_or(line.length)) }
end

def title_of(app: App.Model) -> String = Side.rows(app.side.unwrap!, 100, 8, true, app.keys)[0].text

def footer(app: App.Model) -> String
  cells = TUI.layout(App.view(app), app.width, app.height)
  (
    (0...app.height)
      .to_a
      .map { |y| cells.select { |cell| cell.y == y }.map { |cell| cell.char }.join("").strip }
      .join("\n")
  )
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

def model_of(asked: Channel[String]) -> App.Model
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
    mcp: ->(_id: String) { ok(status()) },
    mcp_reconnect: ->(_id: String, name: String) {
      _ = asked.send(name, 0)
      ok(status().servers[1])
    },
    mcp_log: ->(_id: String, _name: String, _lines: Int) { ok(Protocol.McpLog(lines: ["line one", "line two"])) },
  )

  App.seed(backend, options, Channel.new(1), 100, 20).with(id: "s1")
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
