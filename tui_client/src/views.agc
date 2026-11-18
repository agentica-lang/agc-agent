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
import Transcript from "transcript"
import State from "state"
import Files from "files"

def shown_name(shown: Bool) -> String
  return "shown" if shown

  "folded"
end

def framed(app: State.Model) -> Screen.Frame
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
  )

  frame = Screen.frame(
    app.width,
    app.height,
    Transcript.tail(app.entries, app.width, State.folds(app), app.height + app.scroll),
    app.scroll,
    parts,
  )

  frame.with(marks: Select.marks(app.selection, frame.base, frame.transcript.size))
end

## The rows of the approval panel, without the transcript: a key needs only these.
def panel(app: State.Model) -> List[Layout.Row]
  rows = Prompt.view(app.prompt, State.cursor(app), app.width, app.height).rows.size
  approval_rows(app, Screen.panel_room(app.height, rows))
end

private

# The key hints of the status line, most needed first: those that do not fit are left out.
HINTS = [
  "Enter send",
  "Esc stop",
  "^C quit",
  "^J newline",
  "Alt+Enter follow-up",
  "⇧Tab thinking level",
  "^T show thinking",
  "^O show tool output",
  "@ files",
  "/ commands (Esc Enter: as typed)",
  "↑ history",
  "PgUp/PgDn",
]

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

  Footer.status(state, app.usage, HINTS, model, width, Rate.text(app.rate))
end
