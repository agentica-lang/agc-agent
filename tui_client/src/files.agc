## The `@` list: the files of the session's folder, read from the server, and the keys that pick one.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import Input from "input"
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
    ok(list) if list.truncated and not app.files_cut ->
      State.noted(
        app.with(files: some(list.files), files_cut: true),
        "the @ list is cut: the folder has more files than it reads",
      )
    ok(list) -> app.with(files: some(list.files), files_cut: list.truncated)
    error(e) if e.kind == Client.KIND_TIMEOUT ->
      State.noted(app.with(files_again_at: app.now + FILES_AGAIN_MS), "error: the files were not listed: #{e.message}")
    error(e) -> State.noted(app, "error: the files were not listed: #{e.message}")
  end
end

## The list under the editor: the commands while the prompt is `/` and part of a name that some command starts with,
## else the files while the cursor ends an `@` word and the files are read; none once Esc closed it.
def mention_list(app: State.Model) -> Optional[Input.Mention]
  # A prompt Up recalled shows none: Up and Down go on through the history. Nor does a list without room, or under an
  # approval, which takes the panel.
  return none if app.picker.some? or app.recall.some? or not app.approvals.pending.empty? or list_room(app) <= 0

  found = Input.command_word(app.prompt, State.cursor(app))
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

def mention_choices(app: State.Model, found: Input.Mention) -> List[Input.Choice]
  case found.source
    Input.Source.Commands -> Input.commands(Client.listed(), found.query)
    Input.Source.Files ->
      Input.matches(app.files.unwrap_or([]), found.query).map { |p|
        Input.Choice(value: p, label: Client.printable(p))
      }
  end
end

## Tab, or Enter on part of a command name, puts the selected choice in place of the word; Up and Down move, Esc closes
## the list.
def on_mention_key(app: State.Model, found: Input.Mention, event: TUI.Event) -> State.Model
  choices = mention_choices(app, found)
  selected = [[app.mention_selected, choices.size - 1].min.unwrap!, 0].max.unwrap!
  case event
    TUI.Event.Key(TUI.Key.Up, _) -> selected_choice(app, [selected - 1, 0].max.unwrap!, choices.size)
    TUI.Event.Key(TUI.Key.Down, _) -> selected_choice(app, [selected + 1, choices.size - 1].min.unwrap!, choices.size)
    TUI.Event.Key(TUI.Key.Escape, _) -> app.with(mention_closed: some(found.start))
    _ if choices.empty? -> app
    _ ->
      at = State.cursor(app)
      text = Input.completed(app.prompt, at, found, choices[selected].value)
      app.with(prompt: text, cursor: at + text.length - app.prompt.length, mention_selected: 0, mention_top: 0)
  end
end

private

# How long `@` waits to ask the server again after a read of the files timed out.
FILES_AGAIN_MS = 10_000

# Enter on part of a command's name completes it as Tab does; on a whole name it runs the command, and after `/` alone
# or under the file list it sends the prompt.
def completes?(app: State.Model, found: Input.Mention) -> Bool
  return false if found.source != Input.Source.Commands or found.query == ""

  word = "/#{found.query}"
  not mention_choices(app, found).any? { |choice| choice.value.strip == word }
end

# The rows under the editor that the list may take.
def list_room(app: State.Model) -> Int
  Screen.panel_room(app.height, Prompt.view(app.prompt, State.cursor(app), app.width, app.height).rows.size)
end

def selected_choice(app: State.Model, selected: Int, size: Int) -> State.Model
  top = Input.window(app.mention_top, selected, list_room(app), size)
  app.with(mention_selected: selected, mention_top: top)
end
