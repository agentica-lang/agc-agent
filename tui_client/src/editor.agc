## Ctrl+G: the prompt in the user's editor (`$VISUAL`, else `$EDITOR`), on the terminal the screen gives back meanwhile.
## The text goes through a file in a folder only the user can enter, removed afterwards.

import Client from "pkg/client/client"
import TUI from "pkg/tui/tui"
import State from "state"

## Opens the prompt in the editor, or says how to name one.
def opened(app: State.Model) -> State.Model
  return State.noted(app, "set $VISUAL or $EDITOR to edit the prompt in an editor") if app.editor == ""

  editor = app.editor
  prompt = app.prompt
  State.effect(app.with(editing: true), TUI.Cmd.Suspend(-> { State.Msg.Edited(edited(editor, prompt)) }))
end

## The text the editor saved becomes the prompt, without the line break editors add at its end.
def closed(app: State.Model, result: Result[String]) -> State.Model
  done = app.with(editing: false)
  case result
    ok(text) ->
      prompt = text
      if prompt.end_with?("\n")
        prompt = prompt.slice(0, prompt.length - 1)
      end

      done.with(prompt: prompt, cursor: prompt.length, goal_column: none, prefilled: false)
    error(e) -> State.noted(done, "error: the prompt was not edited: #{Client.printable(e.message)}")
  end
end

private

WAIT_MS = 60_000
FILE_MS = 5000

# The editor runs through the shell, as git runs it, so that `$EDITOR` may hold arguments. With no signal keys,
# a Ctrl+C
# is a key for the editor and never a signal for the client, which owns the terminal.
def edited(editor: String, text: String) -> Result[String]
  folder = "#{System.env("TMPDIR").unwrap_or("/tmp")}/finn-edit-#{Random.int(0, 999_999_999)}"
  try Dir.mkdir_private(folder, FILE_MS)
  result = in_folder(editor, "#{folder}/prompt.md", text)
  _ = Path.remove(folder, FILE_MS)
  result
end

def in_folder(editor: String, path: String, text: String) -> Result[String]
  written: Result[Void] = File.open(path, "create_private", FILE_MS) do |file| File.write(file, text, FILE_MS) end

  try written
  running = try Process.spawn_group("sh", ["-c", "stty -isig 2>/dev/null; #{editor} \"$@\"", editor, path])
  code = Process.wait(running, WAIT_MS)
  while not code.ok?
    code = Process.wait(running, WAIT_MS)
  end

  exit = code.unwrap!
  return error("the editor exited with #{exit}") if exit != 0

  File.read_text(path, FILE_MS)
end
