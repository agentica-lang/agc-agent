import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import App from "../src/app"
import Args from "../src/args"
import Picker from "../src/picker"

def test_keys_edit_the_prompt_and_the_view_draws_it() -> Result[Void]
  model = model_of(30, 6)
  for char in ["h", "i"]
    model = App.update(model, App.Msg.Key(TUI.Event.Char(char, TUI.Mods()))).model
  end

  try Test.eq(model.prompt, "hi")
  try Test.eq(rows(model).drop(2).take(3), ["─" * 30, "hi", "─" * 30])
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

# Enter sends from a command; the stream waits until the reply, so the message is drawn before its answer, and a
# message that was not sent goes back to the prompt.
def test_a_message_is_sent_by_a_command_and_the_stream_waits_for_its_reply() -> Result[Void]
  feed: Channel[Client.Item] = Channel.new(4)
  model = model_of(30, 8).with(id: "s1", generation: 1, feed: some(feed), prompt: "hi")
  sending = App.update(model, enter())
  try Test.eq([sending.model.prompt, "#{sending.model.outbox}", "#{sending.cmds.size}"], ["", "[\"hi\"]", "1"])
  text = Protocol.Event.TextDelta(Protocol.TextDelta(text: "hello"))
  held = App.update(sending.model, App.Msg.Stream(1, [Client.Item.Event(some(1), text)]))
  try Test.eq([held.model.entries.size, held.cmds.size], [0, 0])
  replied = App.update(held.model, App.Msg.Sent(0, "hi", ok(Protocol.MessageAccepted(turn_id: "t1"))))
  try Test.eq(replied.model.entries.map { |entry| entry.text }, ["hi", "hello"])
  try Test.eq([replied.model.turn, replied.model.held.empty?], [true, true])
  try Test.eq(replied.cmds.size, 1)
  failed = App.update(sending.model, App.Msg.Sent(0, "hi", error("down", kind: "client.unreachable")))
  try Test.eq(failed.model.prompt, "hi")
  stale = App.update(sending.model.with(opened: 1), App.Msg.Sent(0, "hi", ok(Protocol.MessageAccepted(turn_id: "t1"))))
  Test.eq(stale.model.entries.size, 0)
end

# Messages typed one after another go one at a time, in order; Esc before the turn started stops it once it has.
def test_messages_go_in_order_and_an_early_stop_waits_for_the_turn() -> Result[Void]
  model = model_of(30, 8).with(id: "s1")
  steps: List[TUI.Step[App.Model, App.Msg]] = []
  for text in ["one", "two", "three"]
    step = App.update(model.with(prompt: text), enter())
    model = step.model
    steps = steps.push(step)
  end

  try Test.eq(steps.map { |step| step.cmds.size }, [1, 0, 0])
  try Test.eq(model.outbox, ["one", "two", "three"])
  stopping = App.update(model, App.Msg.Key(TUI.Event.Key(TUI.Key.Escape, TUI.Mods()))).model
  try Test.eq([stopping.stop_wanted, stopping.stopping], [true, false])
  replied = App.update(stopping, App.Msg.Sent(0, "one", ok(Protocol.MessageAccepted(turn_id: "t1"))))
  try Test.eq([replied.model.turn, replied.model.stopping, replied.model.stop_wanted], [true, true, false])
  try Test.eq(replied.model.outbox, ["two", "three"])
  # The next send (to a server that is not there) is of "two".
  sent = replied.cmds.flat_map { |cmd| run(cmd) }.select { |msg| sent_text(msg) == "two" }
  Test.eq(sent.size, 1)
end

# Shift+Tab sets the next thinking level, one change on its way at a time: the reply sends the latest level wanted,
# one note says where it settled, and a failure with nothing newer goes back to the server's level.
def test_shift_tab_sends_one_level_at_a_time() -> Result[Void]
  model = model_of(30, 6)
  steps: List[Int] = []
  for _ in 0...3
    step = App.update(model, back_tab())
    model = step.model
    steps = steps.push(step.cmds.size)
  end

  try Test.eq(steps, [1, 0, 0])
  try Test.eq([model.effort, model.level_sending], [some("high"), some("low")])

  first = App.update(model, App.Msg.Leveled(ok()))
  try Test.eq(
    [first.model.confirmed, first.model.level_sending, some("#{first.cmds.size}")],
    [some("low"), some("high"), some("1")],
  )

  settled = App.update(first.model, App.Msg.Leveled(ok()))
  try Test.eq([settled.model.confirmed, settled.model.level_sending], [some("high"), none])
  try Test.eq(settled.model.entries.map { |entry| entry.text }, ["thinking high from the next turn"])
  failed = App.update(
    App.update(settled.model, back_tab()).model,
    App.Msg.Leveled(error("down", kind: "client.unreachable")),
  )

  Test.eq([failed.model.effort, failed.model.level_sending], [some("high"), none])
end

# A running turn spins in the top rule.
def test_a_turn_spins_in_the_rule() -> Result[Void]
  turn = model_of(30, 6).with(turn: true)
  try Test.eq(App.subscriptions(turn).size, 2)
  spun = App.update(turn, App.Msg.Spin).model
  Test.eq(rows(spun)[2].slice(0, 12), "── ⠙ Working")
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
  Test.assert(rows(step.model).include?("one two three"), "the note is drawn")
end

# The status line shows the session's provider and model; the `/model` picker draws its pairs, and Esc closes it.
def test_the_status_shows_the_model_and_the_model_picker_closes() -> Result[Void]
  list = Protocol.ProviderList(
    provider: "local",
    providers: [Protocol.ProviderInfo(name: "fireworks", api: "openai", models: ["k2"])],
  )

  model = model_of(100, 12).with(serving: "local/qwen")
  try Test.assert(rows(model).any? { |row| row.include?("(local) qwen") }, "the status shows the model")
  picking = model.with(picker: some(Picker.models(list, "local/qwen")))
  shown = rows(picking)
  try Test.assert(shown.any? { |row| row.include?("pick a model (1 of 1)") }, "the picker is drawn")
  try Test.assert(shown.any? { |row| row.include?("fireworks/k2") }, "the pair is drawn")
  closed = App.update(picking, App.Msg.Key(TUI.Event.Key(TUI.Key.Escape, TUI.Mods()))).model
  Test.eq(closed.picker.none?, true)
end

# The /tree picker lists the messages and answers of every branch; Enter on one asks for the branch by a command, not
# while a turn runs. The session the server moved to is opened, with the message it went back before in the prompt.
def test_the_tree_picker_moves_the_session_and_fills_the_prompt() -> Result[Void]
  nodes = [
    Protocol.TreeNode(id: 1, text: "One.", answer: "A1", last: 7, active: true),
    Protocol.TreeNode(id: 8, parent: some(1), text: "Two.", answer: "A2", last: 14),
    Protocol.TreeNode(id: 15, parent: some(1), text: "Three.", last: 20, active: true),
  ]

  tree = Client.tree_rows(Protocol.SessionTree(nodes: nodes))
  model = model_of(50, 12).with(id: "s1", picker: some(Picker.Picker(tree: tree, kind: Picker.Kind.Tree)))
  drawn = rows(model)
  try Test.assert(drawn.include?("› * One."), "the first message is selected: #{drawn}")
  try Test.assert(drawn.include?("→ A2"), "an answer is a row: #{drawn}")
  down = App.update(model, App.Msg.Key(TUI.Event.Key(TUI.Key.Down, TUI.Mods()))).model
  busy = App.update(down.with(turn: true), enter())
  try Test.eq([busy.cmds.size.to_s, busy.model.picker.some?.to_s], ["0", "false"])
  picked = App.update(down, enter())
  try Test.eq([picked.cmds.size.to_s, picked.model.picker.some?.to_s], ["1", "false"])
  try Test.assert(picked.cmds.flat_map { |cmd| run(cmd) }.all? { |msg| moved?(msg) }, "the branch is asked")
  branched = Protocol.Branched(id: "s1", text: "Two.")
  back = App.update(model.with(picker: none), App.Msg.Moved(ok(branched))).model
  try Test.eq([back.prompt, back.cursor.to_s], ["Two.", "4"])
  failed = App.update(model.with(picker: none), App.Msg.Moved(error("busy", kind: "session.busy"))).model
  Test.eq([failed.prompt, failed.entries.last.text], ["", "error: busy"])
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

def back_tab() -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.BackTab, TUI.Mods()))

def enter() -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.Enter, TUI.Mods()))

def run(cmd: TUI.Cmd[App.Msg]) -> List[App.Msg]
  case cmd
    TUI.Cmd.Run(work) -> [work.call()]
    _ -> []
  end
end

def sent_text(msg: App.Msg) -> String
  case msg
    App.Msg.Sent(_, text, _) -> text
    _ -> ""
  end
end

def quit?(cmd: TUI.Cmd[App.Msg]) -> Bool
  case cmd
    TUI.Cmd.Quit -> true
    _ -> false
  end
end

def moved?(msg: App.Msg) -> Bool
  case msg
    App.Msg.Moved(_) -> true
    _ -> false
  end
end
