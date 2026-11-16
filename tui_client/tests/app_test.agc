import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import App from "../src/app"
import Args from "../src/args"

def test_keys_edit_the_prompt_and_the_view_draws_it() -> Result[Void]
  model = model_of(30, 6)
  for char in ["h", "i"]
    model = App.update(model, App.Msg.Key(TUI.Event.Char(char, TUI.Mods()))).model
  end

  try Test.eq(model.prompt, "hi")
  try Test.eq(rows(model).last, "> hi")
  resized = App.update(model, App.Msg.Key(TUI.Event.Resize(20, 4))).model
  try Test.eq([resized.width, resized.height], [20, 4])
  Test.eq(rows(resized).size, 4)
end

# The items of the current stream are drawn and the stream is read again; those of an old stream are dropped.
def test_the_stream_of_the_current_generation_is_drawn_and_read_again() -> Result[Void]
  feed: Channel[Client.Item] = Channel.new(4)
  model = model_of(30, 6).with(generation: 2, feed: some(feed))
  text = Protocol.Event.TextDelta(Protocol.TextDelta(text: "hello"))
  step = App.update(model, App.Msg.Stream(2, [Client.Item.Event(some(1), text)]))
  try Test.eq(step.model.entries.map { |entry| entry.text }, ["hello"])
  try Test.eq(step.cmds.size, 1)
  try Test.assert(rows(step.model).include?("hello"), "the answer is drawn")
  old = App.update(model, App.Msg.Stream(1, [Client.Item.Event(some(1), text)]))
  try Test.eq(old.model.entries.size, 0)
  Test.eq(old.cmds.size, 0)
end

def test_ctrl_c_and_a_signal_quit_with_their_codes() -> Result[Void]
  model = model_of(30, 6)
  quit = App.update(model, App.Msg.Key(TUI.Event.Key(TUI.Key.Ctrl("c"), TUI.Mods())))
  try Test.eq(quit.model.exit, some(0))
  try Test.assert(quit.cmds.any? { |cmd| quit?(cmd) }, "a quit command")
  signalled = App.update(model, App.Msg.Signal(some(System.Signal.Term)))
  Test.eq(signalled.model.exit, some(143))
end

# A key cuts the rows of every entry once; the view then reads them from the entries.
def test_an_update_keeps_the_wrapped_rows_of_the_entries() -> Result[Void]
  model = model_of(30, 6).with(entries: [])
  step = App.update(model, App.Msg.Note("one two three"))
  try Test.assert(step.model.entries.all? { |entry| entry.wrapped.some? }, "every entry is wrapped")
  Test.assert(rows(step.model).include?("· one two three"), "the note is drawn")
end

def model_of(width: Int, height: Int) -> App.Model
  options = Args.Options(
    state_dir: none,
    server_command: none,
    session: none,
    cwd: none,
    model: none,
    api: none,
    thinking: false,
  )

  App.seed(Client.Server(url: "http://127.0.0.1:1", token: ""), options, Channel.new(1), width, height)
end

def rows(model: App.Model) -> List[String]
  cells = TUI.layout(App.view(model), model.width, model.height)
  (0...model.height).to_a.map do |y| cells.select { |cell| cell.y == y }.map { |cell| cell.char }.join("").strip end
end

def quit?(cmd: TUI.Cmd[App.Msg]) -> Bool
  case cmd
    TUI.Cmd.Quit -> true
    _ -> false
  end
end
