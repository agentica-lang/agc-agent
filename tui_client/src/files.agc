## The lists under the editor and the keys that pick from them: the files of the session's folder for `@`, the
## commands for `/`, and the arguments of `/model`, `/resume`, `/tree`, `/fork`, `/thinking` and `/profile`, read from
## the server.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import Input from "input"
import Picker from "picker"
import Prompt from "prompt"
import Screen from "screen"
import State from "state"

## The files of the session's folder come from the server each time an `@` is typed; the list shows the ones read last.
def read_files(app: State.Model) -> State.Model
  backend = app.backend
  id = app.id
  opened = app.opened
  State.effect(app.with(reading_files: true), TUI.Cmd.Run(-> { State.Msg.Files(opened, backend.files.call(id)) }))
end

def files_read(app: State.Model, result: Result[Protocol.FileList]) -> State.Model
  case result
    ok(list) -> listed(app, list)
    error(e) if e.kind == Client.KIND_TIMEOUT ->
      State.noted(app.with(files_again_at: app.now + FILES_AGAIN_MS), "error: the files were not listed: #{e.message}")
    error(e) -> State.noted(app, "error: the files were not listed: #{e.message}")
  end
end

# A cut list and a note of the server are said once, until they change.
def listed(app: State.Model, list: Protocol.FileList) -> State.Model
  read = app.with(files: some(list.files), files_cut: list.truncated, files_note: list.note)
  if list.note != "" and list.note != app.files_note
    read = State.noted(read, "@ files: #{Client.printable(list.note)}")
  end

  return read if not list.truncated or app.files_cut

  State.noted(read, "the @ list is cut: the folder has more files than it reads")
end

## When the argument of a command starts, its choices are asked of the server once; they go when the command does.
## A read that failed is not asked again until the command changes.
def asked(app: State.Model) -> State.Model
  word = Input.argument_word(app.prompt, State.cursor(app))
  command = word.map { |w| w.command }
  kept = app
  if app.arguments.some? and not app.prompt.start_with?("#{app.arguments.unwrap!.command} ")
    kept = kept.with(arguments: none)
  end

  if app.arguments_failed.some? and not app.prompt.start_with?("#{app.arguments_failed.unwrap!} ")
    kept = kept.with(arguments_failed: none)
  end

  for wanted in State.option_list(command)
    loaded = kept.arguments.map { |a| a.command } == command
    return kept if wanted == "/thinking" or kept.id == "" or kept.reading_arguments or loaded
    return kept if kept.arguments_failed == command

    return read_arguments(kept, wanted)
  end

  kept
end

## The reply of a read: kept while its command is still in the prompt (a late `/tree` list leaves the listed tree
## alone), then the command in the prompt now is asked for.
def arguments_read(app: State.Model, command: String, result: Result[Input.Arguments]) -> State.Model
  current = Input.argument_word(app.prompt, State.cursor(app)).map { |w| w.command }
  return asked(app) if current != some(command)

  case result
    ok(listed) if listed.tree.some? -> asked(fresh_list(app).with(arguments: some(listed), listed: listed.tree))
    ok(listed) -> asked(fresh_list(app).with(arguments: some(listed)))
    error(e) ->
      failed = app.with(arguments_failed: some(command))
      State.noted(failed, "error: the choices of #{command} were not listed: #{Client.printable(e.message)}")
  end
end

## The list under the editor: the commands while the prompt is `/` and part of a name that some command starts with,
## else the choices of a command's argument, else the files while the cursor ends an `@` word and the files are read;
## none once Esc closed it.
def mention_list(app: State.Model) -> Optional[Input.Mention]
  # A prompt Up recalled shows none: Up and Down go on through the history. Nor does a list without room, or under an
  # approval, which takes the panel.
  return none if app.picker.some? or app.recall.some? or not app.approvals.pending.empty? or list_room(app) <= 0

  found = Input.command_word(app.prompt, State.cursor(app))
  if found.none? or mention_choices(app, found.unwrap!).empty?
    found = Input.argument_word(app.prompt, State.cursor(app))
  end

  if found.none? or mention_choices(app, found.unwrap!).empty?
    found = none
    if app.files.some?
      found = Input.mention(app.prompt, State.cursor(app))
    end
  end

  return none if found.none? or app.mention_closed == some(found.unwrap!.start)

  found
end

def mention_key?(app: State.Model, found: Input.Mention, event: TUI.Event) -> Bool
  case event
    TUI.Event.Key(TUI.Key.Tab, _) -> true
    TUI.Event.Key(TUI.Key.Up, _) -> true
    TUI.Event.Key(TUI.Key.Down, _) -> true
    TUI.Event.Key(TUI.Key.Escape, _) -> true
    TUI.Event.Key(TUI.Key.Enter, mods) -> not mods.alt and completes?(app, found)
    _ -> false
  end
end

## Enter on the list of a command's argument runs the command with the row moved to, so a pick there is the one that
## counts and no picker opens after it. Untouched, the line is sent as typed: the command alone opens its picker.
def runs_choice?(app: State.Model, found: Input.Mention, event: TUI.Event) -> Bool
  case event
    TUI.Event.Key(TUI.Key.Enter, mods) if not mods.alt and found.source == Input.Source.Arguments ->
      app.mention_moved and not mention_choices(app, found).empty?
    _ -> false
  end
end

## The selected row of the list: the one moved to; before a move, the session's model or thinking level when the list
## of `/model` or `/thinking` has it, else the first.
def selected_row(app: State.Model, found: Input.Mention, choices: List[Input.Choice]) -> Int
  moved = [[app.mention_selected, choices.size - 1].min.unwrap!, 0].max.unwrap!
  return moved if app.mention_moved or found.source != Input.Source.Arguments

  current = case found.command
    "/model" -> Client.printable(app.serving)
    "/thinking" -> app.effort.unwrap_or(Protocol.EFFORT_DEFAULT)
    _ -> ""
  end

  choices.map { |c| c.value }.index(current).unwrap_or(moved)
end

def mention_choices(app: State.Model, found: Input.Mention) -> List[Input.Choice]
  case found.source
    Input.Source.Commands -> Input.commands(Client.listed() + app.custom, found.query)
    Input.Source.Files ->
      Input.matches(app.files.unwrap_or([]), found.query).map { |p|
        Input.Choice(value: p, label: Client.printable(p))
      }
    Input.Source.Arguments -> Input.argument_matches(argument_choices(app, found.command), found.query)
  end
end

## Tab, or Enter on part of a command name, puts the selected choice in place of the word; Up and Down move, Esc closes
## the list.
def on_mention_key(app: State.Model, found: Input.Mention, event: TUI.Event) -> State.Model
  choices = mention_choices(app, found)
  selected = selected_row(app, found, choices)
  case event
    TUI.Event.Key(TUI.Key.Up, _) -> selected_choice(app, [selected - 1, 0].max.unwrap!, choices.size)
    TUI.Event.Key(TUI.Key.Down, _) -> selected_choice(app, [selected + 1, choices.size - 1].min.unwrap!, choices.size)
    TUI.Event.Key(TUI.Key.Escape, _) -> app.with(mention_closed: some(found.start))
    _ if choices.empty? -> app
    _ ->
      at = State.cursor(app)
      text = Input.completed(app.prompt, at, found, choices[selected].value)
      app.with(
        prompt: text,
        cursor: at + text.length - app.prompt.length,
        mention_selected: 0,
        mention_top: 0,
        mention_moved: false,
      )
  end
end

private

# How long `@` waits to ask the server again after a read of the files timed out.
FILES_AGAIN_MS = 10_000

# The choices of the argument of `command`: the thinking levels, or what the server listed for it.
def argument_choices(app: State.Model, command: String) -> List[Input.Choice]
  if command == "/thinking"
    return (Protocol.EFFORTS + [Protocol.EFFORT_DEFAULT]).map { |level| Input.Choice(value: level, label: level) }
  end

  for listed in State.option_list(app.arguments)
    return listed.choices if listed.command == command
  end

  []
end

def read_arguments(app: State.Model, command: String) -> State.Model
  backend = app.backend
  id = app.id
  opened = app.opened
  now_s = app.clock_s
  serving = app.serving
  read = TUI.Cmd.Run(-> { State.Msg.Arguments(opened, command, listing(backend, id, command, now_s, serving)) })
  State.effect(app.with(reading_arguments: true), read)
end

# The choices of a command's argument from the server: `provider/model` pairs, profiles by name, sessions by id, or
# the messages of the tree by number. Each value and row has its control characters as spaces, as the prompt and the
# list show them.
def listing(
  backend: Client.Backend,
  id: String,
  command: String,
  now_s: Int,
  serving: String,
) -> Result[Input.Arguments]
  case command
    "/model" ->
      pairs = Picker.models(try backend.list_providers.call(), serving).models
      ok(Input.Arguments(command: command, choices: pairs.map { |pair| Input.Choice(value: pair, label: pair) }))
    "/profile" ->
      listed = (try backend.list_profiles.call(id)).profiles
      lines = Client.profile_listing(Protocol.ProfileList(profiles: listed), "")
      choices = (0...listed.size).to_a.map { |i|
        Input.Choice(value: Client.printable(listed[i].name), label: lines[i].strip)
      }

      ok(Input.Arguments(command: command, choices: choices))
    "/resume" ->
      sessions = (try backend.list_sessions.call()).sessions
      shown = Picker.shown(Picker.Picker(sessions: sessions), now_s)
      choices = shown.map { |c| Input.Choice(value: Client.printable(c.key), label: c.text) }
      ok(Input.Arguments(command: command, choices: choices))
    _ ->
      tree = try backend.tree.call(id)
      shown = Picker.shown(Picker.Picker(tree: Client.tree_rows(tree), kind: Picker.Kind.Fork))
      numbered = (0...shown.size).to_a.map { |i| Input.Choice(value: "#{i + 1}", label: shown[i].text) }

      ok(Input.Arguments(command: command, choices: numbered, tree: some(tree)))
  end
end

# Enter on part of a command's name completes it as Tab does; on a whole name it runs the command, and after `/` alone
# or under the file list it sends the prompt.
def completes?(app: State.Model, found: Input.Mention) -> Bool
  return false if found.source != Input.Source.Commands or found.query == ""

  word = "/#{found.query}"
  not mention_choices(app, found).any? { |choice| choice.value.strip == word }
end

def fresh_list(app: State.Model) -> State.Model = app.with(mention_selected: 0, mention_top: 0, mention_moved: false)

# The rows under the editor that the list may take.
def list_room(app: State.Model) -> Int
  Screen.panel_room(app.height, Prompt.view(app.prompt, State.cursor(app), app.width, app.height).rows.size)
end

def selected_choice(app: State.Model, selected: Int, size: Int) -> State.Model
  top = Input.window(app.mention_top, selected, list_room(app), size)
  app.with(mention_selected: selected, mention_top: top, mention_moved: true)
end
