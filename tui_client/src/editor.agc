## Ctrl+G: the prompt in the user's editor (`$VISUAL`, else `$EDITOR`), on the terminal the screen gives back meanwhile.
## The text goes through a file in a folder of the private state folder, removed afterwards.

import Client from "pkg/client/client"
import TUI from "pkg/tui/tui"
import Input from "input"
import State from "state"
import Terminal from "terminal"

## The folders of edits under the private state folder `state_dir`, each client's named by its pid. What a client that
## was killed left there goes once it is a day old (at `now_s`): a younger folder may be another client's edit.
def folder_of(state_dir: String, now_s: Int) -> String
  edits = "#{state_dir}/edits"
  _ = Dir.mkdir_private(edits, FILE_MS)
  names: List[String] = Dir.list(edits, FILE_MS).unwrap_or([])
  for name in names
    old = case File.stat("#{edits}/#{name}", FILE_MS)
      ok(info) -> info.modified_seconds < now_s - LEFT_S
      error(_) -> true
    end

    if old
      _ = Path.remove("#{edits}/#{name}", FILE_MS)
    end
  end

  edits
end

## Opens the prompt in the editor, or says how to name one.
def opened(app: State.Model) -> State.Model
  return State.noted(app, "set $VISUAL or $EDITOR to edit the prompt in an editor") if app.editor == ""
  return State.noted(app, "error: no private folder to edit the prompt in") if app.edits == ""

  editor = app.editor
  folder = "#{app.edits}/#{System.pid()}"
  prompt = Input.expanded(app.prompt, app.pastes)
  State.effect(app.with(editing: true), TUI.Cmd.Suspend(-> { State.Msg.Edited(edited(editor, folder, prompt)) }))
end

## The text the editor saved becomes the prompt, without the line break editors add at its end; the pastes are in it.
def closed(app: State.Model, result: Result[String]) -> State.Model
  done = app.with(editing: false)
  # The terminal library turns the mouse reporting on again when the editor ends: `/mouse` off means it stays off.
  if not app.mouse
    app.write.call(Terminal.mouse(false))
  end

  case result
    ok(text) ->
      prompt = text
      if prompt.end_with?("\n")
        prompt = prompt.slice(0, prompt.length - 1)
      end

      done.with(prompt: prompt, cursor: prompt.length, goal_column: none, prefilled: false, pastes: [])
    error(e) -> State.noted(done, "error: the prompt was not edited: #{Client.printable(e.message)}")
  end
end

private

WAIT_MS = 60_000
LEFT_S = 86_400
FILE_MS = 5000

# The editor runs through the shell, as git runs it, so that `$EDITOR` may hold arguments. With no signal keys, a
# Ctrl+C is a key for the editor and never a signal for the client, which owns the terminal.
def edited(editor: String, folder: String, text: String) -> Result[String]
  _ = Path.remove(folder, FILE_MS)
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
  while timed_out?(code)
    code = Process.wait(running, WAIT_MS)
  end

  exit = try code
  return error("the editor exited with #{exit}") if exit != 0

  File.read_text(path, FILE_MS)
end

def timed_out?(code: Result[Int]) -> Bool
  case code
    ok(_) -> false
    error(e) -> e.kind == "process.timeout"
  end
end
