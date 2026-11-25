## One session on the terminal: the loop that reads what the user types, the signals and the events of the server, and
## what it does with each. The state is one immutable `Chat`; each input gives the next one.

import Client from "pkg/client/client"
import Yolo from "pkg/client/yolo"
import Protocol from "pkg/protocol/protocol"
import Args from "args"
import Inbox from "inbox"
import Render from "render"

INBOX_CAPACITY = 256
WAIT_MS = 3_600_000
SEND_MS = 30_000
RECONNECT_MS = 300
MAX_RECONNECTS = 3
MAX_RESYNCS = 2
EXIT_INTERRUPTED = 130
EXIT_TERMINATED = 143
EXIT_FAILED = 1

## Runs the session until the user leaves: the exit code, or an error when the session cannot go on. With a prompt it
## sends that one task, reads no line, prints only the answer on stdout (the rest on stderr) and gives the status of
## the turn.
def run(server: Client.Server, options: Args.Options, style: Render.Style) -> Result[Int]
  if options.yolo
    IO.warn(Client.yolo_warning(server))
  end

  inbox: Channel[Inbox.Input] = Channel.new(INBOX_CAPACITY)
  chat = Chat(server: server, id: "", style: style, inbox: inbox, options: options, yolo: Yolo.Yolo(on: options.yolo))
  for prompt in option_list(options.prompt)
    task = prompt
    if prompt == "-"
      task = stdin_text()
    end

    if task.strip == ""
      IO.warn("finn: the task is empty")
      return ok(EXIT_FAILED)
    end

    _ = Task.spawn(&watch_signals, inbox)
    sent = try send(try open(chat.with(eof: true, once: true), options), task)
    return ok(sent.exit.unwrap!) if sent.exit.some?

    return loop(sent.chat)
  end

  _ = Task.spawn(&read_lines, inbox)
  _ = Task.spawn(&watch_signals, inbox)
  loop(try open(chat, options))
end

private

struct Chat
  server: Client.Server
  id: String
  style: Render.Style
  inbox: Channel[Inbox.Input]
  ## What `/new` makes a session with.
  options: Args.Options
  stream: Optional[Task[Void]] = none
  generation: Int = 0
  last_event_id: Int = 0
  ## The events up to this id are a replay: their approval requests ask nothing, the pending ones are asked after it.
  replay_until: Int = 0
  ## The highest event id already printed, so a replay after a resync prints nothing twice.
  shown_id: Int = 0
  ## The size of the session's history the client has seen, so a resync prints only the rest.
  known: Int = 0
  ## The session has something in it: a history, a turn or a `!` command seen.
  used: Bool = false
  turn: Bool = false
  ## A `!` command of this client runs.
  shell: Bool = false
  stopping: Bool = false
  pending: List[Protocol.ApprovalRequested] = []
  asked: Bool = false
  flow: Render.Flow = Render.Flow.Idle
  eof: Bool = false
  ## Streams that ended in a row without a subscription the server accepted.
  reconnects: Int = 0
  ## `resync` events in a row, with no other event between.
  resyncs: Int = 0
  ## What `--yolo` allows without asking.
  yolo: Yolo.Yolo
  ## The model `/model` set, until the turn after it ends: a failed call there gets a warning.
  new_model: Optional[String] = none
  ## The tree `/tree` or `/fork` listed last, whose numbers `/tree N` and `/fork N` name.
  listed: Optional[Protocol.SessionTree] = none
  ## One task from the command line: the exit code is the status of its turn.
  once: Bool = false
  status: Int = 0
end

struct Step
  chat: Chat
  exit: Optional[Int] = none
end

def read_lines(inbox: Channel[Inbox.Input]) -> Void
  while true
    case IO.gets
      ok(line) -> break if not inbox.send(Inbox.Input.Line(line), SEND_MS).ok?
      error(_) ->
        _ = inbox.send(Inbox.Input.Eof, SEND_MS)
        break
    end
  end
end

def watch_signals(inbox: Channel[Inbox.Input]) -> Void
  case System.subscribe([System.Signal.Int, System.Signal.Term])
    ok(signals) ->
      while true
        case signals.recv(WAIT_MS)
          ok(System.Signal.Term) -> _ = inbox.send(Inbox.Input.Terminate, SEND_MS)
          ok(_) -> _ = inbox.send(Inbox.Input.Interrupt, SEND_MS)
          error(_) -> next
        end
      end

    error(e) -> IO.warn("Ctrl+C is not handled: #{e.message}")
  end
end

def open(chat: Chat, options: Args.Options) -> Result[Chat]
  opened = case options.session
    some(id) -> try resume(chat.with(id: id), id)
    none -> try create(chat, options)
  end

  ok(server_warnings(opened))
end

# The warnings the server logged since it started (the last of them) are notes of a session that starts or resumes; a
# one-shot run keeps its output to the answer.
def server_warnings(chat: Chat) -> Chat
  return chat if chat.once

  shown = chat
  case Client.server_log(chat.server, 0)
    ok(log) ->
      for line in Client.warning_notes(log)
        shown = note(shown, "[#{line}]")
      end

    error(_) -> nil
  end

  shown
end

def reload_command(chat: Chat) -> Result[Step]
  shown = chat
  for line in Client.reload_report(try Client.reload(chat.server))
    shown = note(shown, line)
  end

  ok(Step(chat: shown))
end

def logs_command(chat: Chat, count: Int) -> Result[Step]
  log = try Client.server_log(chat.server, count)
  shown = chat
  for line in log.lines
    shown = note(shown, line)
  end

  ok(Step(chat: shown))
end

def create(chat: Chat, options: Args.Options) -> Result[Chat]
  # A one-shot run (`-p`) in a script does not change the choice of the next sessions.
  request = try Client.new_session(
    options.cwd,
    options.model,
    options.api,
    options.provider,
    options.profile,
    options.prompt.none?,
  )

  created = try Client.create_session(chat.server, request)
  id = created.id
  ok(subscribe(profile_notes(note(chat, "[session #{id}]"), created.profile).with(id: id), 0))
end

def resume(chat: Chat, id: String) -> Result[Chat]
  session = try Client.session(chat.server, id)
  opened = attach(profile_notes(note(chat, "[session #{id}]"), session.profile), session, false)
  return ok(opened) if session.todos.empty?

  ok(note(opened, Render.todos(session.todos)))
end

# Prints the history the client has not shown yet, then subscribes to what the snapshot of the session says. While a
# turn runs, the replay from the start of the turn gives the whole turn; `skip_replay` reads only what comes next, for
# a server that no longer has that start.
def attach(chat: Chat, session: Protocol.Session, skip_replay: Bool) -> Chat
  missed = session.history.drop(chat.known)
  shown = chat
  if not missed.empty?
    shown = note(chat, Render.history(missed, chat.style))
  end

  running = session.turn_id.some?
  if chat.turn and not running
    shown = note(chat, "[the turn ended while the stream was away]")
  end

  from = Client.replay_from(session, skip_replay)

  fresh = shown.with(
    known: session.history.size,
    used: shown.used or not session.history.empty?,
    turn: running,
    shell: session.shell_id.some?,
    stopping: false,
    pending: session.pending_approvals,
    yolo: Yolo.attached(shown.yolo, session.turn_id, not skip_replay),
    asked: false,
    replay_until: session.last_event_id,
  )

  prompted(subscribe(fresh, from))
end

# Reads the events after `from`; what an older stream still sends is dropped by its generation.
def subscribe(chat: Chat, from: Int) -> Chat
  if chat.stream.some?
    Task.cancel(chat.stream.unwrap!)
  end

  generation = chat.generation + 1
  inbox = chat.inbox
  feed = Client.Feed(
    server: chat.server,
    session_id: chat.id,
    last_event_id: from,
    tell: ->(item) { inbox.send(Inbox.Input.Stream(generation, item), SEND_MS) },
  )

  chat.with(stream: some(Client.start(feed)), generation: generation, last_event_id: from)
end

def loop(chat: Chat) -> Result[Int]
  state = chat
  while true
    case state.inbox.recv(WAIT_MS)
      ok(input) ->
        step = try handle(state, input)
        state = step.chat
        return ok(left(state, step.exit.unwrap!)) if step.exit.some?

      error(_) -> next
    end
  end

  ok(0)
end

def handle(chat: Chat, input: Inbox.Input) -> Result[Step]
  case input
    Inbox.Input.Line(text) -> on_line(chat, text)
    Inbox.Input.Eof -> settled(prompted(chat.with(eof: true)))
    Inbox.Input.Interrupt -> on_interrupt(chat)
    Inbox.Input.Terminate -> ok(Step(chat: chat, exit: some(EXIT_TERMINATED)))
    Inbox.Input.Note(text) -> settled(prompted(note(chat, text)))
    Inbox.Input.Stream(generation, item) -> on_stream(chat, generation, item)
  end
end

def on_stream(chat: Chat, generation: Int, item: Client.Item) -> Result[Step]
  return ok(Step(chat: chat)) if generation != chat.generation

  case item
    Client.Item.Opened -> ok(Step(chat: chat.with(reconnects: 0)))
    Client.Item.Event(_, Protocol.Event.Resync) -> resync(chat)
    Client.Item.Event(id, event) -> on_event(chat.with(resyncs: 0), id, event)
    Client.Item.Skipped(reason) ->
      IO.warn(reason)
      ok(Step(chat: chat))
    Client.Item.Ended(reason) -> reconnect(chat, reason)
  end
end

# Only a call that reached no server needs the session's provider.
def warned(chat: Chat, failure: Protocol.Failure) -> Chat
  provider = ""
  if failure.kind == "llm.network"
    case Client.session(chat.server, chat.id)
      ok(session) -> provider = session.provider
      error(_) -> nil
    end
  end

  done = chat.with(new_model: none, shell: false)
  case Client.turn_warning(failure.kind, provider, chat.new_model)
    some(warning) -> note(done, "[warning] #{warning}")
    none -> done
  end
end

def on_event(chat: Chat, id: Optional[Int], event: Protocol.Event) -> Result[Step]
  seen = id.unwrap_or(chat.last_event_id)
  repeated = id.some? and seen <= chat.shown_id
  shown = chat.with(last_event_id: seen, shown_id: [chat.shown_id, seen].max.unwrap!)
  if not repeated
    shown = show(shown, Render.event(event, chat.style))
  end

  changed = case event
    Protocol.Event.TurnStarted(started) ->
      known = started.history_size.unwrap_or(shown.known)
      shown.with(
        turn: true,
        stopping: false,
        known: known,
        used: true,
        yolo: Yolo.running(shown.yolo, some(started.turn_id)),
      )
    # An error (a write of `shell_finished` that failed) also ends a command: no other event of it comes.
    Protocol.Event.Error(failure) if not repeated -> warned(shown, failure)
    Protocol.Event.Error(_) -> shown.with(shell: false)
    Protocol.Event.TurnFinished(finished) ->
      shown.with(
        new_model: none,
        turn: false,
        stopping: false,
        known: finished.history_size.unwrap_or(shown.known),
        status: exit_status(finished.stop_reason),
        yolo: Yolo.running(shown.yolo, none),
      )
    Protocol.Event.ApprovalRequested(request) -> shown.with(pending: added(shown.pending, request))
    Protocol.Event.ApprovalResolved(resolved) -> forgotten(shown, resolved.approval_id)
    Protocol.Event.MessageQueued(queued) -> shown.with(yolo: Yolo.steered(shown.yolo, queued))
    Protocol.Event.ShellStarted(_) -> shown.with(used: true)
    Protocol.Event.ShellFinished(_) -> shown.with(shell: false, stopping: false, used: true)
    _ -> shown
  end

  settled(prompted(changed))
end

def on_line(chat: Chat, raw: String) -> Result[Step]
  text = raw.strip
  case Client.parse_command(text)
    some(ok(command)) -> return on_command(chat, command)
    some(error(e)) -> return ok(Step(chat: note(chat, "[error] #{e.message}")))
    _ -> nil
  end

  return answered(chat, text) if chat.asked

  return ok(Step(chat: chat)) if text == ""

  for request in option_list(Client.parse_shell(text))
    return shell(chat, request)
  end

  send(chat, text)
end

def shell(chat: Chat, request: Protocol.RunShell) -> Result[Step]
  case Client.shell(chat.server, chat.id, request)
    ok(_) -> ok(Step(chat: chat.with(shell: true)))
    error(e) if e.kind == Protocol.KIND_SESSION_BUSY -> ok(Step(chat: note(chat, "[not run] #{e.message}")))
    error(e) -> ok(Step(chat: note(chat, "[error] #{e.message}")))
  end
end

# A line sent while a turn runs is queued: the turn reads it before its next model call. A one-shot run that cannot
# send its task fails.
def send(chat: Chat, text: String) -> Result[Step]
  case Client.send_message(chat.server, chat.id, text)
    ok(accepted) -> ok(Step(chat: chat.with(turn: true, yolo: Yolo.accepted(chat.yolo, accepted))))
    error(e) if e.kind == Protocol.KIND_SESSION_BUSY and chat.once ->
      ok(Step(chat: note(chat, "[error] #{e.message}"), exit: some(EXIT_FAILED)))
    error(e) if e.kind == Protocol.KIND_SESSION_BUSY -> ok(Step(chat: note(chat, "[not sent] #{e.message}")))
    error(e) if chat.once -> ok(Step(chat: note(chat, "[error] #{e.message}"), exit: some(EXIT_FAILED)))
    error(e) -> ok(Step(chat: note(chat, "[error] #{e.message}")))
  end
end

def answered(chat: Chat, text: String) -> Result[Step]
  case Render.answer(text)
    some(decision) -> settled(prompted(answer_head(chat, decision)))
    none -> ok(Step(chat: note(chat, Render.ANSWER_HINT)))
  end
end

# Sends the decision for the first pending approval. Another client may have answered first: that is not a failure. A
# POST that failed leaves the question pending, to be answered again.
def answer_head(chat: Chat, decision: Protocol.Decision) -> Chat
  request = chat.pending[0]
  case Client.approve(chat.server, chat.id, request.approval_id, decision)
    ok(_) -> forgotten(chat, request.approval_id)
    error(e) if e.kind == Protocol.KIND_APPROVAL_RESOLVED or e.kind == Protocol.KIND_APPROVAL_NOT_FOUND ->
      forgotten(note(chat, "[approval #{request.approval_id}] already answered"), request.approval_id)
    error(e) -> note(chat, "[error] the answer was not sent: #{e.message}")
  end
end

def on_command(chat: Chat, command: Client.Command) -> Result[Step]
  case command
    Client.Command.Quit -> ok(Step(chat: chat, exit: some(0)))
    Client.Command.Stop -> stop_command(chat)
    Client.Command.Help -> said(chat, Client.help(custom_of(chat), Client.CHAT_KEYS).join("\n"))
    Client.Command.Shortcuts -> said(chat, "[the keys of the full screen are listed by /shortcuts in finn]")
    Client.Command.Cost -> said(chat, "[/cost comes with the model catalog]")
    Client.Command.Login(_) ->
      said(chat, "[a key, a base URL or a sign-in is asked for on the full screen: finn login, or /login in finn]")
    Client.Command.Logout(name) -> logout_command(chat, name)
    Client.Command.New -> switch_command(chat, none)
    Client.Command.Resume(choice) -> resume_command(chat, choice)
    Client.Command.Tree(choice) -> tree_command(chat, choice, &branched)
    Client.Command.Fork(choice) -> tree_command(chat, choice, &forked)
    Client.Command.Clone -> moved_command(chat, -> { Client.fork(chat.server, chat.id, none) })
    Client.Command.Export(path, force) -> export_command(chat, path, force)
    Client.Command.Model(model) -> model_command(chat, model)
    Client.Command.Thinking(level) -> setting_command(chat, "thinking", level, Protocol.UpdateSession(effort: level))
    Client.Command.Confine(on) -> confine_command(chat, on)
    Client.Command.Profile(name) -> tried(chat, profile_command(chat, name))
    Client.Command.Mcp(name, reconnecting) -> tried(chat, mcp_command(chat, name, reconnecting))
    Client.Command.Compact -> said(compact_command(chat), "[compacting the history]")
    Client.Command.Logs(count) -> logs_command(chat, count)
    Client.Command.Reload -> reload_command(chat)
    Client.Command.Mouse -> said(chat, "[/mouse is for the full screen: finn]")
  end
end

def export_command(chat: Chat, path: Optional[String], force: Bool) -> Result[Step]
  written = case Client.exported(chat.server, chat.id)
    ok(exported) -> Client.saved(exported, Client.export_path(chat.id, path), force)
    error(e) -> error(e)
  end

  case written
    ok(file) -> said(chat, "[exported to #{Client.printable(file)}]")
    error(e) -> said(chat, "[error] #{Client.printable(e.message)}")
  end
end

# `/profile` lists the profiles, `*` before the session's; `/profile NAME` changes it, and says what it changed.
def profile_command(chat: Chat, name: Optional[String]) -> Result[Chat]
  for wanted in option_list(name)
    try Client.update_session(chat.server, chat.id, Protocol.UpdateSession(profile: some(wanted)))
    session = try Client.session(chat.server, chat.id)
    serving = Client.printable("#{session.provider}/#{session.model}")
    done = note(chat, "[profile #{Client.printable(wanted)} from the next turn: #{serving}]")
    for line in Client.profile_lines(session.profile).select { |l| l.start_with?("warning: ") }
      done = note(done, "[#{line}]")
    end

    return ok(done)
  end

  current = (try Client.session(chat.server, chat.id)).profile.map { |p| p.name }.unwrap_or("")
  ok(note(chat, Client.profile_listing(try Client.list_profiles(chat.server, chat.id), current).join("\n")))
end

# `/mcp` lists the MCP servers, `/mcp NAME` the tools of one, and `/mcp reconnect NAME` starts it again.
def mcp_command(chat: Chat, name: Optional[String], reconnecting: Bool) -> Result[Chat]
  for wanted in option_list(name)
    if reconnecting
      server = try Client.mcp_reconnect(chat.server, chat.id, wanted)
      return ok(note(chat, Client.mcp_listing(Protocol.McpStatus(servers: [server])).join("\n")))
    end

    return ok(note(chat, Client.mcp_tools(try Client.mcp_status(chat.server, chat.id), wanted).join("\n")))
  end

  ok(note(chat, Client.mcp_listing(try Client.mcp_status(chat.server, chat.id)).join("\n")))
end

# The session's slash commands for `/help`; none when the server does not list them.
def custom_of(chat: Chat) -> List[Client.Usage]
  case Client.list_commands(chat.server, chat.id)
    ok(list) -> Client.custom(list)
    error(_) -> []
  end
end

def logout_command(chat: Chat, name: Optional[String]) -> Result[Step]
  case Client.logout(chat.server, name)
    ok(_) -> said(chat, "[#{Client.logged_out(name)}]")
    error(e) -> said(chat, "[error] #{e.message}")
  end
end

def stop_command(chat: Chat) -> Result[Step]
  return stop(chat) if chat.turn or chat.shell

  said(chat, "[no turn is running]")
end

def resume_command(chat: Chat, choice: Optional[String]) -> Result[Step]
  return tried(chat, listed(chat)) if choice.none?

  switch_command(chat, choice)
end

# The tree without a choice; else what `go` does with the entry the choice names in the last listing, so a message
# another client adds since does not change what a number names.
def tree_command(chat: Chat, choice: Optional[String], go: Fn[Chat, Int, Result[Protocol.Branched]]) -> Result[Step]
  case choice
    none -> tried(chat, tree_listed(chat))
    some(picked) ->
      case chat.listed
        some(tree) -> moved_command(chat, -> { go.call(chat, try Client.tree_entry(tree, picked)) })
        none -> said(chat, "[list the messages first: /tree]")
      end
  end
end

def tree_listed(chat: Chat) -> Result[Chat]
  tree = try Client.tree(chat.server, chat.id)
  return ok(note(chat, "[no messages yet]")) if tree.nodes.empty?

  ok(note(chat, Client.tree_listing(tree).join("\n")).with(listed: some(tree)))
end

def branched(chat: Chat, entry: Int) -> Result[Protocol.Branched] = Client.branch(chat.server, chat.id, entry)

def forked(chat: Chat, entry: Int) -> Result[Protocol.Branched] = Client.fork(chat.server, chat.id, some(entry))

# The session that a branch, a fork or a copy goes on in, drawn again from its start, with the message it went back
# before.
def moved_command(chat: Chat, move: Fn[Result[Protocol.Branched]]) -> Result[Step]
  return said(chat, "[a turn is running: /stop it first]") if chat.turn

  tried(chat, moved(chat, move))
end

def moved(chat: Chat, move: Fn[Result[Protocol.Branched]]) -> Result[Chat]
  done = try move.call()
  opened = try resume(fresh(chat).with(id: done.id), done.id)
  return ok(opened) if done.text.empty?

  ok(note(opened, "[went back before: #{Client.printable(done.text)}]"))
end

# A new session (no choice), or the session `/resume` chose.
def switch_command(chat: Chat, choice: Optional[String]) -> Result[Step]
  return said(chat, "[a turn is running: /stop it first]") if chat.turn

  case choice
    some(picked) -> tried(chat, switched(chat, picked))
    none -> tried(chat, create(fresh(chat), chat.options))
  end
end

def setting_command(chat: Chat, name: String, value: Optional[String], change: Protocol.UpdateSession) -> Result[Step]
  case value
    some(text) -> tried(chat, changed(chat, change, "[#{name} #{text} from the next turn]"))
    none -> tried(chat, shown_setting(chat, name))
  end
end

def confine_command(chat: Chat, on: Optional[Bool]) -> Result[Step]
  case on
    some(wanted) -> tried(chat, changed(chat, Protocol.UpdateSession(confine: on), confine_note(wanted)))
    none -> tried(chat, confine_shown(chat))
  end
end

def confine_shown(chat: Chat) -> Result[Chat]
  ok(note(chat, "[#{Client.confined(try Client.session(chat.server, chat.id))}]"))
end

def confine_note(on: Bool) -> String
  return "[the file tools stay in the session folder from the next turn]" if on

  "[the file tools reach any path from the next turn]"
end

def said(chat: Chat, text: String) -> Result[Step] = ok(Step(chat: note(chat, text)))

# A command that failed says why; the session goes on.
def tried(chat: Chat, result: Result[Chat]) -> Result[Step]
  case result
    ok(next_chat) -> ok(Step(chat: next_chat))
    error(e) -> said(chat, "[error] #{e.message}")
  end
end

# The state of no session yet, with the stream that `subscribe` replaces.
def fresh(chat: Chat) -> Chat
  Chat(
    server: chat.server,
    id: "",
    style: chat.style,
    inbox: chat.inbox,
    options: chat.options,
    yolo: Yolo.Yolo(on: chat.yolo.on),
    stream: chat.stream,
    generation: chat.generation,
  )
end

def listed(chat: Chat) -> Result[Chat]
  lines = Client.listing(try Client.list_sessions(chat.server), chat.id)
  return ok(note(chat, "[no sessions]")) if lines.empty?

  ok(note(chat, lines.join("\n")))
end

def switched(chat: Chat, choice: String) -> Result[Chat]
  id = try Client.pick(try Client.list_sessions(chat.server), choice, chat.id)
  resume(fresh(chat).with(id: id), id)
end

def shown_setting(chat: Chat, name: String) -> Result[Chat]
  session = try Client.session(chat.server, chat.id)
  return ok(note(chat, "[model (#{session.provider}) #{session.model}]")) if name == "model"

  ok(note(chat, "[#{Client.thinking(session)}]"))
end

def model_command(chat: Chat, model: Optional[String]) -> Result[Step]
  case model
    some(text) -> tried(chat, model_changed(chat, text))
    none -> tried(chat, shown_setting(chat, "model"))
  end
end

def model_changed(chat: Chat, text: String) -> Result[Chat]
  current = (try Client.session(chat.server, chat.id)).provider
  change = try Client.model_change(try Client.list_providers(chat.server), current, text)
  changed(chat, change, "[model #{text} from the next turn]")
end

def changed(chat: Chat, change: Protocol.UpdateSession, done: String) -> Result[Chat]
  try Client.update_session(chat.server, chat.id, change)
  shown = note(chat, done)
  return ok(shown) if change.model.none?

  ok(shown.with(new_model: change.model))
end

# The summary takes as long as a turn: a task asks for it and puts the outcome on the inbox.
def compact_command(chat: Chat) -> Chat
  server = chat.server
  id = chat.id
  inbox = chat.inbox
  _ = Task.spawn(-> { _ = inbox.send(Inbox.Input.Note(compacted(server, id)), SEND_MS) })
  chat
end

def compacted(server: Client.Server, id: String) -> String
  case Client.compact(server, id)
    ok(folded) -> "[#{Client.compacted(folded)}]"
    error(e) -> "[error] #{e.message}"
  end
end

def stop(chat: Chat) -> Result[Step]
  case Client.stop(chat.server, chat.id)
    ok(_) -> ok(Step(chat: note(chat, "[stopping the #{stopped(chat)}: Ctrl+C again leaves]").with(stopping: true)))
    error(e) -> ok(Step(chat: note(chat, "[error] the stop was not sent: #{e.message}").with(stopping: true)))
  end
end

def stopped(chat: Chat) -> String
  return "command" if chat.shell and not chat.turn

  "turn"
end

def on_interrupt(chat: Chat) -> Result[Step]
  return stop(chat) if (chat.turn or chat.shell) and not chat.stopping

  ok(Step(chat: note(chat, "[interrupted]"), exit: some(EXIT_INTERRUPTED)))
end

# The end of the input leaves once no turn runs; a one-shot run with the status of its turn.
def settled(chat: Chat) -> Result[Step]
  return ok(Step(chat: chat, exit: some(chat.status))) if chat.eof and not chat.turn and chat.once
  return ok(Step(chat: chat, exit: some(0))) if chat.eof and not chat.turn and not chat.shell

  ok(Step(chat: chat))
end

# Leaving a session of the line chat says how to come back to it, unless it has nothing in it yet.
def left(chat: Chat, code: Int) -> Int
  return code if chat.once

  for hint in option_list(Client.resume_hint("finn chat", chat.id, not chat.used))
    _ = note(chat, "[#{hint}]")
  end

  case Client.server_log(chat.server, 0)
    ok(log) ->
      for report in option_list(Client.warning_report(log))
        _ = note(chat, report)
      end

    error(_) -> nil
  end

  code
end

def exit_status(reason: Protocol.StopReason) -> Int
  case reason
    Protocol.StopReason.EndTurn -> 0
    Protocol.StopReason.Cancelled -> EXIT_INTERRUPTED
    _ -> EXIT_FAILED
  end
end

def stdin_text() -> String
  lines: List[String] = []
  while true
    case IO.gets
      ok(line) -> lines = lines.push(line)
      error(_) -> break
    end
  end

  text = lines.join("\n")
  while text.end_with?("\n")
    text = text.slice(0, text.length - 1)
  end

  text
end

def resync(chat: Chat) -> Result[Step]
  return error("the server keeps asking to read the session again", kind: "cli.resync") if chat.resyncs >= MAX_RESYNCS

  noted = note(chat, "[resync: reading the session again]")
  session = try Client.session(noted.server, noted.id)
  ok(Step(chat: attach(noted.with(resyncs: chat.resyncs + 1), session, chat.resyncs >= 1)))
end

def reconnect(chat: Chat, reason: String) -> Result[Step]
  reconnects = chat.reconnects + 1
  return error("lost the event stream: #{reason}", kind: "cli.stream") if reconnects > MAX_RECONNECTS

  IO.warn("[the event stream ended: #{reason}; reconnecting]")
  Task.sleep(RECONNECT_MS * reconnects)
  try Client.recheck(chat.server)
  ok(Step(chat: subscribe(chat.with(reconnects: reconnects), chat.last_event_id)))
end

def added(
  pending: List[Protocol.ApprovalRequested],
  request: Protocol.ApprovalRequested,
) -> List[Protocol.ApprovalRequested]
  known = pending.any? { |p| p.approval_id == request.approval_id }
  return pending if known

  pending.push(request)
end

# The approval is answered: nothing waits for it, and the next one is asked.
def forgotten(chat: Chat, approval_id: String) -> Chat
  head = not chat.pending.empty? and chat.pending[0].approval_id == approval_id
  rest = chat.pending.select { |p| p.approval_id != approval_id }
  return chat.with(pending: rest, asked: false) if head

  chat.with(pending: rest)
end

# Asks the first pending approval once the replay is over; `--yolo` allows those of an own turn (see `Yolo`). With the
# input at its end nobody can answer: every pending approval left is denied, however many come.
def prompted(chat: Chat) -> Chat
  state = chat
  while not state.pending.empty? and state.last_event_id >= state.replay_until
    head = state.pending[0]
    if Yolo.allows?(state.yolo)
      state = decided(state, Protocol.Decision.Allow)
    elsif state.eof
      state = decided(state, Protocol.Decision.Deny)
    else
      return state if state.asked

      return show(state, some(Render.prompt(head))).with(asked: true)
    end
  end

  state
end

# Answers the first pending approval; one whose answer failed is dropped, so nothing waits for it.
def decided(chat: Chat, decision: Protocol.Decision) -> Chat
  head = chat.pending[0]
  state = answer_head(chat, decision)
  if not state.pending.empty? and state.pending[0].approval_id == head.approval_id
    return forgotten(state, head.approval_id)
  end

  state
end

def note(chat: Chat, text: String) -> Chat = show(chat, some(Render.line(text)))

def profile_notes(chat: Chat, profile: Optional[Protocol.Profile]) -> Chat
  shown = chat
  for line in Client.profile_lines(profile)
    shown = note(shown, "[#{line}]")
  end

  shown
end

# A one-shot run prints only the answer on stdout; its other lines go to stderr, and so does its thinking.
def show(chat: Chat, out: Optional[Render.Out]) -> Chat
  case out
    none -> chat
    some(piece) ->
      written = Render.put(chat.flow, piece)
      if not chat.once or piece.flow == Render.Flow.Text
        print(written.text)
      else
        aside(written.text)
      end

      IO.flush()
      chat.with(flow: written.flow)
  end
end

# The newline that closes the answer's open line stays on stdout; the line itself goes to stderr.
def aside(text: String) -> Void
  rest = text
  if rest.start_with?("\n")
    print("\n")
    rest = rest.slice(1, rest.length - 1)
  end

  if rest.end_with?("\n")
    rest = rest.slice(0, rest.length - 1)
  end

  IO.warn(rest)
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
