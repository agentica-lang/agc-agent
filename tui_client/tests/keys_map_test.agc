# The `keys` of the config: a key in effect does what its action does, the old one does nothing, the hints and `/help`
# show the keys in effect, and `/reload` applies a change.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import App from "../src/app"
import Args from "../src/args"
import Markdown from "../src/markdown"
import Side from "../src/side"
import State from "../src/state"
import Transcript from "../src/transcript"

# The thinking level on F9 and the logs on Ctrl+L: those keys do their action, F2 and Ctrl+P do nothing; Alt+T works
# as a key of the config, and a swap of two actions works.
def test_a_key_of_the_config_does_its_action() -> Result[Void]
  moved = model_of().with(keys: Client.effective([setting("thinking_level", "f9"), setting("logs", "ctrl+l")]))
  try Test.eq(App.update(moved, f(9)).cmds.size, 1)
  try Test.eq(App.update(moved, f(2)).cmds.size, 0)
  try Test.eq(App.update(moved, f(2)).model.effort, none)
  try Test.eq(App.update(moved, f(9)).model.effort, some("low"))
  try Test.eq(App.update(moved, ctrl("l")).model.side.some?, true)
  try Test.eq(App.update(moved, ctrl("p")).model.side.none?, true)
  alt = model_of().with(keys: Client.effective([setting("thinking_level", "alt+t")]))
  try Test.eq(App.update(alt, alt_char("t")).model.effort, some("low"))
  try Test.eq(App.update(alt, alt_char("t")).model.prompt, "")
  swapped = model_of().with(
    keys: Client.effective([setting("thinking_level", "shift+tab"), setting("cycle_profile", "f2")]),
  )

  try Test.eq(App.update(swapped, back_tab()).model.effort, some("low"))
  Test.eq(App.update(swapped, f(2)).model.effort, none)
end

# PgUp moved to F7 and the focus to F3: F7 scrolls the panel of the log, PgUp does nothing, and the title of the panel
# says so.
def test_a_moved_page_key_scrolls_and_shows_in_the_panel_title() -> Result[Void]
  long = (0...60).to_a.map { |n| "line #{n}" }
  backend = Client.unreachable_backend().with(
    server_log: ->(_lines: Int) { ok(Protocol.ServerLog(lines: long, warnings: [], warning_count: 0)) },
  )

  keyed = model_of(120).with(
    backend: backend,
    keys: Client.effective([setting("page_up", "f7"), setting("side_focus", "f3")]),
    height: 14,
  )

  opened = App.update(keyed.with(prompt: "/logs 60", cursor: 8), enter()).model
  try Test.eq(opened.side.unwrap!.follow, true)
  try Test.eq(
    App.update(opened, App.Msg.Key(TUI.Event.Key(TUI.Key.PageUp, TUI.Mods()))).model.side.unwrap!.follow,
    true,
  )

  try Test.eq(App.update(opened, f(7)).model.side.unwrap!.follow, false)
  title = Side.rows(opened.side.unwrap!, 80, 8, true, opened.keys)[0].text
  Test.assert(title.include?("F7/PgDn scroll") and title.include?("F3 focus"), title)
end

# The hints, the keys of `/help` and the key of a hint of the side panel are the ones in effect.
def test_the_hints_and_the_help_show_the_keys_in_effect() -> Result[Void]
  model = model_of(160).with(
    id: "s1",
    keys: Client.effective([
      setting("thinking_level", "f9"),
      setting("logs", "ctrl+l"),
      setting("cycle_profile", "alt+m"),
    ]),
  )

  footer = rows(model).last
  try Test.assert(footer.include?("F9 thinking level") and footer.include?("Alt+M profile"), footer)
  try Test.assert(footer.include?("^L logs") and not footer.include?("⇧Tab") and not footer.include?("^P"), footer)
  helped = App.update(model.with(prompt: "/shortcuts", cursor: 10), enter()).model
  lines = helped.side.unwrap!.lines.join("\n")
  try Test.assert(
    lines.include?("Alt+M") and lines.include?("**F9**") and lines.include?("the next thinking level"),
    lines,
  )

  try Test.assert(lines.include?("Ctrl+L") and not lines.include?("Ctrl+P"), lines)
  folds = State.folds(
    model_of().with(keys: Client.effective([setting("show_thinking", "f9"), setting("show_tools", "f10")])),
  )

  try Test.eq([folds.thinking_key, folds.tools_key], ["F9", "F10"])
  folded = Transcript.lines([Transcript.Entry(kind: Transcript.Kind.Thinking, text: "x")], 40, folds)
  try Test.eq(Markdown.plain(folded[0].spans).include?("click or F9 shows it"), true)
  plain = model_of(160).with(id: "s1")
  try Test.assert(
    rows(plain).last.include?("⇧Tab profile") and rows(plain).last.include?("F2 thinking level"),
    rows(plain).last,
  )

  Test.assert(rows(plain).last.include?("^P logs"), rows(plain).last)
end

# `/shortcuts` is completed by Tab and opens the side panel with one row per key, named as the keys map sets it.
def test_shortcuts_opens_the_panel_with_the_keys_in_effect() -> Result[Void]
  model = model_of(160).with(id: "s1", keys: Client.effective([setting("logs", "ctrl+l")]))
  typed = model.with(prompt: "/shortc", cursor: 7)
  completed = App.update(typed, App.Msg.Key(TUI.Event.Key(TUI.Key.Tab, TUI.Mods()))).model
  try Test.eq(completed.prompt, "/shortcuts")
  opened = App.update(completed, enter()).model
  side = opened.side.unwrap!
  try Test.eq(side.title, "Shortcuts")
  try Test.assert(
    side.lines.any? { |line| line.include?("**Ctrl+L**") and line.include?("server log") },
    "#{side.lines}",
  )

  try Test.assert(not side.lines.any? { |line| line.include?("Ctrl+P") }, "the default key is gone: #{side.lines}")
  Test.assert(side.lines.any? { |line| line.include?("**/mcp: r**") }, "the panel keys: #{side.lines}")
end

# `/reload` reads the keys of the server's config again: the new ones apply, the report lists the entries that were not
# taken, and a key of the old config does nothing any more.
def test_a_reload_applies_the_keys() -> Result[Void]
  entries: Channel[List[Protocol.KeySetting]] = Channel.new(1)
  _ = entries.send([setting("logs", "f9")], 0)
  display = -> {
    no_keys: List[Protocol.KeySetting] = []
    now = entries.recv(0).unwrap_or(no_keys)
    _ = entries.send(now, 0)
    Client.Display(mouse: true, clipboard: Protocol.ClipboardSetting(), keys: some(now))
  }

  backend = backend().with(display: display, reload: -> { ok(Protocol.Reloaded(config: "reloaded")) })

  model = model_of().with(backend: backend, keys: Client.effective([setting("logs", "f9")]))
  try Test.eq(App.update(model, f(9)).model.side.some?, true)
  _ = entries.recv(0)
  _ = entries.send([setting("thinking_level", "f8"), setting("nothing", "f1")], 0)
  reloaded = App.update(model.with(prompt: "/reload", cursor: 7), enter()).model
  try Test.eq(reloaded.keys.warnings.size, 1)
  try Test.assert(
    reloaded.side.unwrap!.lines.any? { |line| line.include?("warning: keys: nothing") },
    "#{reloaded.side}",
  )

  closed = App.update(reloaded.with(side: none), f(9)).model
  try Test.eq(closed.side.none?, true)
  Test.eq(App.update(closed, f(8)).model.effort, some("low"))
end

# A server whose log has a line.
def backend() -> Client.Backend
  Client.unreachable_backend().with(
    server_log: ->(_lines: Int) { ok(Protocol.ServerLog(lines: ["log line"], warnings: [], warning_count: 0)) },
  )
end

def setting(action: String, key: String) -> Protocol.KeySetting = Protocol.KeySetting(action: action, key: key)

def model_of(width: Int = 100) -> App.Model
  options = Args.Options(
    state_dir: none,
    server_command: none,
    session: none,
    cwd: none,
    model: none,
    api: none,
    thinking: false,
  )

  App.seed(backend(), options, Channel.new(1), width, 20)
end

def rows(model: App.Model) -> List[String]
  cells = TUI.layout(App.view(model), model.width, model.height)
  (0...model.height).to_a.map do |y| cells.select { |cell| cell.y == y }.map { |cell| cell.char }.join("").strip end
end

def f(n: Int) -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.F(n), TUI.Mods()))

def ctrl(c: String) -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.Ctrl(c), TUI.Mods()))

def alt_char(c: String) -> App.Msg = App.Msg.Key(TUI.Event.Char(c, TUI.Mods(alt: true)))

def back_tab() -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.BackTab, TUI.Mods()))

def enter() -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.Enter, TUI.Mods()))
