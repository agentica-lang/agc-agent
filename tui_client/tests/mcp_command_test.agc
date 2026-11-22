# `/mcp` in the full screen: the servers in the side panel, the tools of one, a reconnect that runs in a task, the
# failed ones in the banner, and the completion of the name after `/mcp reconnect `.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import App from "../src/app"
import Args from "../src/args"

# `/mcp` shows the list and puts the failed server in the banner once, in place of the server's own warning about it;
# `/mcp NAME` shows its tools; a read that finds it well again takes it out of the banner.
def test_mcp_lists_the_servers_and_banners_the_failed_ones() -> Result[Void]
  state: Channel[Protocol.McpStatus] = Channel.new(1)
  _ = state.send(status("failed"), 0)
  model = model_of(state, Channel.new(4)).with(id: "s1")
  listed = ran(model, "/mcp")
  try Test.eq(listed.side.unwrap!.title, "MCP servers")
  try Test.assert(
    listed.side.unwrap!.lines.any? { |l| l.include?("web (project, http") and l.include?("failed: no answer") },
    "#{listed.side}",
  )

  try Test.eq(listed.banner, ["/mcp reconnect web: mcp web failed: no answer"])
  try Test.eq(
    ran(App.update(listed, App.Msg.Key(TUI.Event.Key(TUI.Key.Escape, TUI.Mods()))).model, "/mcp").banner,
    listed.banner,
  )

  tools = ran(App.update(listed, App.Msg.Key(TUI.Event.Key(TUI.Key.Escape, TUI.Mods()))).model, "/mcp fs")
  try Test.eq(tools.side.unwrap!.title, "MCP fs")
  try Test.eq(tools.side.unwrap!.lines, ["- **read**"])
  _ = state.recv(0)
  _ = state.send(status("connected"), 0)
  Test.eq(ran(tools, "/mcp").banner, [])
end

# `/mcp reconnect web` asks the server in a task and says how it went; the name is not on the screen twice.
def test_a_reconnect_runs_in_a_task_and_says_how_it_went() -> Result[Void]
  asked: Channel[String] = Channel.new(4)
  model = model_of(Channel.new(1), asked).with(id: "s1")
  step = App.update(model.with(prompt: "/mcp reconnect web", cursor: 18), enter())
  try Test.eq(step.cmds.size > 0, true)
  noted = step.model.entries.map { |e| e.text }
  try Test.eq(noted.include?("mcp web: starting again"), true)
  results = step.cmds.flat_map { |cmd| run_one(cmd) }
  try Test.eq(drain(asked), ["web"])
  try Test.eq(
    results.any? { |m| App.update(step.model, m).model.entries.last.text.include?("web (project, http") },
    true,
  )

  Test.eq(results.any? { |m| App.update(step.model, m).model.entries.last.text.include?("connected, 0 tools") }, true)
end

# After `/mcp reconnect ` the list offers the servers, the failed one first; Tab puts the name in.
def test_the_names_complete_after_reconnect() -> Result[Void]
  state: Channel[Protocol.McpStatus] = Channel.new(1)
  _ = state.send(status("failed"), 0)
  model = model_of(state, Channel.new(4)).with(id: "s1", prompt: "/mcp reconnect", cursor: 14)
  typed = App.update(model, key_char(" "))
  try Test.eq(typed.model.reading_arguments, true)
  listed = App.update(typed.model, run_one(typed.cmds[0])[0]).model
  tabbed = App.update(listed, tab()).model
  Test.eq(tabbed.prompt, "/mcp reconnect web")
end

def status(state: String) -> Protocol.McpStatus
  failing = state == "failed"
  web = Protocol.McpServer(name: "web", scope: "project", transport: "http", target: "https://h.example", state: state)

  if failing
    web = web.with(error: "no answer")
  end

  Protocol.McpStatus(
    servers: [
      Protocol.McpServer(
        name: "fs",
        scope: "user",
        transport: "stdio",
        target: "npx",
        state: "connected",
        tools: [Protocol.McpTool(name: "read", description: "Reads a file")],
      ),
      web,
    ],
  )
end

def model_of(state: Channel[Protocol.McpStatus], asked: Channel[String]) -> App.Model
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
    mcp: ->(_id: String) {
      now = state.recv(0).unwrap_or(status("failed"))
      _ = state.send(now, 0)
      ok(now)
    },
    mcp_reconnect: ->(_id: String, name: String) {
      _ = asked.send(name, 0)
      ok(status("connected").servers[1])
    },
  )

  App.seed(backend, options, Channel.new(1), 100, 20)
end

def ran(model: App.Model, line: String) -> App.Model
  App.update(model.with(prompt: line, cursor: line.length), enter()).model
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

def enter() -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.Enter, TUI.Mods()))

def tab() -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.Tab, TUI.Mods()))

def key_char(c: String) -> App.Msg = App.Msg.Key(TUI.Event.Char(c, TUI.Mods()))
