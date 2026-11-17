import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import App from "../src/app"
import Approvals from "../src/approvals"
import Args from "../src/args"
import Picker from "../src/picker"
import Session from "../src/session"
import Transcript from "../src/transcript"

def test_keys_edit_the_prompt_and_the_view_draws_it() -> Result[Void]
  model = model_of(30, 6)
  for char in ["h", "i"]
    model = App.update(model, App.Msg.Key(TUI.Event.Char(char, TUI.Mods()))).model
  end

  try Test.eq(model.prompt, "hi")
  try Test.eq(rows(model).drop(1).take(3), ["─" * 30, "hi", "─" * 30])
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
  try Test.eq(
    [failed.model.prompt, failed.model.entries.last.text],
    ["hi", "error: the message was not sent: down: hi"],
  )

  late = App.update(sending.model, App.Msg.Sent(0, "hi", error("slow", kind: Client.KIND_TIMEOUT)))
  try Test.eq(late.model.entries.last.text, "error: the message may not have been sent (slow): hi")
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

# `/thinking LEVEL` and `/model NAME` change the session on the server, `/thinking` says its level, and `/compact`
# gives the outcome of the server's summary as a note.
def test_the_session_commands_change_the_session() -> Result[Void]
  session = Protocol.Session(
    id: "s1",
    cwd: ".",
    model: "other-model",
    last_event_id: 0,
    turn_id: none,
    turn_from_event_id: none,
    pending_approvals: [],
    history: [],
    effort: some("high"),
    provider: "p",
  )

  changes: Channel[Protocol.UpdateSession] = Channel.new(4)
  backend = Client.unreachable_backend().with(
    session: ->(_id: String) { ok(session) },
    update_session: ->(_id: String, change: Protocol.UpdateSession) {
      _ = changes.send(change, 0)
      ok()
    },
    list_providers: -> { ok(Protocol.ProviderList(provider: "p", providers: [])) },
    compact: ->(_id: String) { ok(true) },
  )

  model = model_of(80, 20).with(backend: backend, id: "s1")
  notes: List[String] = []
  for line in ["/thinking high", "/thinking", "/model other-model", "/thinking max"]
    model = App.update(model.with(prompt: line, cursor: line.size), enter()).model
    notes = notes.push(model.entries.last.text)
  end

  try Test.eq(
    notes,
    [
      "thinking high from the next turn",
      "thinking high",
      "model other-model from the next turn",
      "the thinking level is one of low, medium, high, default",
    ],
  )

  try Test.eq([model.prompt, model.serving], ["/thinking max", "p/other-model"])
  try Test.assert(model.effort == some("high"), "the level is high")
  try Test.eq([(try changes.recv(0)).effort, (try changes.recv(0)).model], [some("high"), some("other-model")])
  compacting = App.update(model.with(prompt: "/compact", cursor: 8), enter())
  try Test.eq(compacting.model.entries.last.text, "compacting the history")
  done = App.update(compacting.model, run(compacting.cmds[0])[0]).model
  try Test.eq(done.entries.last.text, "compacted")
  down = model.with(backend: backend.with(compact: ->(_id: String) { error("busy", kind: "session.busy") }))
  failing = App.update(down.with(prompt: "/compact", cursor: 8), enter())
  failed = App.update(failing.model, run(failing.cmds[0])[0]).model
  Test.eq(failed.entries.last.text, "error: busy")
end

# A running turn spins in the top rule.
def test_a_turn_spins_in_the_rule() -> Result[Void]
  turn = model_of(30, 6).with(turn: true)
  try Test.eq(App.subscriptions(turn).size, 2)
  spun = App.update(turn, App.Msg.Spin).model
  Test.eq(rows(spun)[1].slice(0, 12), "── ⠙ Working")
end

# `!cmd` goes to the shell route from a command and draws as a `$` line with its output, and a muted line when the
# model does not get it; Esc stops it. A refused command goes back to the prompt, one that may have run does not, and
# none goes while the session moves or as a follow-up.
# The model's todo list shows as a notice, one item a line.
def test_a_todo_list_is_drawn() -> Result[Void]
  model = model_of(40, 10).with(id: "s1", generation: 1)
  list = [
    Protocol.Todo(content: "Write the test", status: "completed"),
    Protocol.Todo(content: "Fix the bug", status: "in_progress"),
    Protocol.Todo(content: "Docs", status: "pending"),
  ]

  event = Protocol.Event.Todos(Protocol.Todos(todos: list))
  shown = rows(App.update(model, App.Msg.Stream(1, [Client.Item.Event(some(1), event)])).model)
  for row in ["[x] Write the test", "[>] Fix the bug", "[ ] Docs"]
    try Test.assert(shown.include?(row), "#{row} is drawn: #{shown}")
  end

  ok()
end

def test_a_bang_line_runs_a_shell_command() -> Result[Void]
  model = model_of(40, 10).with(id: "s1", generation: 1, prompt: "!echo one")
  sending = App.update(model, enter())
  try Test.eq([sending.model.prompt, "#{sending.model.outbox}", "#{sending.cmds.size}"], ["", "[]", "1"])
  started = Protocol.Event.ShellStarted(Protocol.ShellStarted(shell_id: "sh1", command: "echo one", context: true))
  running = App.update(sending.model, App.Msg.Stream(1, [Client.Item.Event(some(1), started)])).model
  try Test.eq([running.shell, App.subscriptions(running).size == 2], [true, true])
  try Test.assert(rows(running).include?("$ echo one"), "the command is drawn: #{rows(running)}")
  stopping = App.update(running, App.Msg.Key(TUI.Event.Key(TUI.Key.Escape, TUI.Mods())))
  try Test.eq([stopping.model.stopping, stopping.model.entries.last.text == "stopping the command"], [true, true])
  done = Protocol.ShellFinished(
    shell_id: "sh1",
    command: "echo one",
    context: true,
    ok: true,
    output: "one\n",
    duration_ms: 200,
  )

  finished = App.update(
    stopping.model,
    App.Msg.Stream(1, [Client.Item.Event(some(2), Protocol.Event.ShellFinished(done))]),
  )

  try Test.eq([finished.model.shell, finished.model.stopping], [false, false])
  try Test.assert(rows(finished.model).include?("one"), "the output is drawn: #{rows(finished.model)}")
  try Test.assert(not rows(finished.model).include?("not sent to the model"), "a ! output goes to the model")
  quiet = done.with(shell_id: "sh2", command: "true", context: false, output: "")
  silent = App.update(
    finished.model,
    App.Msg.Stream(1, [Client.Item.Event(some(3), Protocol.Event.ShellFinished(quiet))]),
  )

  shown = rows(silent.model)
  try Test.eq(
    [shown.include?("$ true"), shown.include?("true"), shown.include?("not sent to the model")],
    [true, false, true],
  )

  refused = App.update(model_of(40, 10), App.Msg.ShellSent("ls", error("a turn is running", kind: "session.busy")))
  try Test.eq(
    [refused.model.prompt, refused.model.entries.last.text],
    ["!ls", "the command did not run: a turn is running: ls"],
  )

  late = App.update(model_of(40, 10), App.Msg.ShellSent("ls", error("slow", kind: Client.KIND_TIMEOUT))).model
  try Test.eq([late.prompt, late.entries.last.text], ["", "the command may have run (slow): ls"])
  moving = App.update(model_of(40, 10).with(moving: true, prompt: "!ls"), enter())
  try Test.eq([moving.model.entries.last.text, "#{moving.cmds.size}"], ["the session is moving: wait for it", "0"])
  later = App.update(model_of(40, 10).with(turn: true, prompt: "!ls"), alt_enter())
  Test.eq(
    [later.model.prompt, "#{later.model.follow_ups}", later.model.entries.last.text],
    ["!ls", "[]", "a ! command runs between turns: send it once the turn ends"],
  )
end

# Ctrl+O shows or folds the output of every tool call, and says so.
def test_ctrl_o_folds_every_tool_output() -> Result[Void]
  shown = App.update(model_of(40, 8), App.Msg.Key(TUI.Event.Key(TUI.Key.Ctrl("o"), TUI.Mods()))).model
  try Test.eq([shown.tools, shown.entries.last.text == "tool output: shown"], [true, true])
  Test.eq(App.update(shown, App.Msg.Key(TUI.Event.Key(TUI.Key.Ctrl("o"), TUI.Mods()))).model.tools, false)
end

# Esc before the reply of a message that went into another client's turn stops that turn; a level reply after /new
# is dropped.
def test_an_early_stop_reaches_a_turn_of_another_client() -> Result[Void]
  model = model_of(30, 8).with(id: "s1", outbox: ["hi"], stop_wanted: true)
  queued = App.update(
    model,
    App.Msg.Sent(0, "hi", ok(Protocol.MessageAccepted(turn_id: "t9", message_id: some("t9.1")))),
  )

  try Test.eq([queued.model.stopping, queued.model.stop_wanted], [true, false])
  try Test.eq(queued.cmds.size, 1)
  # A stop that found its turn ended says so.
  late = App.update(queued.model, App.Msg.Stopped("turn", ok(false))).model
  try Test.eq([late.stopping.to_s, late.entries.last.text], ["false", "the turn had already ended"])
  command = App.update(queued.model, App.Msg.Stopped("command", ok(false))).model
  try Test.eq(command.entries.last.text, "the command had already ended")
  stray = App.update(model_of(30, 8), App.Msg.Leveled(ok()))
  Test.eq([stray.model.entries.size, stray.cmds.size], [0, 0])
end

# The server is checked again before the stream is read again: a newer version ends the client, else a new stream.
def test_a_recheck_reads_the_stream_again_or_ends_the_client() -> Result[Void]
  model = model_of(30, 8).with(id: "s1", generation: 3, last_event_id: 7)
  failed = App.update(model, App.Msg.Rechecked(3, error("another version", kind: "client.version")))
  try Test.eq([failed.model.failure, some("#{failed.cmds.size}")], [some("another version"), some("1")])
  try Test.eq(App.update(model, App.Msg.Rechecked(2, ok())).model.generation, 3)
  again = App.update(model, App.Msg.Rechecked(3, ok())).model
  try Test.eq([again.generation, again.last_event_id], [4, 7])
  # The new reader finds no server and ends.
  Task.await(again.stream.unwrap!)
  ok()
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

# The /tree picker lists the numbered messages and answers of every branch; Enter on one asks for the branch by a
# command, not while a turn runs, and nothing but a local command (/help) goes until its reply. `/tree N` names a
# message of the picker shown last. The session the server moved to is opened with the message it went back before
# selected in the prompt: a typed character replaces it, an arrow keeps it.
def test_the_tree_picker_moves_the_session_and_fills_the_prompt() -> Result[Void]
  nodes = [
    Protocol.TreeNode(id: 1, text: "One.", answer: "A1", last: 7, active: true),
    Protocol.TreeNode(id: 8, parent: some(1), text: "Two.", answer: "A2", last: 14),
    Protocol.TreeNode(id: 15, parent: some(1), text: "Three.", last: 20, active: true),
  ]

  tree = Protocol.SessionTree(nodes: nodes)
  picker = Picker.Picker(tree: Client.tree_rows(tree), kind: Picker.Kind.Tree)
  model = model_of(50, 13).with(id: "s1", picker: some(picker), listed: some(tree))
  drawn = rows(model)
  try Test.assert(drawn.include?("› 1. * One."), "the first message is selected: #{drawn}")
  try Test.assert(drawn.include?("2. ├   Two."), "a branch has a guide: #{drawn}")
  try Test.assert(drawn.include?("→ A2"), "an answer is a row: #{drawn}")
  down = App.update(model, App.Msg.Key(TUI.Event.Key(TUI.Key.Down, TUI.Mods()))).model
  busy = App.update(down.with(turn: true), enter())
  try Test.eq([busy.cmds.size.to_s, busy.model.picker.some?.to_s], ["0", "false"])
  picked = App.update(down, enter())
  try Test.eq(
    [picked.cmds.size.to_s, picked.model.picker.some?.to_s, picked.model.moving.to_s],
    ["1", "false", "true"],
  )

  try Test.assert(picked.cmds.flat_map { |cmd| run(cmd) }.all? { |msg| moved?(msg) }, "the branch is asked")
  held = App.update(picked.model.with(prompt: "hi"), enter())
  try Test.eq([held.cmds.size.to_s, held.model.prompt, held.model.outbox.size.to_s], ["0", "hi", "0"])
  helped = App.update(picked.model.with(prompt: "/help"), enter()).model
  try Test.eq([helped.prompt, helped.entries.last.text], ["", Client.help().last])
  renewed = App.update(picked.model.with(prompt: "/new"), enter()).model
  try Test.eq([renewed.prompt, renewed.entries.last.text], ["/new", "the session is moving: wait for it"])
  typed = App.update(model.with(picker: none, prompt: "/tree 3"), enter())
  try Test.eq([typed.cmds.size.to_s, typed.model.moving.to_s], ["1", "true"])
  unlisted = App.update(model.with(picker: none, listed: none, prompt: "/tree 3"), enter())
  try Test.eq([unlisted.cmds.size.to_s, unlisted.model.entries.last.text], ["0", "open the list first: /tree"])
  branched = Protocol.Branched(id: "s1", text: "Two.")
  back = App.update(model.with(picker: none, moving: true), App.Msg.Moved(ok(branched))).model
  try Test.eq([back.prompt, back.cursor.to_s, back.prefilled.to_s, back.moving.to_s], ["Two.", "4", "true", "false"])
  replaced = App.update(back, App.Msg.Key(TUI.Event.Char("x", TUI.Mods()))).model
  try Test.eq([replaced.prompt, replaced.prefilled.to_s], ["x", "false"])
  kept = App.update(back, App.Msg.Key(TUI.Event.Key(TUI.Key.Left, TUI.Mods()))).model
  try Test.eq([kept.prompt, kept.prefilled.to_s], ["Two.", "false"])
  failed = App.update(model.with(picker: none, moving: true), App.Msg.Moved(error("busy", kind: "session.busy"))).model
  Test.eq([failed.prompt, failed.entries.last.text, failed.moving.to_s], ["", "error: busy", "false"])
end

# Alt+Enter during a turn keeps the text for after it, listed above the editor; the turn's end sends the follow-ups
# as one message, and Esc puts them back in the prompt instead.
def test_follow_ups_wait_for_the_end_of_the_turn() -> Result[Void]
  model = model_of(30, 9).with(id: "s1", turn: true, feed: some(Channel.new(4)), generation: 1)
  for text in ["one", "two"]
    model = App.update(model.with(prompt: text), alt_enter()).model
  end

  try Test.eq([model.follow_ups, [model.prompt]], [["one", "two"], [""]])
  try Test.eq(rows(model).drop(2).take(2), ["follow-up: one", "follow-up: two"])
  finished = Protocol.Event.TurnFinished(
    Protocol.TurnFinished(turn_id: "t1", stop_reason: Protocol.StopReason.EndTurn),
  )

  ended = App.update(model, App.Msg.Stream(1, [Client.Item.Event(some(5), finished)]))
  try Test.eq([ended.model.follow_ups.size, ended.cmds.size], [0, 2])
  try Test.eq(ended.model.outbox, ["one\n\ntwo"])

  back = App.update(model.with(prompt: "three"), App.Msg.Key(TUI.Event.Key(TUI.Key.Escape, TUI.Mods())))
  try Test.eq(
    [back.model.prompt, "#{back.model.follow_ups}", "#{back.model.stopping}"],
    ["one\ntwo\nthree", "[]", "true"],
  )

  quit = App.update(model.with(prompt: "/quit"), alt_enter()).model
  try Test.eq([quit.exit, some(quit.follow_ups.size)], [some(0), some(2)])
  idle = App.update(model_of(30, 8).with(prompt: "now"), alt_enter())
  Test.eq(idle.model.outbox, ["now"])
end

# A resync that finds no turn running sends the follow-ups: the end of their turn was missed. A move to another branch
# puts them in the prompt after the message it went back before.
def test_a_resync_with_no_turn_sends_the_follow_ups() -> Result[Void]
  session = Protocol.Session(
    id: "s1",
    cwd: ".",
    model: "m",
    last_event_id: 9,
    turn_id: none,
    turn_from_event_id: none,
    pending_approvals: [],
    history: [],
  )

  backend = Client.unreachable_backend().with(session: ->(_id: String) { ok(session) })
  model = model_of(30, 8).with(backend: backend, id: "s1", turn: true, generation: 1, follow_ups: ["later"])
  resynced = App.update(model, App.Msg.Stream(1, [Client.Item.Event(some(3), Protocol.Event.Resync)])).model
  Task.await(resynced.stream.unwrap!)
  branched = Protocol.Branched(id: "s1", text: "Two.")
  moved = App.update(model.with(turn: false, moving: true), App.Msg.Moved(ok(branched))).model
  Task.await(moved.stream.unwrap!)
  try Test.eq([resynced.follow_ups, resynced.outbox], [[], ["later"]])
  Test.eq([moved.prompt, moved.follow_ups.size.to_s, moved.outbox.size.to_s], ["Two.\nlater", "0", "0"])
end

# The first resync replays the running turn from its start, the next reads only what comes after; one more in a row
# ends the client.
def test_resyncs_in_a_row_end_the_client() -> Result[Void]
  session = Protocol.Session(
    id: "s1",
    cwd: ".",
    model: "m",
    last_event_id: 9,
    turn_id: some("t1"),
    turn_from_event_id: some(2),
    pending_approvals: [],
    history: [],
  )

  froms: Channel[Int] = Channel.new(Session.MAX_RESYNCS + 2)
  # Every read is one reader that already ended, so the test leaves no task running.
  reader = idle()
  Task.await(reader)
  backend = Client.unreachable_backend().with(
    session: ->(_id: String) { ok(session) },
    subscribe: ->(_id: String, from: Int, _sink: Fn[Client.Item, Result[Void]]) {
      _ = froms.send(from, 0)
      reader
    },
  )

  model = model_of(30, 8).with(backend: backend, id: "s1", turn: true, generation: 1)
  quits: List[Bool] = []
  for _ in 0..Session.MAX_RESYNCS
    step = App.update(model, App.Msg.Stream(model.generation, [Client.Item.Event(some(5), Protocol.Event.Resync)]))
    model = step.model
    quits = quits.push(step.cmds.any? { |cmd| quit?(cmd) })
  end

  reads: List[Int] = []
  got = froms.recv(0)
  while got.ok?
    reads = reads.push(got.unwrap!)
    got = froms.recv(0)
  end

  try Test.eq(reads, [2] + (1...Session.MAX_RESYNCS).map { |_| 9 })
  try Test.eq(quits, (0..Session.MAX_RESYNCS).map { |i| i == Session.MAX_RESYNCS })
  Test.eq(model.failure, some("the server keeps asking to read the session again"))
end

# A resync into a session whose snapshot names a running command waits for it; its end, a cut one with no duration,
# clears it.
def test_a_command_running_on_attach_waits_for_its_end() -> Result[Void]
  session = Protocol.Session(
    id: "s1",
    cwd: ".",
    model: "m",
    last_event_id: 9,
    turn_id: none,
    turn_from_event_id: none,
    pending_approvals: [],
    history: [],
    shell_id: some("sh1"),
  )

  backend = Client.unreachable_backend().with(session: ->(_id: String) { ok(session) })
  model = model_of(40, 8).with(backend: backend, id: "s1", generation: 1)
  resynced = App.update(model, App.Msg.Stream(1, [Client.Item.Event(some(3), Protocol.Event.Resync)])).model
  Task.await(resynced.stream.unwrap!)
  try Test.eq([resynced.shell, App.subscriptions(resynced).size == 2], [true, true])
  cut = Protocol.ShellFinished(
    shell_id: "sh1",
    command: "make",
    context: false,
    ok: false,
    output: "the server stopped while it ran",
    duration_ms: 0,
  )

  item = Client.Item.Event(some(10), Protocol.Event.ShellFinished(cut))
  ended = App.update(resynced, App.Msg.Stream(resynced.generation, [item])).model
  shown = rows(ended)
  Test.eq([ended.shell, shown.include?("$ make"), shown.any? { |row| row.include?("Took") }], [false, true, false])
end

# The editing keys of pi: by word (letters and punctuation are words of their own), to the line's ends, forward; Ctrl+D
# quits on an empty prompt.
def test_editing_keys_cut_and_move_by_word_and_line() -> Result[Void]
  model = model_of(40, 8).with(id: "s1", prompt: "one two-three four", cursor: 18)
  steps = [
    key(TUI.Key.Left, TUI.Mods(alt: true)),
    ctrl("w"),
    key(TUI.Key.Backspace, TUI.Mods(alt: true)),
    ctrl("a"),
    key(TUI.Key.Delete, TUI.Mods()),
    ctrl("e"),
    key(TUI.Key.Left, TUI.Mods(ctrl: true)),
    App.Msg.Key(TUI.Event.Char("f", TUI.Mods(alt: true))),
    App.Msg.Key(TUI.Event.Char("B", TUI.Mods(alt: true))),
    ctrl("k"),
    ctrl("k"),
    ctrl("u"),
  ]

  shown: List[String] = []
  for step in steps
    model = App.update(model, step).model
    shown = shown.push("#{model.prompt}|#{model.cursor}")
  end

  try Test.eq(
    shown,
    [
      "one two-three four|14",
      "one two-four|8",
      "one twofour|7",
      "one twofour|0",
      "ne twofour|0",
      "ne twofour|10",
      "ne twofour|3",
      "ne twofour|10",
      "ne twofour|3",
      "ne |3",
      "ne |3",
      "|0",
    ],
  )

  # At a line's start Ctrl+U joins it with the line before; at its end Ctrl+K with the line after.
  joined = App.update(model_of(40, 8).with(prompt: "ab\ncd", cursor: 3), ctrl("u")).model
  try Test.eq([joined.prompt, "#{joined.cursor}"], ["abcd", "2"])
  try Test.eq(App.update(model_of(40, 8).with(prompt: "ab\ncd", cursor: 2), ctrl("k")).model.prompt, "abcd")
  try Test.eq(App.update(model_of(40, 8).with(prompt: "ab", cursor: 0), ctrl("d")).model.prompt, "b")
  # An edit that deletes nothing keeps the prompt recalled.
  recalled = model_of(40, 8).with(prompt: "ab", cursor: 2, history: ["ab"], recall: some(0))
  for edit in [ctrl("k"), key(TUI.Key.Delete, TUI.Mods()), ctrl("e")]
    try Test.eq(App.update(recalled, edit).model.recall, some(0))
  end

  try Test.eq(App.update(recalled.with(cursor: 0), ctrl("u")).model.recall, some(0))
  quit = App.update(model_of(40, 8), ctrl("d"))
  try Test.eq(quit.model.exit, some(0))
  try Test.assert(quit.cmds.any? { |cmd| quit?(cmd) }, "Ctrl+D quits")
  busy = App.update(model_of(40, 8).with(turn: true), ctrl("d"))
  Test.eq([busy.model.exit.none?, busy.cmds.empty?], [true, true])
end

# A word move or Ctrl+W stops at a line end: at a line's start it takes only the line end. Delete takes a character
# with the zero-width ones joined to it; words of CJK are words too.
def test_words_stop_at_line_ends_and_delete_takes_a_whole_character() -> Result[Void]
  model = model_of(40, 8).with(prompt: "ab cd\n  ef", cursor: 10)
  places: List[String] = []
  for step in [alt_left(), alt_left(), alt_left(), alt_left(), alt_right(), alt_right()]
    model = App.update(model, step).model
    places = places.push("#{model.cursor}")
  end

  try Test.eq(places, ["8", "6", "5", "3", "5", "6"])
  cut = App.update(model_of(40, 8).with(prompt: "ab\ncd", cursor: 3), ctrl("w")).model
  try Test.eq([cut.prompt, "#{cut.cursor}"], ["abcd", "2"])
  spaces = App.update(model_of(40, 8).with(prompt: "ab\n  cd", cursor: 5), ctrl("w")).model
  try Test.eq(spaces.prompt, "ab\ncd")
  accent = "e#{String.from_code(0x301)}x"
  try Test.eq(App.update(model_of(40, 8).with(prompt: accent, cursor: 0), ctrl("d")).model.prompt, "x")
  coder = "#{String.from_code(0x1F469)}#{String.from_code(0x200D)}#{String.from_code(0x1F4BB)}!"
  try Test.eq(
    App.update(model_of(40, 8).with(prompt: coder, cursor: 0), key(TUI.Key.Delete, TUI.Mods())).model.prompt,
    "!",
  )

  cjk = model_of(40, 8).with(prompt: "中文 字", cursor: 4)
  left = App.update(cjk, alt_left()).model
  Test.eq(["#{left.cursor}", "#{App.update(left, alt_left()).model.cursor}"], ["3", "0"])
end

# Up and Down move between the rows of the prompt, cut lines included, and keep their column across shorter rows; Up
# from the first row recalls a prompt only while one is recalled or the prompt is empty, and Down from the last
# row goes
# on through the recalled ones.
def test_up_and_down_move_between_rows_and_recall_from_the_edges() -> Result[Void]
  model = model_of(40, 8).with(id: "s1", history: ["first", "second\nline"])
  places: List[String] = []
  for step in [up(), up(), up(), down(), down(), down()]
    model = App.update(model, step).model
    places = places.push("#{model.prompt}|#{model.cursor}")
  end

  try Test.eq(places, ["second\nline|11", "second\nline|4", "first|5", "second\nline|11", "|0", "|0"])

  typed = model_of(40, 8).with(prompt: "ab\ncdef", cursor: 6)
  higher = App.update(typed, up()).model
  try Test.eq(["#{higher.cursor}", "#{App.update(higher, down()).model.cursor}"], ["2", "6"])
  try Test.eq(App.update(higher, up()).model.cursor, 2)
  try Test.eq(App.update(App.update(higher, key(TUI.Key.Left, TUI.Mods())).model, down()).model.cursor, 4)
  # The column is kept across a short row.
  short = model_of(40, 8).with(prompt: "abcdef\nab\nabcdef", cursor: 5)
  across = App.update(App.update(short, down()).model, down()).model
  try Test.eq(across.cursor, 15)
  # 8 columns leave 6 to the text: "abcdef" and "ghij" are two rows of one line.
  long = model_of(8, 8).with(prompt: "abcdefghij", cursor: 9)
  try Test.eq(App.update(long, up()).model.cursor, 3)
  try Test.eq(App.update(long.with(cursor: 5), down()).model.cursor, 10)
  # On a screen 1 or 2 columns wide each character is a row.
  for width in [1, 2]
    narrow = model_of(width, 8).with(prompt: "abc", cursor: 1)
    try Test.eq([App.update(narrow, up()).model.cursor, App.update(narrow, down()).model.cursor], [0, 2])
  end

  # A wide character takes two columns: a column inside it goes to its start.
  wide = model_of(40, 8).with(prompt: "中文字\nab", cursor: 5)
  try Test.eq([App.update(wide, up()).model.cursor, App.update(wide.with(cursor: 6), up()).model.cursor], [0, 1])
  emoji = model_of(40, 8).with(prompt: "#{String.from_code(0x1F600)}x\nabc", cursor: 6)
  Test.eq(App.update(emoji, up()).model.cursor, 2)
end

# A prompt put back from outside the keys (a message that was not sent) forgets the column Up and Down kept.
def test_a_prompt_put_back_forgets_the_kept_column() -> Result[Void]
  model = model_of(40, 8).with(id: "s1", prompt: "abcdef\nab", cursor: 5)
  lower = App.update(model, down()).model
  try Test.eq([lower.cursor, lower.goal_column.unwrap_or(-1)], [9, 5])
  sending = lower.with(prompt: "", cursor: 0, outbox: ["abc\nabcdef"])
  put_back = App.update(sending, App.Msg.Sent(0, "abc\nabcdef", error("down", kind: Client.KIND_UNREACHABLE))).model
  try Test.eq([put_back.prompt, "#{put_back.goal_column}"], ["abc\nabcdef", "none"])
  Test.eq(App.update(put_back.with(cursor: 3), down()).model.cursor, 7)
end

# Up on an empty prompt goes back through the prompts sent, Down comes forward to an empty prompt; a large paste is
# one token that the send puts back.
def test_up_recalls_prompts_and_a_large_paste_is_one_token() -> Result[Void]
  model = model_of(40, 8).with(id: "s1")
  for text in ["first", "/help"]
    model = App.update(model.with(prompt: text), enter()).model
  end

  up = App.Msg.Key(TUI.Event.Key(TUI.Key.Up, TUI.Mods()))
  down = App.Msg.Key(TUI.Event.Key(TUI.Key.Down, TUI.Mods()))
  model = App.update(model, up).model
  try Test.eq(model.prompt, "/help")
  model = App.update(App.update(model, up).model, up).model
  try Test.eq(model.prompt, "first")
  try Test.eq(App.update(App.update(model, down).model, down).model.prompt, "")
  text = (1..12).to_a.map { |i| "line #{i}" }.join("\n")
  pasted = App.update(
    model_of(40, 8).with(id: "s1", prompt: "see ", cursor: 4),
    App.Msg.Key(TUI.Event.Paste(text)),
  ).model

  try Test.eq(pasted.prompt, "see [paste #1 +12 lines]")
  sent = App.update(pasted, enter()).model
  try Test.eq(sent.outbox, ["see #{text}"])
  try Test.eq(App.update(sent, App.Msg.Key(TUI.Event.Key(TUI.Key.Up, TUI.Mods()))).model.prompt, "see #{text}")
  # A paste that holds the token of a later paste keeps it as text: each token is put back once.
  inner = "#{"x" * 1001} [paste #2 +12 lines]"
  both = App.update(
    App.update(model_of(40, 8).with(id: "s1"), App.Msg.Key(TUI.Event.Paste(inner))).model,
    App.Msg.Key(TUI.Event.Paste(text)),
  ).model

  try Test.eq(both.prompt, "[paste #1 1022 chars][paste #2 +12 lines]")
  try Test.eq(App.update(both, enter()).model.outbox, ["#{inner}#{text}"])
  # A token's text typed before the real token is the copy that is put back; the real token after it stays as text.
  typed = model_of(40, 8).with(id: "s1", prompt: "[paste #1 +12 lines] [paste #1 +12 lines]", pastes: [text])
  Test.eq(App.update(typed, enter()).model.outbox, ["#{text} [paste #1 +12 lines]"])
end

# `@` asks the server for the files of the session's folder each time it is typed; the list under the editor narrows
# as the word grows, Tab puts the selected path in its place, and Esc closes the list. A failed read is a note.
def test_at_lists_the_files_and_tab_completes_one() -> Result[Void]
  model = model_of(40, 10).with(id: "s1", prompt: "see ", cursor: 4)
  asked = App.update(model, App.Msg.Key(TUI.Event.Char("@", TUI.Mods())))
  try Test.eq([asked.cmds.size.to_s, asked.model.reading_files.to_s], ["1", "true"])
  listed = Protocol.FileList(files: ["README.md", "thinking.sse"])
  model = App.update(asked.model, App.Msg.Files(asked.model.opened, ok(listed))).model
  try Test.eq(model.files, some(["README.md", "thinking.sse"]))
  # A cut list is said once, until a whole one comes.
  cut = App.update(model, App.Msg.Files(model.opened, ok(listed.with(truncated: true)))).model
  try Test.eq(cut.entries.last.text, "the @ list is cut: the folder has more files than it reads")
  try Test.eq(
    App.update(cut, App.Msg.Files(model.opened, ok(listed.with(truncated: true)))).model.entries.size,
    cut.entries.size,
  )

  again = App.update(model.with(prompt: "", cursor: 0), App.Msg.Key(TUI.Event.Char("@", TUI.Mods())))
  try Test.eq(again.cmds.size, 1)
  failed = App.update(again.model, App.Msg.Files(again.model.opened, error("refused")))
  try Test.eq([failed.model.reading_files.to_s, failed.model.files.unwrap_or([]).size.to_s], ["false", "2"])
  try Test.assert(failed.model.entries.last.text.include?("the files were not listed"), failed.model.entries.last.text)
  # After a timeout the server may still walk the folder: `@` asks again only later.
  slow = App.update(again.model, App.Msg.Files(again.model.opened, error("slow", kind: Client.KIND_TIMEOUT))).model
  try Test.eq(App.update(slow.with(prompt: "", cursor: 0), App.Msg.Key(TUI.Event.Char("@", TUI.Mods()))).cmds.size, 0)
  # A name with control bytes is drawn without them.
  odd = "a#{String.from_code(27)}[2Jb.txt"
  shown = App.update(
    model.with(prompt: "@", cursor: 1),
    App.Msg.Files(model.opened, ok(Protocol.FileList(files: [odd]))),
  ).model

  try Test.assert(rows(shown).any? { |row| row.include?("a [2Jb.txt") }, "#{rows(shown)}")
  for char in ["t", "h", "k"]
    model = App.update(model, App.Msg.Key(TUI.Event.Char(char, TUI.Mods()))).model
  end

  try Test.assert(rows(model).include?("thinking.sse"), "the list shows the file")
  done = App.update(model, App.Msg.Key(TUI.Event.Key(TUI.Key.Tab, TUI.Mods()))).model
  try Test.eq([done.prompt, done.cursor.to_s], ["see @thinking.sse ", "18"])
  closed = App.update(model, App.Msg.Key(TUI.Event.Key(TUI.Key.Escape, TUI.Mods()))).model
  Test.assert(not rows(closed).include?("thinking.sse"), "Esc closes the list")
end

# `/` lists the commands of the client's table under the editor, narrowed as the name grows; Tab completes the
# selected one, Enter completes a part of a name and runs a whole one, Esc closes the list, and a name no command
# starts with shows none and goes as text.
def test_slash_lists_the_commands_and_tab_completes_one() -> Result[Void]
  model = App.update(model_of(80, 20).with(id: "s1"), key_char("/")).model
  try Test.assert(
    rows(model).any? { |row| row.start_with?("/new") and row.include?("a new session") },
    "#{rows(model)}",
  )

  try Test.assert(not rows(model).any? { |row| row.start_with?("/cost") }, "an unlisted command is left out")
  for c in ["m", "o"]
    model = App.update(model, key_char(c)).model
  end

  try Test.assert(
    rows(model).any? { |row| row.start_with?("/model [PROVIDER/]NAME  change the model") },
    "#{rows(model)}",
  )

  try Test.assert(not rows(model).any? { |row| row.start_with?("/new") }, "the list narrows")
  done = App.update(model, App.Msg.Key(TUI.Event.Key(TUI.Key.Tab, TUI.Mods()))).model
  try Test.eq([done.prompt, done.cursor.to_s], ["/model ", "7"])
  try Test.assert(not rows(done).any? { |row| row.start_with?("/model [") }, "a space closes the list")
  closed = App.update(model, App.Msg.Key(TUI.Event.Key(TUI.Key.Escape, TUI.Mods()))).model
  try Test.assert(not rows(closed).any? { |row| row.start_with?("/model [") }, "Esc closes the list")
  try Test.eq(closed.stopping, false)
  # Enter on part of a name completes it and runs nothing; on a whole name it runs the command.
  partial = App.update(model_of(80, 20).with(id: "s1", prompt: "/c", cursor: 2), enter())
  try Test.eq([partial.model.prompt, partial.model.outbox.size.to_s, partial.cmds.size.to_s], ["/clone", "0", "0"])
  helped = App.update(model_of(80, 20).with(id: "s1", prompt: "/help", cursor: 5), enter()).model
  try Test.eq(helped.prompt, "")
  try Test.assert(
    helped.entries.any? { |entry| entry.text == "/quit                      leave" },
    "the help is drawn",
  )

  # Esc, then Enter, sends a prefix as text.
  escaped = App.update(model_of(80, 20).with(id: "s1", prompt: "/c", cursor: 2), escape()).model
  try Test.eq(App.update(escaped, enter()).model.outbox, ["/c"])
  # The cursor inside the word, or a word after which more is typed, shows no list; at the end of the word the whole
  # word is replaced.
  # With the cursor inside the word, Enter runs the line as it does at the word's end.
  inside = App.update(model_of(80, 20).with(id: "s1", prompt: "/resume", cursor: 3), enter())
  at_end = App.update(model_of(80, 20).with(id: "s1", prompt: "/resume", cursor: 7), enter())
  try Test.eq(
    [inside.model.prompt, inside.model.entries.map { |entry| entry.text }.join("\n"), inside.cmds.size.to_s],
    [at_end.model.prompt, at_end.model.entries.map { |entry| entry.text }.join("\n"), at_end.cmds.size.to_s],
  )

  # In a prompt of more lines, Enter completes the first word and keeps the rest.
  lines = App.update(model_of(80, 20).with(id: "s1", prompt: "/c\nfoo", cursor: 2), enter())
  try Test.eq([lines.model.prompt, lines.model.outbox.size.to_s, lines.cmds.size.to_s], ["/clone\nfoo", "0", "0"])
  middle = App.update(model_of(80, 20).with(id: "s1", prompt: "/mo foo", cursor: 3), tab()).model
  try Test.eq(middle.prompt, "/model foo")
  inside_rows = rows(model_of(80, 20).with(prompt: "/resume", cursor: 3))
  try Test.assert(not inside_rows.any? { |row| row.start_with?("/resume [") }, "no list inside the word")
  # Backspace from `/` closes the list; a prompt Up recalled shows none.
  back = App.update(App.update(model_of(80, 20).with(id: "s1"), key_char("/")).model, backspace()).model
  try Test.assert(not rows(back).any? { |row| row.start_with?("/new") }, "no list")
  recalled = App.update(model_of(80, 20).with(id: "s1", history: ["/he"]), up()).model
  try Test.eq(recalled.prompt, "/he")
  try Test.assert(not rows(recalled).any? { |row| row.start_with?("/help") }, "a recalled prompt shows no list")
  try Test.eq(App.update(model_of(80, 20).with(id: "s1", prompt: "/", cursor: 1), enter()).model.outbox, ["/"])
  path = "/etc/hosts has a bad entry"
  try Test.eq(
    App.update(model_of(80, 20).with(id: "s1", prompt: path, cursor: path.size), enter()).model.outbox,
    [path],
  )

  unknown = model_of(80, 20).with(id: "s1", prompt: "/zz", cursor: 3)
  try Test.assert(not rows(unknown).any? { |row| row.include?("no file matches") }, "no list")
  Test.eq(App.update(unknown, enter()).model.outbox, ["/zz"])
end

# On a small screen the list shows the rows it has room for: Down scrolls it to keep the selected one in view, Up moves
# the mark within it, and a resize keeps the selected one in view too.
def test_the_command_list_follows_the_selection_on_a_small_screen() -> Result[Void]
  model = App.update(model_of(80, 7).with(id: "s1"), key_char("/")).model
  for _ in 0...20
    model = App.update(model, down()).model
  end

  try Test.assert(rows(model).any? { |row| row.start_with?("/quit") }, "the selected row shows: #{rows(model)}")
  up_once = App.update(model, up()).model
  try Test.eq(
    [rows(up_once).join("\n"), up_once.mention_selected.to_s],
    [rows(model).join("\n"), (model.mention_selected - 1).to_s],
  )

  wide = App.update(model_of(80, 20).with(id: "s1"), key_char("/")).model
  for _ in 0...20
    wide = App.update(wide, down()).model
  end

  resized = App.update(wide, App.Msg.Key(TUI.Event.Resize(80, 7))).model
  try Test.assert(rows(resized).any? { |row| row.start_with?("/quit") }, "the selected row shows: #{rows(resized)}")
  tiny = App.update(model_of(80, 4).with(id: "s1"), key_char("/")).model
  try Test.eq(App.update(tiny, down()).model.mention_selected, 0)
  Test.eq(App.update(tiny, enter()).model.outbox, ["/"])
end

# A pending approval takes the panel: the list is hidden and Tab goes to the approval. While a turn runs, Esc closes
# the list first and stops the turn the second time.
def test_the_command_list_gives_way_to_an_approval_and_to_esc() -> Result[Void]
  request = Protocol.ApprovalRequested(
    approval_id: "a1",
    call_id: "c1",
    tool: "write_file",
    preview: "x.txt",
    detail: "",
  )

  panel = Approvals.requested(Approvals.Panel(), request, 0)
  asked = model_of(80, 20).with(id: "s1", turn: true, prompt: "/m", cursor: 2, approvals: panel)

  try Test.assert(not rows(asked).any? { |row| row.start_with?("/model [") }, "no list: #{rows(asked)}")
  tabbed = App.update(asked, tab()).model
  try Test.eq([tabbed.prompt, tabbed.approvals.focused.to_s], ["/m", "true"])
  running = model_of(80, 20).with(id: "s1", turn: true, prompt: "/m", cursor: 2)
  closed = App.update(running, escape()).model
  try Test.eq([closed.stopping.to_s, rows(closed).any? { |row| row.start_with?("/model [") }.to_s], ["false", "false"])
  Test.eq(App.update(closed, escape()).model.stopping, true)
end

# The argument of `/model`, `/resume` and `/tree` is listed from the server once its command is typed, in the list
# under the editor; `/thinking` lists its levels. Tab completes the selected choice; Enter runs the line as typed.
def test_arguments_complete_from_the_server() -> Result[Void]
  providers = Protocol.ProviderList(
    provider: "p",
    providers: [Protocol.ProviderInfo(name: "p", api: "chat", models: ["small", "large"])],
  )

  summary = Protocol.SessionSummary(id: "s9", cwd: "/w", model: "m", api: "chat", title: "fix the tests")
  tree = Protocol.SessionTree(nodes: [Protocol.TreeNode(id: 1, text: "hello", last: 2)])
  backend = Client.unreachable_backend().with(
    list_providers: -> { ok(providers) },
    list_sessions: -> { ok(Protocol.SessionList(sessions: [summary])) },
    tree: ->(_id: String) { ok(tree) },
  )

  model = model_of(80, 20).with(backend: backend, id: "s1")
  completed: List[String] = []
  for command in ["/model", "/resume", "/tree"]
    asking = App.update(model.with(prompt: command, cursor: command.length), key_char(" "))
    try Test.eq(asking.cmds.size, 1)
    listed = App.update(asking.model, run(asking.cmds[0])[0]).model
    picked = App.update(App.update(listed, down()).model, tab()).model
    completed = completed.push(picked.prompt)
  end

  try Test.eq(completed, ["/model p/large", "/resume s9", "/tree 1"])
  levels = model.with(prompt: "/thinking h", cursor: 11)
  try Test.assert(rows(levels).any? { |row| row.start_with?("high") }, "#{rows(levels)}")
  try Test.eq(App.update(levels, tab()).model.prompt, "/thinking high")
  # The tree listed for `/tree N` is the one its numbers name; leaving the command forgets the choices.
  asking = App.update(model.with(prompt: "/tree", cursor: 5), key_char(" "))
  listed = App.update(asking.model, run(asking.cmds[0])[0]).model
  try Test.eq([listed.listed.some?, rows(listed).any? { |row| row.start_with?("1. ") }], [true, true])
  left = App.update(listed, backspace()).model
  try Test.eq(left.arguments.none?, true)
  # Enter runs the line as typed, with no completion.
  typed = App.update(listed.with(prompt: "/thinking hi", cursor: 12), enter()).model
  try Test.eq(typed.entries.last.text, "the thinking level is one of low, medium, high, default")
  # A late `/tree` list, once the prompt holds `/model `, leaves the listed tree alone and asks for the models.
  late = App.update(model.with(prompt: "/tree", cursor: 5), key_char(" "))
  moved_on = late.model.with(prompt: "/model ", cursor: 7)
  replied = App.update(moved_on, run(late.cmds[0])[0])
  try Test.eq([replied.model.listed.none?, replied.model.arguments.none?, replied.cmds.size == 1], [true, true, true])
  try Test.eq(App.update(replied.model, run(replied.cmds[0])[0]).model.arguments.map { |a| a.command }, some("/model"))
  # A read that fails is noted once and not asked again while the command stays.
  down = model.with(backend: backend.with(list_providers: -> { error("down", kind: Client.KIND_UNREACHABLE) }))
  failing = App.update(down.with(prompt: "/model", cursor: 6), key_char(" "))
  failed = App.update(failing.model, run(failing.cmds[0])[0]).model
  again = App.update(failed, key_char("x"))
  notes = again.model.entries.select { |entry| entry.text.include?("not listed") }
  Test.eq([notes.size, again.cmds.size], [1, 0])
end

# An Alt key types nothing: not in the prompt, not over a selected prompt, not in a picker's filter, not in a key.
def test_an_alt_key_types_nothing() -> Result[Void]
  alt_x = App.Msg.Key(TUI.Event.Char("x", TUI.Mods(alt: true)))
  typed = App.update(model_of(40, 8).with(prompt: "ab", cursor: 2), alt_x).model
  selected = App.update(model_of(40, 8).with(prompt: "keep", cursor: 4, prefilled: true), alt_x).model
  picking = App.update(model_of(40, 8).with(picker: some(Picker.Picker())), alt_x).model
  secret = App.update(model_of(40, 8).with(key_for: some("openai")), alt_x).model
  Test.eq(
    [typed.prompt, selected.prompt, picking.picker.map { |p| p.filter }.unwrap_or("closed"), secret.secret],
    ["ab", "keep", "", ""],
  )
end

# Ctrl+D on an empty prompt does not quit while a command runs, an approval waits or a message is on its way.
def test_ctrl_d_waits_for_what_runs() -> Result[Void]
  request = Protocol.ApprovalRequested(approval_id: "a1", call_id: "c1", tool: "write_file", preview: "x", detail: "")
  waiting = [
    model_of(40, 8).with(shell: true),
    model_of(40, 8).with(approvals: Approvals.requested(Approvals.Panel(), request, 0)),
    model_of(40, 8).with(outbox: ["hi"]),
    model_of(40, 8).with(moving: true),
    model_of(40, 8).with(stopping: true),
  ]

  for model in waiting
    try Test.eq(App.update(model, ctrl("d")).model.exit, none)
  end

  sent = App.update(model_of(40, 8).with(id: "s1", prompt: "hi", cursor: 2), enter()).model
  after = App.update(sent, ctrl("d")).model
  Test.eq([after.exit.none?, after.outbox == ["hi"]], [true, true])
end

# One key deletes or crosses a whole character: a flag (two flag letters), a skin tone, a ZWJ sequence.
def test_a_key_takes_a_whole_character() -> Result[Void]
  spain = "#{String.from_code(0x1F1EA)}#{String.from_code(0x1F1F8)}"
  france = "#{String.from_code(0x1F1EB)}#{String.from_code(0x1F1F7)}"
  thumb = "#{String.from_code(0x1F44D)}#{String.from_code(0x1F3FD)}"
  zwj = String.from_code(0x200D)
  coder = "#{String.from_code(0x1F469)}#{String.from_code(0x1F3FD)}#{zwj}#{String.from_code(0x1F4BB)}"
  delete = key(TUI.Key.Delete, TUI.Mods())
  flags = model_of(40, 8).with(prompt: spain + france, cursor: 0)
  try Test.eq(App.update(flags, delete).model.prompt, france)
  right = App.update(flags, key(TUI.Key.Right, TUI.Mods())).model
  try Test.eq([right.cursor, App.update(right, key(TUI.Key.Right, TUI.Mods())).model.cursor], [2, 4])
  try Test.eq(App.update(model_of(40, 8).with(prompt: thumb + "x", cursor: 0), delete).model.prompt, "x")
  try Test.eq(App.update(model_of(40, 8).with(prompt: coder + "!", cursor: 0), delete).model.prompt, "!")
  ending = model_of(40, 8).with(prompt: "a" + coder, cursor: 5)
  try Test.eq(App.update(ending, backspace()).model.prompt, "a")
  try Test.eq(App.update(ending, key(TUI.Key.Left, TUI.Mods())).model.cursor, 1)
  Test.eq(App.update(flags.with(cursor: 4), backspace()).model.prompt, spain)
end

# Alt+y (or Escape and y read together) on a focused approval panel answers nothing and types nothing; y allows.
def test_alt_y_does_not_answer_an_approval() -> Result[Void]
  request = Protocol.ApprovalRequested(
    approval_id: "a1",
    call_id: "c1",
    tool: "write_file",
    preview: "x.txt",
    detail: "",
  )

  panel = Approvals.requested(Approvals.Panel(guard_ms: 0), request, 0).with(focused: true)
  asked = model_of(80, 20).with(id: "s1", turn: true, approvals: panel)
  alt = App.update(asked, App.Msg.Key(TUI.Event.Char("y", TUI.Mods(alt: true))))
  try Test.eq([alt.model.approvals.answering.none?, alt.cmds.empty?, alt.model.prompt == ""], [true, true, true])
  plain = App.update(asked, key_char("y"))
  Test.eq([plain.model.approvals.answering, some("#{plain.cmds.size}")], [some("a1"), some("1")])
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

  App.seed(Client.unreachable_backend(), options, Channel.new(1), width, height)
end

# The footer: the folder (home as ~), the branch and the first line of the first user message (not a command the prompt
# history has); then the status, the last model call (its prompt, its output, the cache read and the part cached), the
# session's cost, the prompt in the window, and the model with its level on the right. A `usage` event updates it, the
# end of a turn reads the branch again, and the branch of a session opened since is dropped.
def test_the_footer_shows_the_place_the_usage_and_the_model() -> Result[Void]
  model = model_of(100, 8).with(
    id: "s1",
    cwd: "/home/ana/app",
    home: "/home/ana/",
    history: ["/help", "Fix the parser."],
    entries: [
      Transcript.Entry(kind: Transcript.Kind.Notice, text: "session s1"),
      Transcript.Entry(
        kind: Transcript.Kind.User,
        text: "\n  Fix the#{String.from_code(27)}parser.\nIt fails on tabs.",
      ),
    ],
    serving: "local/qwen3",
    effort: some("high"),
  )

  try Test.eq(
    rows(model).drop(6),
    [
      "~/app · Fix the parser.",
      "ready · Enter send · Esc stop · ^C quit · ^J newline · Alt+Enter follow-up    (local) qwen3 · high",
    ],
  )

  used = Protocol.Usage(
    input: 1200,
    output: 340,
    cache_read: 3600,
    cache_write: 0,
    context: 4800,
    session_cost: some(0.0125),
    window: some(32_000),
    call_output: some(40),
  )

  counted = App.update(
    model,
    App.Msg.Stream(model.generation, [Client.Item.Event(some(5), Protocol.Event.Usage(used))]),
  ).model

  try Test.eq(
    rows(counted).last,
    "ready · ↑4.8k ↓40 R3.6k 75% cached $0.013 15.0%/32k · Enter send · Esc stop   (local) qwen3 · high",
  )

  finished = Protocol.Event.TurnFinished(
    Protocol.TurnFinished(turn_id: "t1", stop_reason: Protocol.StopReason.EndTurn),
  )

  ended = App.update(
    counted.with(turn: true),
    App.Msg.Stream(model.generation, [Client.Item.Event(some(6), finished)]),
  )

  try Test.eq(ended.cmds.flat_map { |cmd| run(cmd) }.select { |msg| branch?(msg) }.size, 1)
  named = App.update(ended.model, App.Msg.Branch(model.opened, "main")).model
  try Test.eq(rows(named)[6], "~/app (main) · Fix the parser.")
  Test.eq(App.update(named, App.Msg.Branch(model.opened - 1, "old")).model.branch, "main")
end

# The login of a local server lists its base URL; picked, it asks for a new one (the prompt empty, the note says the
# current one), and Esc cancels it.
def test_a_local_login_is_listed_with_its_url_and_asks_for_one() -> Result[Void]
  label = "a local server of the OpenAI API (llama.cpp)"
  url = "http://127.0.0.1:8080/v1"
  local = Protocol.LoginStatus(
    name: "local",
    label: label,
    key_env: "FINN_BASE_URL",
    from: "",
    coming: false,
    asks: Protocol.ASKS_URL,
    base_url: url,
  )

  picking = model_of(80, 12).with(picker: some(Picker.logins(Protocol.LoginList(providers: [local], first: false))))
  try Test.assert(rows(picking).any? { |row| row.include?("local  base URL, now #{url}") }, "#{rows(picking)}")

  asked = App.update(picking, enter()).model
  try Test.eq(
    [asked.key_for, some(asked.secret), some(asked.asking_url.to_s)],
    [some("local"), some(""), some("true")],
  )

  try Test.assert(asked.entries.last.text.include?("now #{url}"), asked.entries.last.text)
  cancelled = App.update(asked, App.Msg.Key(TUI.Event.Key(TUI.Key.Escape, TUI.Mods()))).model
  try Test.eq([cancelled.secret, "#{cancelled.key_for}", cancelled.asking_url.to_s], ["", "none", "false"])
  stored = local.with(from: "stored", base_url: "http://127.0.0.1:9090/v1")
  done = App.update(cancelled, App.Msg.LoggedIn("local", ok(stored))).model
  Test.eq(done.entries.last.text, "local is set up at http://127.0.0.1:9090/v1: /model lists its models")
end

# A coming login cannot be given a key; Esc in the key prompt drops what was typed; under `finn login` the answer to
# the login ends the app. A `/login` or `/logout` line, which may hold a key typed by mistake, is not remembered and
# drops its pastes.
def test_a_login_drops_a_coming_pick_and_a_cancelled_key() -> Result[Void]
  claude = Protocol.LoginStatus(name: "claude", label: "Claude Pro/Max", key_env: "", from: "", coming: true)
  groq = Protocol.LoginStatus(name: "groq", label: "", key_env: "GROQ_API_KEY", from: "", coming: false)
  list = Protocol.LoginList(providers: [groq, claude], first: false)
  picking = model_of(60, 12).with(picker: some(Picker.logins(list)))
  down = App.update(picking, App.Msg.Key(TUI.Event.Key(TUI.Key.Down, TUI.Mods()))).model
  coming = App.update(down, enter()).model
  try Test.eq([coming.picker.none?, coming.key_for.none?], [true, true])
  try Test.assert(coming.entries.any? { |e| e.text.include?("Claude Pro/Max: coming") }, "the coming login is said")
  asked = App.update(picking, enter()).model
  try Test.eq(asked.key_for, some("groq"))
  typed = App.update(asked, App.Msg.Key(TUI.Event.Paste("sk-1\n"))).model
  try Test.eq([typed.secret, typed.prompt], ["sk-1", ""])
  cancelled = App.update(typed, App.Msg.Key(TUI.Event.Key(TUI.Key.Escape, TUI.Mods()))).model
  try Test.eq([cancelled.secret, "#{cancelled.key_for}"], ["", "none"])
  only = typed.with(login_only: true)
  sent = App.update(only, enter())
  try Test.eq([sent.model.secret, "#{sent.cmds.size}"], ["", "1"])
  done = App.update(sent.model, App.Msg.LoggedIn("groq", ok(groq.with(from: "stored"))))
  try Test.eq(done.model.exit, some(0))
  try Test.eq(rows(done.model).any? { |row| row.include?("sk-1") }, false)
  for line in ["/login groq [paste #1]", "/logout sk-3"]
    after = App.update(model_of(60, 12).with(prompt: line, pastes: ["sk-2"]), enter()).model
    try Test.eq([after.history.size, after.pastes.size, after.prompt.size], [0, 0, 0])
  end

  ok()
end

def rows(model: App.Model) -> List[String]
  cells = TUI.layout(App.view(model), model.width, model.height)
  (0...model.height).to_a.map do |y| cells.select { |cell| cell.y == y }.map { |cell| cell.char }.join("").strip end
end

def back_tab() -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.BackTab, TUI.Mods()))

def tab() -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.Tab, TUI.Mods()))

def escape() -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.Escape, TUI.Mods()))

def backspace() -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.Backspace, TUI.Mods()))

def down() -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.Down, TUI.Mods()))

def up() -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.Up, TUI.Mods()))

def alt_left() -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.Left, TUI.Mods(alt: true)))

def alt_right() -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.Right, TUI.Mods(alt: true)))

def ctrl(c: String) -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.Ctrl(c), TUI.Mods()))

def key(k: TUI.Key, mods: TUI.Mods) -> App.Msg = App.Msg.Key(TUI.Event.Key(k, mods))

def key_char(c: String) -> App.Msg = App.Msg.Key(TUI.Event.Char(c, TUI.Mods()))

def enter() -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.Enter, TUI.Mods()))

def alt_enter() -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.Enter, TUI.Mods(alt: true)))

def branch?(msg: App.Msg) -> Bool
  case msg
    App.Msg.Branch(_, _) -> true
    _ -> false
  end
end

# A stream reader that reads nothing.
def idle() -> Task[Void]
  Task.spawn(
    -> {
    },
  )
end

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
