## The frame of the screen: the prompt or a picker, the approval panel, the rules and the footer. Pure.

import Client from "pkg/client/client"
import Approvals from "approvals"
import Footer from "footer"
import Input from "input"
import Picker from "picker"
import Layout from "panel"
import Prompt from "prompt"
import Rate from "rate"
import Screen from "screen"
import Select from "select"
import Side from "side"
import Transcript from "transcript"
import State from "state"
import Files from "files"

def shown_name(shown: Bool) -> String
  return "shown" if shown

  "folded"
end

def framed(app: State.Model) -> Screen.Frame = laid_out(app, app.selection.some? or app.pressed.some?)

## The same, with the rows counted from the first row of the transcript: what the mouse needs to place a cell.
def located(app: State.Model) -> Screen.Frame = laid_out(app, true)

def laid_out(app: State.Model, counted: Bool) -> Screen.Frame
  prompt = Prompt.view(app.prompt, State.cursor(app), app.width, app.height)
  for name in State.option_list(app.key_for)
    hidden = "key of #{name}: #{"•" * app.secret.length}"
    if app.asking_url
      hidden = "base URL of #{name}: #{app.secret}"
    end

    prompt = Prompt.view(hidden, hidden.length, app.width, app.height)
  end

  for device in State.option_list(app.device)
    waiting = "login of #{app.device_for}: enter #{device.user_code} at #{device.url} (Esc cancels)"
    prompt = Prompt.view(waiting, waiting.length, app.width, app.height)
  end

  parts = Screen.Parts(
    prompt: prompt,
    picker: ->(room: Int) { picker_rows(app, room) },
    panel: ->(room: Int) { approval_rows(app, room) },
    label: label(app),
    level: app.effort,
    status: status(app, app.width),
    place: Footer.place(app.cwd, app.home, app.branch, session_name(app), app.width),
    queued: app.follow_ups.map { |text| "follow-up: #{Client.printable(text)}" },
    banner: app.banner,
    cover: covering(app),
    keys: some(app.keys),
  )

  shown = Transcript.tail(app.entries, app.width, State.folds(app), app.height + app.scroll)
  frame = Screen.frame(app.width, app.height, shown, app.scroll, parts)
  return frame if not counted

  # The rows of the frame are counted from the first row of the transcript, not of what `shown` kept.
  top = frame.top + Transcript.size(app.entries, app.width, State.folds(app)) - shown.size
  frame.with(top: top, marks: Select.marks(app.selection, top, frame.transcript.size))
end

## The rows of the side panel beside the app, the full height of the screen; none when it is closed or covers the
## transcript.
def beside(app: State.Model) -> List[Layout.Row]
  return [] if not Side.wide?(app.screen_width)

  case app.side
    some(side) -> Side.rows(own_keys(app, side), Side.columns(app.screen_width), app.height, true, app.keys)
    none -> []
  end
end

## How many rows the side panel has: its title and its lines.
def side_rows(app: State.Model) -> Int
  return app.height if Side.wide?(app.screen_width)

  framed(app).area
end

## The rows of the approval panel, without the transcript: a key needs only these.
def panel(app: State.Model) -> List[Layout.Row]
  rows = Prompt.view(app.prompt, State.cursor(app), app.width, app.height).rows.size
  approval_rows(app, Screen.panel_room(app.height, rows))
end

private

# The key hints of the status line, most needed first: those that do not fit are left out. The keys are those
# in effect.
def hint_list(app: State.Model) -> List[String]
  [
    "Enter send",
    "Esc stop",
    "^C quit",
    "^J newline",
    "Alt+Enter follow-up",
    "#{short(app, "cycle_profile")} profile",
    "#{short(app, "thinking_level")} thinking level",
    "#{short(app, "show_thinking")} show thinking",
    "#{short(app, "show_tools")} show tool output",
    "@ files",
    "/ commands (Esc Enter: as typed)",
    "↑ history",
    scroll_hint(app),
  ]
end

# With the side panel closed, the logs key comes after the keys that every screen needs.
def closed_hints(app: State.Model) -> List[String]
  hints = hint_list(app)
  hints.take(3) + ["#{short(app, "logs")} logs"] + hints.drop(3)
end

def short(app: State.Model, action: String) -> String = Client.short(Client.key_of(app.keys, action))

def scroll_hint(app: State.Model) -> String = "#{short(app, "page_up")}/#{short(app, "page_down")}"

# The side panel that takes the transcript's place: only on a narrow screen.
def covering(app: State.Model) -> Optional[Side.Side]
  return none if Side.wide?(app.screen_width)

  app.side.map { |side| own_keys(app, side) }
end

# The panel with its own keys named only while they are its: not under a prompt with text.
def own_keys(app: State.Model, side: Side.Side) -> Side.Side
  return side if app.prompt == ""

  side.with(keys: "")
end

# The key hints: with the side panel open they say what its keys do, in the place of the ones that it takes (Esc
# and PgUp/PgDn).
def hints(app: State.Model) -> List[String]
  for side in State.option_list(app.side)
    focus = ""
    if Side.wide?(app.screen_width)
      focus = "#{short(app, "side_focus")} transcript"
      if not side.focused
        focus = "#{short(app, "side_focus")} panel"
      end
    end

    if Side.active?(side, app.screen_width)
      keys = (
        mcp_hints(app) +
        ["Esc close panel", focus, "#{scroll_hint(app)} scroll panel", "#{short(app, "logs")} close panel", "^C quit"]
      )

      detail = app.mcp.map { |panel| panel.view != "" }.unwrap_or(false)
      keys = keys.select { |text| text != "" and not (detail and text == "Esc close panel") }
      return keys + hint_list(app).select { |text| not rest_of_keys?(app, text) }
    end

    own = ["Enter send", "Esc close panel", focus, "^C quit", "#{short(app, "logs")} close panel"]
    return own.select { |text| text != "" } + hint_list(app).drop(3)
  end

  closed_hints(app)
end

# What the keys of the MCP panel do, while it has them.
def mcp_hints(app: State.Model) -> List[String]
  return [] if app.prompt != ""

  for panel in State.option_list(app.mcp)
    return ["Esc back", "r reconnect", "t tools", "l log"] if panel.view != ""

    return ["↑↓/jk move", "r reconnect", "t/Enter tools", "l log"]
  end

  []
end

# The hints that the side panel's own replace.
def rest_of_keys?(app: State.Model, text: String) -> Bool
  ["Enter send", "Esc stop", "^C quit", scroll_hint(app)].include?(text)
end

# The first non-empty line of the session's first user message, as the screen can show it.
def session_name(app: State.Model) -> String
  case (app.entries.find { |entry| entry.kind == Transcript.Kind.User })
    ok(entry) ->
      Client.printable(
        entry.text.split("\n").map { |line| line.strip }.select { |line| not line.empty? }.take(1).join(""),
      )
    error(_) -> ""
  end
end

# The session picker of `/resume`, in the editor's place.
def picker_rows(app: State.Model, room: Int) -> List[Layout.Row]
  case app.picker
    some(picker) -> Picker.rows(picker, app.width, room, app.clock_s)
    none -> []
  end
end

# The approval asked, under the editor; none while the picker is open.
def approval_rows(app: State.Model, room: Int) -> List[Layout.Row]
  return [] if app.picker.some?

  asked = Approvals.rows(app.approvals, app.width, room)
  return asked if not asked.empty?

  case Files.mention_list(app)
    some(found) ->
      choices = Files.mention_choices(app, found)
      selected = Files.selected_row(app, found, choices)
      Input.rows(choices, selected, Input.window(app.mention_top, selected, room, choices.size), app.width, room)
    none -> []
  end
end

# The spinner and what the turn does, in the top rule.
def label(app: State.Model) -> String
  return "#{State.SPINNER[app.spin]} Stopping" if app.stopping
  return "#{State.SPINNER[app.spin]} Working" if State.busy?(app)

  ""
end

# What the turn does is in the top rule; the status line says when the client is ready.
def status(app: State.Model, width: Int) -> String
  state: List[String] = []
  if app.options.yolo
    state = state.push("YOLO")
  end

  if not State.busy?(app)
    state = state.push("ready")
  end

  if not app.approvals.pending.empty?
    state = state.push("approval waiting")
  end

  model = ""
  if not app.serving.empty?
    model = Footer.model(app.serving, app.effort)
  end

  if not app.profile.empty?
    model = [app.profile, model].select { |part| not part.empty? }.join(" · ")
  end

  case app.statusline
    some(layout) ->
      Footer.custom(
        layout,
        Footer.Values(state: state, usage: app.usage, hints: hints(app), model: model, rate: Rate.text(app.rate)),
        width,
      )
    none -> Footer.status(state, app.usage, hints(app), model, width, Rate.text(app.rate))
  end
end
