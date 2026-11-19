## What the model does with a selection: the copy when the button goes up, and the word of a double click.

import TUI from "pkg/tui/tui"
import Clipboard from "clipboard"
import Select from "select"
import State from "state"
import Terminal from "terminal"
import Transcript from "transcript"

## Copies the selected text where the clipboard provider says and notes how: a program in a command (its end comes back
## as `Copied`), or the sequence at once. The note adds rows at the end of the transcript, which the cells (counted from
## its first row) do not feel.
def copied(app: State.Model) -> State.Model
  chosen = app.selection.unwrap!
  text = Select.text(chosen, Transcript.lines(app.entries, app.width, State.folds(app)))
  return app if text == ""

  case Clipboard.choose(app.clipboard, app.host)
    some(_) if text.bytesize > Clipboard.MAX_INPUT_BYTES -> too_large(app, text, Clipboard.MAX_INPUT_BYTES, "")
    some(method) ->
      run = app.run
      State.effect(
        app,
        TUI.Cmd.Run(
          -> {
            result = run.call(method.argv, Clipboard.input(method, text))
            State.Msg.Copied(text, method, result, Clipboard.checked(run, method, result))
          },
        ),
      )
    none -> sent(app, text, "")
  end
end

## The note of a program that ended: it copied, or it did not and the terminal is asked instead. tmux that copied with
## `set-clipboard off` has the text in its buffer only.
def finished(
  app: State.Model,
  text: String,
  method: Clipboard.Method,
  result: Result[String],
  checked: String,
) -> State.Model
  case result
    ok(_) if checked == "off" ->
      State.noted(app, "copied #{text.length} characters to the #{method.name} buffer only (set-clipboard is off)")
    ok(_) -> State.noted(app, "copied #{text.length} characters (#{method.name})")
    error(e) -> sent(app, text, "#{method.name} failed (#{e.message}); ")
  end
end

## `text` goes to the terminal as OSC 52. Nothing says that the terminal took it, so the note does not say "copied".
def sent(app: State.Model, text: String, why: String) -> State.Model
  return too_large(app, text, Clipboard.MAX_OSC52_BYTES, why) if text.bytesize > Clipboard.MAX_OSC52_BYTES

  app.write.call(Terminal.osc52(text))
  State.noted(app, "#{why}sent #{text.length} characters to the terminal (OSC 52)")
end

## Whether a click at `cell` is the second of a double click.
def double?(app: State.Model, cell: Select.Cell) -> Bool
  case app.click
    some(before) -> before.cell == cell and app.now - before.at_ms <= Select.DOUBLE_MS
    none -> false
  end
end

## The word at `cell` is selected and copied. The first click of the pair folded a block (a thinking block or a tool
## call): the second puts it back.
def double(app: State.Model, cell: Select.Cell) -> State.Model
  unfolded = app
  for before in State.option_list(app.click)
    if before.toggled >= 0
      unfolded = app.with(entries: Transcript.toggle(app.entries, before.toggled, State.folds(app)))
    end
  end

  lines = Transcript.lines(unfolded.entries, unfolded.width, State.folds(unfolded))
  case Select.word_at(lines, cell)
    some(word) -> copied(unfolded.with(selection: some(word), click: none))
    none -> unfolded.with(click: none)
  end
end

private

def too_large(app: State.Model, text: String, most: Int, why: String) -> State.Model
  State.noted(app, "#{why}selection too large to copy (#{text.bytesize} bytes, at most #{most})")
end
