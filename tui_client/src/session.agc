## A session opened, attached or resumed, and the stream of its events read and drawn.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import Approvals from "approvals"
import Calls from "calls"
import Args from "args"
import Git from "git"
import Transcript from "transcript"
import Yolo from "pkg/client/yolo"
import State from "state"
import Answering from "answering"
import Turn from "turn"

## The resyncs in a row after which the client ends.
MAX_RESYNCS = 2

## A signal ends the client; a wait that ended without one waits again. An interrupt while the editor of Ctrl+G has the
## terminal does not.
def signalled(app: State.Model, signal: Optional[System.Signal]) -> State.Model
  case signal
    some(System.Signal.Int) if app.editing -> State.effect(app, State.listen(app.signals))
    some(got) -> app.with(exit: some(128 + System.signal_number(got)))
    none if app.signals.closed? -> app
    none -> State.effect(app, State.listen(app.signals))
  end
end

def rechecked(app: State.Model, result: Result[Void]) -> State.Model
  case result
    ok(_) -> subscribe(app, app.last_event_id)
    error(e) -> app.with(failure: some(e.message))
  end
end

## The items of the current stream, then the next read of it while it goes on.
def streamed(app: State.Model, items: List[Client.Item]) -> State.Model
  generation = app.generation
  done = app
  for item in items
    done = on_stream(done, item)
    break if done.failure.some? or done.generation != generation
  end

  ended = items.any? { |item| ended?(item) }
  return done if ended or done.failure.some? or done.generation != generation or done.feed.none?

  State.effect(done, read_feed(generation, done.feed.unwrap!))
end

def open(app: State.Model, options: Args.Options) -> Result[State.Model]
  case options.session
    some(id) -> resume(app, id)
    none -> create(app)
  end
end

def create(app: State.Model) -> Result[State.Model]
  options = app.options
  request = try Client.new_session(options.cwd, options.model, options.api, options.provider, options.profile)
  cwd = request.cwd
  id = try app.backend.create_session.call(request)
  session = try app.backend.session.call(id)
  serving = State.serving_of(session)
  made = app.with(
    id: id,
    cwd: cwd,
    opened: app.opened + 1,
    serving: serving,
    usage: none,
    branch: "",
    profile: profile_name(session),
  )

  ok(
    read_branch(
      subscribe(profile_notices(State.noted(with_custom(made, id, session.cwd), "session #{id}"), session), 0),
    ),
  )
end

def resume(app: State.Model, id: String) -> Result[State.Model]
  session = try app.backend.session.call(id)
  ok(profile_notices(State.noted(attach(app.with(id: id), session, false), "session #{id}"), session))
end

## The slash commands of session `id` in folder `cwd`, read when the list is of another folder; none when the server
## does not list them.
def with_custom(app: State.Model, id: String, cwd: String) -> State.Model
  return app if app.custom_dir == some(cwd)

  case app.backend.list_commands.call(id)
    ok(list) -> app.with(custom: Client.custom(list), custom_dir: some(cwd))
    error(_) -> app.with(custom: [], custom_dir: some(cwd))
  end
end

## The warnings of the server about the session's profile, as notices.
def profile_notices(app: State.Model, session: Protocol.Session) -> State.Model
  lines = Client.profile_lines(session.profile).select { |line| line.start_with?("warning: ") }
  noted = app
  for line in lines
    noted = State.noted(noted, line)
  end

  noted
end

## The name of the session's profile for the footer; empty for the built-in `build`.
def profile_name(session: Protocol.Session) -> String
  case session.profile
    some(p) if p.name == "build" and p.source == "built-in" -> ""
    some(p) if p.source.empty? -> "#{Client.printable(p.name)} (does not load)"
    some(p) -> Client.printable(p.name)
    none -> ""
  end
end

## The stream held while messages were sent goes on once every reply came.
def released(app: State.Model) -> State.Model
  return app if not app.outbox.empty? or app.held.empty?

  streamed(app.with(held: []), app.held)
end

## The state of no session yet, with the stream that `subscribe` replaces; the follow-ups not sent wait in the prompt.
def fresh(app: State.Model) -> State.Model
  kept = app.with(prompt: "", cursor: 0)
  if not app.follow_ups.empty?
    kept = Turn.put_back(app)
  end

  State.seed(app.backend, app.options, app.signals, app.width, app.height).with(
    prompt: kept.prompt,
    cursor: kept.cursor,
    thinking: app.thinking,
    tools: app.tools,
    theme: app.theme,
    stream: app.stream,
    feed: app.feed,
    generation: app.generation,
    now: app.now,
    clock_s: app.clock_s,
    effects: app.effects,
    opened: app.opened,
    custom: app.custom,
    custom_dir: app.custom_dir,
  )
end

## The command that reads the next items of the stream `feed` of `generation`.
def read_feed(generation: Int, feed: Channel[Client.Item]) -> TUI.Cmd[State.Msg]
  TUI.Cmd.Run(-> { State.Msg.Stream(generation, drained(feed)) })
end

private

FEED_CAPACITY = 1024
# The most stream items one message carries, so a long stream still lets the keys in between draws.
FEED_BATCH = 256
SEND_MS = 30_000
RECONNECT_MS = 300
MAX_RECONNECTS = 3

def same_folder(app: State.Model, cwd: String) -> String
  return app.branch if cwd == app.cwd

  ""
end

# The branch may change with a turn or a `!` command (`git switch`): it is read again after each.
def read_branch(app: State.Model) -> State.Model
  return app if app.cwd.empty?

  opened = app.opened
  cwd = app.cwd
  State.effect(app, TUI.Cmd.Run(-> { State.Msg.Branch(opened, Git.branch(cwd)) }))
end

def drained(feed: Channel[Client.Item]) -> List[Client.Item]
  items: List[Client.Item] = []
  got = feed.recv(State.WAIT_MS)
  while got.ok? and items.size < FEED_BATCH
    items = items.push(got.unwrap!)
    got = feed.recv(0)
  end

  items
end

def ended?(item: Client.Item) -> Bool
  case item
    Client.Item.Ended(_) -> true
    _ -> false
  end
end

# Draws the history of the session and reads the events after it; while a turn runs, from the start of the turn, unless
# `skip_replay` (a server that no longer has that start).
def attach(app: State.Model, session: Protocol.Session, skip_replay: Bool) -> State.Model
  from = Client.replay_from(session, skip_replay)

  entries = Transcript.from_history(session.history)
  if not session.todos.empty?
    entries = Transcript.note(entries, todos(session.todos))
  end

  fresh = app.with(
    serving: State.serving_of(session),
    profile: profile_name(session),
    opened: app.opened + 1,
    cwd: session.cwd,
    usage: session.usage,
    branch: same_folder(app, session.cwd),
    entries: entries,
    history: entries.select { |entry| entry.kind == Transcript.Kind.User }.map { |entry| entry.text },
    files: none,
    reading_files: false,
    turn: session.turn_id.some?,
    shell: session.shell_id.some?,
    effort: State.wanted_level(app, session.effort),
    confirmed: session.effort,
    stopping: false,
    shown_id: from,
    approvals: Approvals.replaced(app.approvals, session.pending_approvals, app.now),
    yolo: Yolo.attached(app.yolo, session.turn_id, not skip_replay),
  )

  subscribed = read_branch(subscribe(with_custom(fresh, session.id, session.cwd), from))
  return subscribed if session.turn_id.some?

  # The end of the turn they waited for was not seen.
  Turn.after_turn(subscribed, Protocol.StopReason.EndTurn)
end

# A new reader of the stream from `from`; the old one stops, and its channel is closed so its last read ends.
def subscribe(app: State.Model, from: Int) -> State.Model
  for task in State.option_list(app.stream)
    Task.cancel(task)
  end

  for old in State.option_list(app.feed)
    old.close
  end

  generation = app.generation + 1
  feed: Channel[Client.Item] = Channel.new(FEED_CAPACITY)
  started = app.with(
    stream: some(app.backend.subscribe.call(app.id, from, ->(item) { feed.send(item, SEND_MS) })),
    feed: some(feed),
    generation: generation,
    last_event_id: from,
    held: [],
  )

  State.effect(started, read_feed(generation, feed))
end

def on_stream(app: State.Model, item: Client.Item) -> State.Model
  case item
    Client.Item.Opened -> app.with(reconnects: 0)
    Client.Item.Event(_, Protocol.Event.Resync) -> resync(app)
    Client.Item.Event(id, event) -> on_event(app.with(resyncs: 0), id, event)
    Client.Item.Skipped(reason) -> State.noted(app, reason)
    Client.Item.Ended(reason) -> reconnect(app, reason)
  end
end

def on_event(app: State.Model, id: Optional[Int], event: Protocol.Event) -> State.Model
  seen = id.unwrap_or(app.last_event_id)
  return app.with(last_event_id: seen) if id.some? and seen <= app.shown_id

  shown = app.with(last_event_id: seen, shown_id: seen)
  case event
    Protocol.Event.TextDelta(delta) ->
      shown.with(entries: Transcript.add(shown.entries, Transcript.Kind.Assistant, delta.text))
    Protocol.Event.ThinkingDelta(delta) ->
      shown.with(entries: Transcript.add(shown.entries, Transcript.Kind.Thinking, delta.text))
    Protocol.Event.TurnStarted(started) ->
      shown.with(turn: true, yolo: Yolo.running(shown.yolo, some(started.turn_id)))
    Protocol.Event.TurnFinished(done) ->
      ended = shown.with(turn: false, stopping: false, new_model: none, yolo: Yolo.running(shown.yolo, none))
      read_branch(Turn.after_turn(finished(ended, done.stop_reason), done.stop_reason))
    Protocol.Event.Usage(usage) -> shown.with(usage: some(usage))
    Protocol.Event.ApprovalRequested(request) if Yolo.allows?(shown.yolo) -> Answering.allowed(shown, request)
    Protocol.Event.ApprovalRequested(request) ->
      shown.with(approvals: Approvals.requested(shown.approvals, request, app.now))
    Protocol.Event.ApprovalResolved(done) ->
      decided = "approval #{done.approval_id}: #{Protocol.decision_name(done.decision)}"
      State.noted(Answering.resolved(shown, done.approval_id), "#{decided} (#{Protocol.source_name(done.source)})")
    Protocol.Event.ToolStarted(tool) -> shown.with(entries: Transcript.tool_started(shown.entries, tool))
    Protocol.Event.ToolFinished(tool) -> shown.with(entries: Transcript.tool_finished(shown.entries, tool))
    Protocol.Event.ShellStarted(started) ->
      tool = Protocol.ToolStarted(call_id: started.shell_id, name: Calls.BASH, summary: started.command)
      shown.with(shell: true, entries: Transcript.tool_started(shown.entries, tool))
    Protocol.Event.ShellFinished(done) ->
      # Started again in place, so a command whose start was not seen still draws as one.
      start = Protocol.ToolStarted(call_id: done.shell_id, name: Calls.BASH, summary: done.command)
      tool = Protocol.ToolFinished(
        call_id: done.shell_id,
        ok: done.ok,
        summary: "",
        duration_ms: done.duration_ms,
        output: some(done.output),
      )

      aside = ""
      if not done.context
        aside = "not sent to the model"
      end

      # A command that a restart cut has no duration.
      timed = done.duration_ms > 0
      entries = Transcript.tool_finished(Transcript.tool_started(shown.entries, start), tool, aside, timed)
      read_branch(shown.with(shell: false, stopping: false, entries: entries))
    # An error (a write of `shell_finished` that failed) also ends a command: no other event of it comes.
    Protocol.Event.Error(failure) ->
      failed = State.noted(shown.with(shell: false), "error: #{failure.kind}: #{failure.message}")
      case shown.new_model
        some(model) -> State.noted(failed.with(new_model: none), "warning: #{Client.model_warning(model)}")
        none -> failed
      end

    Protocol.Event.MessageQueued(queued) ->
      steered = shown.with(yolo: Yolo.steered(shown.yolo, queued))
      State.noted(steered, "queued: #{Client.printable(queued.text)}")
    Protocol.Event.Todos(list) -> State.noted(shown, todos(list.todos))
    _ -> shown
  end
end

## The model's todo list as a notice, one item a line.
def todos(list: List[Protocol.Todo]) -> String
  return "todos: none" if list.empty?

  (["todos:"] + Client.todo_lines(list)).join("\n")
end

def finished(app: State.Model, reason: Protocol.StopReason) -> State.Model
  case reason
    Protocol.StopReason.EndTurn -> app
    Protocol.StopReason.Cancelled -> State.noted(app, "stopped")
    _ -> State.noted(app, "the turn ended: #{Protocol.stop_reason_name(reason)}")
  end
end

def resync(app: State.Model) -> State.Model
  return app.with(failure: some("the server keeps asking to read the session again")) if app.resyncs >= MAX_RESYNCS

  case app.backend.session.call(app.id)
    ok(session) -> attach(app.with(resyncs: app.resyncs + 1), session, app.resyncs >= 1)
    error(e) -> app.with(failure: some(e.message))
  end
end

# The stream is read again after a pause that grows, once the server is checked to be the same version.
def reconnect(app: State.Model, reason: String) -> State.Model
  reconnects = app.reconnects + 1
  return app.with(failure: some("lost the event stream: #{reason}")) if reconnects > MAX_RECONNECTS

  backend = app.backend
  generation = app.generation
  pause = RECONNECT_MS * reconnects
  back = TUI.Cmd.Run(
    -> {
      Task.sleep(pause)
      State.Msg.Rechecked(generation, backend.recheck.call())
    },
  )

  State.effect(app.with(reconnects: reconnects), back)
end
