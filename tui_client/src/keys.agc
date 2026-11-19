## The keys and the mouse on the prompt, and what Enter sends.

import Client from "pkg/client/client"
import TUI from "pkg/tui/tui"
import Approvals from "approvals"
import Input from "input"
import Prompt from "prompt"
import Select from "select"
import Sides from "sides"
import Selecting from "selecting"
import Screen from "screen"
import Transcript from "transcript"
import State from "state"
import Keymap from "keymap"
import Level from "level"
import Answering from "answering"
import Editor from "editor"
import Files from "files"
import Logins from "logins"
import Turn from "turn"
import Commands from "commands"
import McpPanel from "mcp_panel"
import Views from "views"

def on_key(model: State.Model, event: TUI.Event) -> State.Model
  return unmarked(model, event) if clears_selection?(model, event)

  Files.asked(keyed(aimed(Sides.focused_by(unmarked(model, event), event), event), event))
end

private

SCROLL_STEP = 3

# Esc with a selection shown and the side panel open only clears the selection; the next Esc closes the panel.
def clears_selection?(app: State.Model, event: TUI.Event) -> Bool
  case event
    TUI.Event.Key(TUI.Key.Escape, _) ->
      (
        app.selection.some? and
        app.side.some? and
        not app.approvals.focused and
        app.picker.none? and
        app.key_for.none? and
        app.device.none?
      )
    _ -> false
  end
end

# A key (not the mouse) ends the selection, which the copy left shown: Esc then stops a turn at once.
def unmarked(app: State.Model, event: TUI.Event) -> State.Model
  case event
    TUI.Event.Mouse(_, _, _, _) -> app
    _ -> app.with(selection: none, pressed: none)
  end
end

def keyed(app: State.Model, event: TUI.Event) -> State.Model
  for name in State.option_list(app.key_for)
    return Logins.on_secret_key(app, name, event) if not State.ctrl_c?(event)
  end

  return Logins.on_device_key(app, event) if app.device.some? and not State.ctrl_c?(event)

  event = Keymap.translated(app.keys, event)

  for picker in State.option_list(app.picker)
    return Commands.on_picker_key(app, picker, event) if not State.ctrl_c?(event)
  end

  case Approvals.decision(app.approvals, event, app.now, not Views.panel(app).empty?)
    some(decision) -> return Answering.answer(app, decision)
    none -> nil
  end

  for panel_key in State.option_list(McpPanel.on_key(app, event))
    return panel_key
  end

  return app if Approvals.captures?(app.approvals, event)

  for closed in State.option_list(Files.cancelled(app, event))
    return closed
  end

  return app if Files.waiting?(app, event)

  for found in State.option_list(Files.mention_list(app))
    return send(Files.on_mention_key(app, found, event)) if Files.runs_choice?(app, found, event)
    return Files.on_mention_key(app, found, event) if Files.mention_key?(app, found, event)
  end

  edited = on_prompt_key(unselected(app, event), event)
  return Files.fresh_list(edited) if edited.prompt != app.prompt

  edited
end

# A typed character, a paste or Backspace replaces a selected prompt; any other key keeps it as text. An Alt key
# types nothing.
def unselected(app: State.Model, event: TUI.Event) -> State.Model
  return app if not app.prefilled

  case event
    TUI.Event.Char(_, mods) if not mods.alt -> app.with(prompt: "", cursor: 0, prefilled: false)
    TUI.Event.Paste(_), TUI.Event.Key(TUI.Key.Backspace, _) -> app.with(prompt: "", cursor: 0, prefilled: false)
    _ -> app.with(prefilled: false)
  end
end

def on_prompt_key(app: State.Model, event: TUI.Event) -> State.Model
  case event
    TUI.Event.Key(TUI.Key.Ctrl("c"), _) -> app.with(exit: some(0))
    TUI.Event.Key(TUI.Key.Enter, mods) if mods.alt -> follow_up(app)
    TUI.Event.Key(TUI.Key.Enter, _) -> send(app)
    TUI.Event.Key(TUI.Key.Ctrl("d"), _) if app.prompt == "" and idle?(app) -> app.with(exit: some(0))
    TUI.Event.Key(TUI.Key.Up, _) -> line_moved(app, -1)
    TUI.Event.Key(TUI.Key.Down, _) -> line_moved(app, 1)
    TUI.Event.Key(TUI.Key.Ctrl("t"), _) ->
      shown = app.with(thinking: not app.thinking, entries: Transcript.unfold_thinking(app.entries))
      State.noted(shown, "thinking blocks: #{Views.shown_name(shown.thinking)}")
    TUI.Event.Key(TUI.Key.Ctrl("o"), _) ->
      shown = app.with(tools: not app.tools, entries: Transcript.unfold_tools(app.entries))
      State.noted(shown, "tool output: #{Views.shown_name(shown.tools)}")
    TUI.Event.Key(TUI.Key.Ctrl("j"), _) -> typed(app, "\n")
    TUI.Event.Key(TUI.Key.Ctrl("g"), _) -> Editor.opened(app)
    TUI.Event.Key(TUI.Key.Backspace, mods) if mods.alt -> cut_to(app, Prompt.word_left(app.prompt, State.cursor(app)))
    TUI.Event.Key(TUI.Key.Backspace, _) -> cut_to(app, Prompt.previous_char(app.prompt, State.cursor(app)))
    TUI.Event.Key(TUI.Key.Delete, _), TUI.Event.Key(TUI.Key.Ctrl("d"), _) -> deleted(app)
    TUI.Event.Key(TUI.Key.Ctrl("w"), _) -> cut_to(app, Prompt.word_left(app.prompt, State.cursor(app)))
    TUI.Event.Key(TUI.Key.Ctrl("u"), _) -> cut_to(app, line_back(app))
    TUI.Event.Key(TUI.Key.Ctrl("k"), _) -> cut_to(app, line_forward(app))
    TUI.Event.Key(TUI.Key.Ctrl("a"), _) -> app.with(cursor: Prompt.line_start(app.prompt, State.cursor(app)))
    TUI.Event.Key(TUI.Key.Ctrl("e"), _) -> app.with(cursor: Prompt.line_end(app.prompt, State.cursor(app)))
    TUI.Event.Key(TUI.Key.Left, mods) if mods.ctrl or mods.alt ->
      app.with(cursor: Prompt.word_left(app.prompt, State.cursor(app)))
    TUI.Event.Key(TUI.Key.Right, mods) if mods.ctrl or mods.alt ->
      app.with(cursor: Prompt.word_right(app.prompt, State.cursor(app)))
    TUI.Event.Char(c, mods) if mods.alt and c.downcase == "b" ->
      app.with(cursor: Prompt.word_left(app.prompt, State.cursor(app)))
    TUI.Event.Char(c, mods) if mods.alt and c.downcase == "f" ->
      app.with(cursor: Prompt.word_right(app.prompt, State.cursor(app)))
    TUI.Event.Key(TUI.Key.Left, _) -> app.with(cursor: Prompt.previous_char(app.prompt, State.cursor(app)))
    TUI.Event.Key(TUI.Key.Right, _) -> app.with(cursor: Prompt.next_char(app.prompt, State.cursor(app)))
    TUI.Event.Key(TUI.Key.Home, _) -> app.with(cursor: 0)
    TUI.Event.Key(TUI.Key.End, _) -> app.with(cursor: app.prompt.length)
    TUI.Event.Mouse(TUI.Mouse.WheelUp, x, _, _) if Sides.over?(app, x) -> Sides.moved(app, -SCROLL_STEP)
    TUI.Event.Mouse(TUI.Mouse.WheelDown, x, _, _) if Sides.over?(app, x) -> Sides.moved(app, SCROLL_STEP)
    TUI.Event.Mouse(_, x, _, _) if Sides.beside?(app, x) and app.pressed.none? -> app
    TUI.Event.Mouse(TUI.Mouse.Left, x, y, mods) if mods.motion -> dragged(app, [x, app.width - 1].min.unwrap!, y)
    TUI.Event.Mouse(TUI.Mouse.Left, x, y, _) -> pressed(app, x, y)
    TUI.Event.Mouse(TUI.Mouse.Release, _, _, _) -> released(app)
    TUI.Event.Key(TUI.Key.Tab, _) -> app.with(approvals: Approvals.toggled(app.approvals, app.now))
    TUI.Event.Key(TUI.Key.BackTab, _) -> Commands.next_profile(app)
    TUI.Event.Key(TUI.Key.F(2), _) -> Level.leveled(app)
    TUI.Event.Key(TUI.Key.Escape, _) if app.approvals.focused ->
      app.with(approvals: Approvals.toggled(app.approvals, app.now))
    TUI.Event.Key(TUI.Key.Escape, _) if app.side.some? -> Sides.closed(app)
    TUI.Event.Key(TUI.Key.Escape, _) if closes_banner?(app) -> app.with(banner: [])
    TUI.Event.Key(TUI.Key.Escape, _) if not app.follow_ups.empty? -> Turn.stop(Turn.put_back(app))
    TUI.Event.Key(TUI.Key.Escape, _) -> Turn.stop(app)
    TUI.Event.Key(TUI.Key.PageUp, _) if Sides.active?(app) -> Sides.paged(app, -1)
    TUI.Event.Key(TUI.Key.PageDown, _) if Sides.active?(app) -> Sides.paged(app, 1)
    TUI.Event.Key(TUI.Key.Ctrl("p"), _) -> Sides.toggled(app)
    TUI.Event.Key(TUI.Key.F(6), _) -> Sides.toggled_focus(app)
    TUI.Event.Key(TUI.Key.PageUp, _) -> State.scrolled(app, State.page(app))
    TUI.Event.Key(TUI.Key.PageDown, _) -> State.scrolled(app, -State.page(app))
    TUI.Event.Mouse(TUI.Mouse.WheelUp, _, _, _) -> State.scrolled(app, SCROLL_STEP)
    TUI.Event.Mouse(TUI.Mouse.WheelDown, _, _, _) -> State.scrolled(app, -SCROLL_STEP)
    TUI.Event.Char(char, mods) if not mods.alt -> typed(app, char)
    TUI.Event.Paste(text) -> pasted(app, Prompt.pasted(text))
    _ -> app
  end
end

# Esc closes the banner of warnings when it has nothing else to do: an empty prompt and nothing running.
def closes_banner?(app: State.Model) -> Bool = not app.banner.empty? and app.prompt == "" and not State.busy?(app)

def typed(app: State.Model, piece: String) -> State.Model
  at = State.cursor(app)
  edited = app.with(prompt: Prompt.insert(app.prompt, at, piece), cursor: at + piece.length, recall: none)
  # A list Esc closed opens again for a new prompt.
  if app.prompt == ""
    edited = edited.with(mention_closed: none, mention_selected: 0, mention_top: 0, mention_moved: none)
  end

  return edited if piece != "@" or edited.reading_files or app.id == "" or app.now < app.files_again_at

  Files.read_files(edited)
end

# A large paste goes in as a token, which the send puts back.
def pasted(app: State.Model, text: String) -> State.Model
  return typed(app, text) if not Input.large?(text)

  pastes = app.pastes.push(text)
  typed(app.with(pastes: pastes), Input.token(pastes.size, text))
end

# The text from the cursor to `to`, either side of it, is cut, and the cursor goes to the start of the cut.
def cut_to(app: State.Model, to: Int) -> State.Model
  at = State.cursor(app)
  edge = Prompt.clamp(app.prompt, to)
  # An edit that deletes nothing keeps the prompt recalled.
  return app if edge == at

  from = [at, edge].min.unwrap!
  app.with(prompt: Prompt.cut(app.prompt, from, [at, edge].max.unwrap!), cursor: from, recall: none)
end

# Delete and Ctrl+D delete the character after the cursor, with the zero-width ones joined to it.
def deleted(app: State.Model) -> State.Model
  text = Prompt.delete(app.prompt, State.cursor(app))
  return app if text == app.prompt

  app.with(prompt: text, recall: none)
end

# Ctrl+D quits only when nothing runs or waits: no turn or command, no approval, no message on its way.
def idle?(app: State.Model) -> Bool
  return false if State.busy?(app) or not app.approvals.pending.empty? or not app.outbox.empty?

  not app.moving and not app.stopping
end

# Up and Down keep their column across shorter rows; any other key forgets it.
def aimed(app: State.Model, event: TUI.Event) -> State.Model
  case event
    TUI.Event.Key(TUI.Key.Up, _), TUI.Event.Key(TUI.Key.Down, _) -> app
    _ -> app.with(goal_column: none)
  end
end

# Ctrl+U cuts to the start of the line; at its start, the line end before it.
def line_back(app: State.Model) -> Int
  at = State.cursor(app)
  start = Prompt.line_start(app.prompt, at)
  return at - 1 if start == at and at > 0

  start
end

# Ctrl+K cuts to the end of the line; at its end, the line end after it.
def line_forward(app: State.Model) -> Int
  at = State.cursor(app)
  stop = Prompt.line_end(app.prompt, at)
  return at + 1 if stop == at and at < app.prompt.length

  stop
end

# Up and Down move between the rows of the prompt; from the first row (or an empty prompt) Up recalls the prompt sent
# before, and while one is recalled Down from the last row the one after.
def line_moved(app: State.Model, step: Int) -> State.Model
  return recalled(app, step) if app.prompt == "" and step < 0

  at = State.cursor(app)
  goal = app.goal_column.unwrap_or(Prompt.column(app.prompt, at, app.width))
  case Prompt.vertical(app.prompt, at, app.width, step, goal)
    some(moved) -> app.with(cursor: moved, goal_column: some(goal))
    none if app.recall.some? -> recalled(app, step)
    none -> app
  end
end

# Up shows the prompt sent before the one shown, Down the one after; past the newest the prompt is empty again.
def recalled(app: State.Model, step: Int) -> State.Model
  return app if app.history.empty?

  at = app.recall.unwrap_or(app.history.size) + step
  return app if at < 0

  return app.with(prompt: "", cursor: 0, recall: none, goal_column: none) if at >= app.history.size

  text = app.history[at]
  app.with(prompt: text, cursor: text.length, recall: some(at), goal_column: none)
end

# Alt+Enter: while a turn runs (or a message that starts one is on its way), the text waits for the turn's end.
def follow_up(app: State.Model) -> State.Model
  text = app.prompt.strip
  # A command runs now, as with Enter: it is no message for the model.
  return send(app) if text == "" or (not app.turn and app.outbox.empty?) or Client.parse_command(text).some?
  if Client.parse_shell(text).some?
    return State.noted(app, "a ! command runs between turns: send it once the turn ends")
  end

  whole = Turn.expanded(app, text)
  waiting = app.with(prompt: "", cursor: 0, recall: none, follow_ups: app.follow_ups.push(whole), pastes: [])
  waiting.with(history: Turn.remembered(waiting.history, whole))
end

# A click on the transcript opens or closes a thinking block or a tool call; on a key of the approval panel it is
# that key (with the same rules); in the prompt it moves the cursor. The click is matched against the regions of the
# model as drawn.
def clicked(app: State.Model, x: Int, y: Int) -> State.Model = clicked_on(app, Views.framed(app), x, y)

# A button down on the transcript may start a drag, so it acts when it goes up; on anything else it acts at once.
def pressed(app: State.Model, x: Int, y: Int) -> State.Model
  frame = Views.located(app)
  case Screen.hit(frame, x, y)
    Screen.Hit.Entry(index) ->
      press = Select.Press(cell: Select.cell_at(frame.top, x, Screen.below_banner(frame, y)), entry: index)
      app.with(pressed: some(press), selection: none)
    _ -> clicked_on(app.with(selection: none, pressed: none), frame, x, y)
  end
end

# The button moves down: the cells from where it went down to this one are selected, the rows of the transcript that
# are on the screen at most.
def dragged(app: State.Model, x: Int, y: Int) -> State.Model
  frame = Views.located(app)
  case app.pressed
    some(press) if not frame.transcript.empty? ->
      row = [[Screen.below_banner(frame, y), 0].max.unwrap!, frame.transcript.size - 1].min.unwrap!
      head = Select.cell_at(frame.top, x, row)
      return app if head == press.cell and app.selection.none?

      app.with(selection: some(Select.Selection(anchor: press.cell, head: head)))
    _ -> app
  end
end

# The button goes up: a drag copies what it selected; with no drag it was a click, or the second of a double click.
def released(app: State.Model) -> State.Model
  case app.pressed
    some(press) ->
      done = app.with(pressed: none)
      return Selecting.copied(done) if done.selection.some?

      return Selecting.double(done, press.cell) if Selecting.double?(done, press.cell)

      toggled = done.with(click: some(Select.Click(cell: press.cell, at_ms: app.now, toggled: press.entry)))
      return toggled if press.entry < 0

      toggled.with(entries: Transcript.toggle(app.entries, press.entry, State.folds(app)))
    none -> app
  end
end

def clicked_on(app: State.Model, frame: Screen.Frame, x: Int, y: Int) -> State.Model
  case Screen.hit(frame, x, y)
    Screen.Hit.Entry(index) -> app.with(entries: Transcript.toggle(app.entries, index, State.folds(app)))
    Screen.Hit.Key(event) -> on_key(app, event)
    Screen.Hit.Banner -> app.with(banner: [])
    Screen.Hit.Prompt(column, row) ->
      app.with(cursor: Prompt.index_at(app.prompt, State.cursor(app), frame.width, frame.height, column, row))
    Screen.Hit.Nothing -> app
  end
end

def send(app: State.Model) -> State.Model
  typed_text = app.prompt.strip
  return app if typed_text == ""

  text = Turn.expanded(app, typed_text)
  base = app.with(history: Turn.remembered(app.history, text), recall: none, cursor: 0, mention_closed: none)
  secret_line = ["/login", "/logout"].any? { |name| typed_text.start_with?(name) }
  if secret_line
    # A key typed on a `/login` or `/logout` line by mistake is not kept: not remembered, its pastes dropped.
    base = base.with(history: app.history, pastes: [])
  end

  case Client.parse_command(typed_text)
    some(ok(command)) if not app.moving or local?(command) ->
      return Commands.on_command(base.with(prompt: "", scroll: 0), command)
    some(error(e)) if secret_line -> return State.noted(base.with(prompt: ""), e.message)
    some(error(e)) -> return State.noted(app, e.message)
    _ -> nil
  end

  return State.noted(app, "the session is moving: wait for it") if app.moving

  for request in State.option_list(Client.parse_shell(text))
    return Turn.shell_send(base.with(prompt: "", scroll: 0, pastes: []), request)
  end

  queued = base.with(prompt: "", scroll: 0, outbox: app.outbox.push(text), pastes: [])
  return queued if not app.outbox.empty?

  Turn.sending(queued, text)
end

# A command that does not touch the session, which goes on while it moves.
def local?(command: Client.Command) -> Bool
  case command
    Client.Command.Quit, Client.Command.Help, Client.Command.Shortcuts, Client.Command.Cost -> true
    Client.Command.Login(_), Client.Command.Logout(_) -> true
    _ -> false
  end
end
