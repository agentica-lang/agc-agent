import HTTP from "std/http"
import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import App from "../src/app"
import Approvals from "../src/approvals"
import Args from "../src/args"
import Picker from "../src/picker"

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

  handler = ->(_request: HTTP.Request, _body: HTTP.RequestBody) {
    ok(HTTP.Answer.Whole(HTTP.Response(status: 200, headers: [], body: Protocol.encode_session(session).bytes)))
  }

  http = try HTTP.serve("127.0.0.1", 0, handler)
  server = Client.Server(url: "http://127.0.0.1:#{HTTP.local_port(http)}", token: "t")
  model = model_of(30, 8).with(server: server, id: "s1", turn: true, generation: 1, follow_ups: ["later"])
  resynced = App.update(model, App.Msg.Stream(1, [Client.Item.Event(some(3), Protocol.Event.Resync)])).model
  Task.await(resynced.stream.unwrap!)
  branched = Protocol.Branched(id: "s1", text: "Two.")
  moved = App.update(model.with(turn: false, moving: true), App.Msg.Moved(ok(branched))).model
  Task.await(moved.stream.unwrap!)
  HTTP.close_server(http)
  _ = HTTP.wait(http)
  try Test.eq([resynced.follow_ups, resynced.outbox], [[], ["later"]])
  Test.eq([moved.prompt, moved.follow_ups.size.to_s, moved.outbox.size.to_s], ["Two.\nlater", "0", "0"])
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

  handler = ->(_request: HTTP.Request, _body: HTTP.RequestBody) {
    ok(HTTP.Answer.Whole(HTTP.Response(status: 200, headers: [], body: Protocol.encode_session(session).bytes)))
  }

  http = try HTTP.serve("127.0.0.1", 0, handler)
  server = Client.Server(url: "http://127.0.0.1:#{HTTP.local_port(http)}", token: "t")
  model = model_of(40, 8).with(server: server, id: "s1", generation: 1)
  resynced = App.update(model, App.Msg.Stream(1, [Client.Item.Event(some(3), Protocol.Event.Resync)])).model
  Task.await(resynced.stream.unwrap!)
  HTTP.close_server(http)
  _ = HTTP.wait(http)
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

# The footer: the folder (home as ~), the branch and the first message; then the status, the counts of the last
# model call (cache read, the part cached, the session's cost, the context in the window) and the model with its
# level on the right. A `usage` event updates it, the end of a turn reads the branch again, and the branch of a
# session opened since is dropped.
def test_the_footer_shows_the_place_the_usage_and_the_model() -> Result[Void]
  model = model_of(100, 8).with(
    id: "s1",
    cwd: "/home/ana/app",
    home: "/home/ana",
    history: ["Fix the parser.\nIt fails on tabs."],
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
  )

  counted = App.update(
    model,
    App.Msg.Stream(model.generation, [Client.Item.Event(some(5), Protocol.Event.Usage(used))]),
  ).model

  try Test.eq(
    rows(counted).last,
    "ready · ↑1.2k ↓340 R3.6k 75% cached $0.013 15.0%/32k · Enter send · Esc stop  (local) qwen3 · high",
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

def key_char(c: String) -> App.Msg = App.Msg.Key(TUI.Event.Char(c, TUI.Mods()))

def enter() -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.Enter, TUI.Mods()))

def alt_enter() -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.Enter, TUI.Mods(alt: true)))

def branch?(msg: App.Msg) -> Bool
  case msg
    App.Msg.Branch(_, _) -> true
    _ -> false
  end
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
