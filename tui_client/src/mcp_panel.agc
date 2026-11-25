## `/mcp` as a panel with a cursor: the servers in the side panel, Up and Down (or j and k) move it, and while the panel
## has the keys `r` starts the server under the cursor again, `t` or Enter shows its tools, `l` the end of its log, and
## Esc or Backspace goes back to the list. The prompt keeps its keys whenever the panel does not have the focus.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import Keymap from "keymap"
import Side from "side"
import Sides from "sides"
import State from "state"

TITLE = "MCP servers"
LIST_KEYS = "j/k r t l"
DETAIL_KEYS = "r t l Esc back"
LOG_LINES = 200

## The panel open on the servers of `status`, with the keys.
def opened(app: State.Model, status: Protocol.McpStatus) -> State.Model
  shown = Sides.shown(app, Side.of(TITLE, []))
  dialog = shown.with(mcp: some(State.McpPanel(servers: status.servers)))
  drawn(Sides.resized(dialog, app.screen_width, app.height))
end

## The dialog owns input until it closes.
def on_key(app: State.Model, raw: TUI.Event) -> State.Model
  panel = app.mcp.unwrap!
  event = Keymap.translated(app.keys, raw)
  case event
    TUI.Event.Key(TUI.Key.Up, _) -> step(app, panel, -1)
    TUI.Event.Key(TUI.Key.Down, _) -> step(app, panel, 1)
    TUI.Event.Char("k", mods) if plain?(mods) -> step(app, panel, -1)
    TUI.Event.Char("j", mods) if plain?(mods) -> step(app, panel, 1)
    TUI.Event.Char("r", mods) if plain?(mods) -> reconnect(app, panel)
    TUI.Event.Char("t", mods) if plain?(mods) -> tools(app, panel)
    TUI.Event.Key(TUI.Key.Enter, mods) if not mods.alt and panel.view == "" -> tools(app, panel)
    TUI.Event.Char("l", mods) if plain?(mods) -> log(app, panel)
    TUI.Event.Key(TUI.Key.PageUp, _) -> Sides.paged(app, -1)
    TUI.Event.Key(TUI.Key.PageDown, _) -> Sides.paged(app, 1)
    TUI.Event.Mouse(TUI.Mouse.WheelUp, _, _, _) -> Sides.moved(app, -3)
    TUI.Event.Mouse(TUI.Mouse.WheelDown, _, _, _) -> Sides.moved(app, 3)
    TUI.Event.Key(TUI.Key.Escape, _) if panel.view == "" -> Sides.closed(app)
    TUI.Event.Key(TUI.Key.Escape, _), TUI.Event.Key(TUI.Key.Backspace, _) if panel.view != "" ->
      drawn(app.with(mcp: some(panel.with(view: ""))))
    _ -> app
  end
end

## The servers as a read gave them, for the panel with that serial: the cursor stays on the same server, and the view
## on the same server if it is still there.
def read(app: State.Model, serial: Int, result: Result[Protocol.McpStatus]) -> State.Model
  return app if serial != app.side_serial or app.mcp.none?

  case result
    ok(status) -> refreshed(app, status)
    error(e) -> State.noted(app, "error: the MCP servers were not read: #{Client.printable(e.message)}")
  end
end

## The panel with `status` in place of its servers, if it is the MCP panel.
def refreshed(app: State.Model, status: Protocol.McpStatus) -> State.Model
  for panel in State.option_list(app.mcp)
    name = selected_name(panel)
    cursor = 0
    for at in 0...status.servers.size
      if status.servers[at].name == name
        cursor = at
      end
    end

    return drawn(app.with(mcp: some(panel.with(servers: status.servers, cursor: cursor))))
  end

  app
end

## The panel after a reconnect that gave `status`: as `refreshed`, and the log it shows read again.
def reconnected(app: State.Model, status: Protocol.McpStatus) -> State.Model
  again = refreshed(app, status)
  for panel in State.option_list(again.mcp)
    return log(again, panel) if panel.view == "log"
  end

  again
end

## The log lines of a server, for the panel with that serial that shows its log.
def log_read(app: State.Model, serial: Int, name: String, result: Result[Protocol.McpLog]) -> State.Model
  for panel in State.option_list(app.mcp)
    return app if serial != app.side_serial or panel.view != "log" or panel.name != name

    case result
      ok(read_lines) ->
        shown = read_lines.lines.map { |line| Client.printable(line) }
        return at_end(drawn(app.with(mcp: some(panel.with(log: shown)))))
      error(e) ->
        failed = ["the log was not read: #{Client.printable(e.message)}"]
        return drawn(app.with(mcp: some(panel.with(log: failed))))
    end
  end

  app
end

## The tool names of the server `panel` shows: only names, one per line with a blank line between them, the name
## in bold. They draw in the panel text and head styles, so CSS `.panel-text` and `.panel-head` style them.
def tool_lines(panel: State.McpPanel) -> List[String] = names_of(panel.servers, panel.name)

def names_of(servers: List[Protocol.McpServer], name: String) -> List[String]
  case servers.find { |server| server.name == name }
    ok(server) ->
      names = server.tools.map { |tool| "- **#{Client.printable(tool.name)}**" }
      return ["no tools on #{Client.printable(name)}"] if names.empty?

      names.flat_map { |line| [line, ""] }.take(names.size * 2 - 1)
    error(_) -> ["no MCP server named #{Client.printable(name)}: /mcp lists them"]
  end
end

private

def plain?(mods: TUI.Mods) -> Bool = not mods.ctrl and not mods.alt

def selected_name(panel: State.McpPanel) -> String
  return panel.name if panel.view != ""
  return "" if panel.servers.empty?

  panel.servers[panel.cursor].name
end

def step(app: State.Model, panel: State.McpPanel, by: Int) -> State.Model
  return Sides.moved(app, by) if panel.view != ""

  last = [panel.servers.size - 1, 0].max.unwrap!
  drawn(app.with(mcp: some(panel.with(cursor: [[panel.cursor + by, 0].max.unwrap!, last].min.unwrap!))))
end

def reconnect(app: State.Model, panel: State.McpPanel) -> State.Model
  name = selected_name(panel)
  return app if name == ""

  backend = app.backend
  id = app.id
  State.effect(
    State.noted(app, "mcp #{Client.printable(name)}: starting again"),
    TUI.Cmd.Run(
      -> {
        case backend.mcp_reconnect.call(id, name)
          ok(server) ->
            State.Msg.Mcp(
              Client.mcp_listing(Protocol.McpStatus(servers: [server]))[0],
              status_of(backend.mcp.call(id)),
            )
          error(e) -> State.Msg.Note("error: mcp #{Client.printable(name)}: #{Client.printable(e.message)}")
        end
      },
    ),
  )
end

def status_of(read: Result[Protocol.McpStatus]) -> Optional[Protocol.McpStatus]
  return none if not read.ok?

  some(read.unwrap!)
end

def tools(app: State.Model, panel: State.McpPanel) -> State.Model
  name = selected_name(panel)
  return app if name == ""

  refresh(top(drawn(app.with(mcp: some(panel.with(view: "tools", name: name))))))
end

def log(app: State.Model, panel: State.McpPanel) -> State.Model
  name = selected_name(panel)
  return app if name == ""

  backend = app.backend
  id = app.id
  serial = app.side_serial
  shown = top(drawn(app.with(mcp: some(panel.with(view: "log", name: name, log: ["reading the log..."])))))
  State.effect(
    shown,
    TUI.Cmd.Run(-> { State.Msg.McpLogRead(serial, name, backend.mcp_log.call(id, name, LOG_LINES)) }),
  )
end

# The servers are read again after an action, so what the panel shows is what the server says now.
def refresh(app: State.Model) -> State.Model
  backend = app.backend
  id = app.id
  serial = app.side_serial
  State.effect(app, TUI.Cmd.Run(-> { State.Msg.McpRead(serial, backend.mcp.call(id)) }))
end

# The panel's lines for what it shows now.
def drawn(app: State.Model) -> State.Model
  for panel in State.option_list(app.mcp)
    for side in State.option_list(app.side)
      rich = panel.view == "tools"
      shown = app.with(side: some(Side.retitled(side, title_of(panel), keys_of(panel), lines_of(panel), rich)))
      return shown if panel.view != "" or panel.servers.empty?

      return Sides.revealed(shown, panel.cursor)
    end
  end

  app
end

def title_of(panel: State.McpPanel) -> String
  return TITLE if panel.view == ""

  "MCP #{Client.printable(panel.name)} #{panel.view}"
end

def keys_of(panel: State.McpPanel) -> String
  return LIST_KEYS if panel.view == ""

  DETAIL_KEYS
end

def lines_of(panel: State.McpPanel) -> List[String]
  case panel.view
    "tools" -> tool_lines(panel)
    "log" -> panel.log
    _ -> listed(panel)
  end
end

def listed(panel: State.McpPanel) -> List[String]
  rows = Client.mcp_listing(Protocol.McpStatus(servers: panel.servers))
  return rows if panel.servers.empty?

  (0...rows.size).to_a.map { |at| marked(rows[at], at == panel.cursor) }
end

def marked(row: String, selected: Bool) -> String
  return "> #{row}" if selected

  "  #{row}"
end

# A view that was just opened shows from its first line.
def top(app: State.Model) -> State.Model = Sides.moved(app, -1_000_000)

# The panel shows the end of the log.
def at_end(app: State.Model) -> State.Model = Sides.moved(app, 1_000_000)
