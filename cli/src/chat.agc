## One session on the terminal: the loop that reads what the user types, the signals and the events of the server, and
## what it does with each. The state is one immutable `Chat`; each input gives the next one.

import Client from "pkg/client/client"
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
    IO.warn("--yolo: every tool call is approved")
  end

  inbox: Channel[Inbox.Input] = Channel.new(INBOX_CAPACITY)
  chat = Chat(server: server, id: "", style: style, inbox: inbox, yolo: options.yolo)
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
  stream: Optional[Task[Void]] = none
  generation: Int = 0
  last_event_id: Int = 0
  ## The events up to this id are a replay: their approval requests ask nothing, the pending ones are asked after it.
  replay_until: Int = 0
  ## The highest event id already printed, so a replay after a resync prints nothing twice.
  shown_id: Int = 0
  ## The size of the session's history the client has seen, so a resync prints only the rest.
  known: Int = 0
  turn: Bool = false
  stopping: Bool = false
  pending: List[Protocol.ApprovalRequested] = []
  asked: Bool = false
  flow: Render.Flow = Render.Flow.Idle
  eof: Bool = false
  ## Streams that ended in a row without a subscription the server accepted.
  reconnects: Int = 0
  ## `resync` events in a row, with no other event between.
  resyncs: Int = 0
  ## Every approval of this run is allowed without asking.
  yolo: Bool = false
  ## The approvals that were pending when the client attached: `--yolo` leaves them to be asked.
  inherited: List[String] = []
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
  case options.session
    some(id) -> resume(chat.with(id: id), id)
    none -> create(chat, options)
  end
end

def create(chat: Chat, options: Args.Options) -> Result[Chat]
  cwd = case options.cwd
    some(dir) -> dir
    none -> try Path.cwd()
  end

  id = try Client.create_session(chat.server, Protocol.NewSession(cwd: cwd, model: options.model, api: options.api))
  ok(subscribe(note(chat, "[session #{id}]").with(id: id), 0))
end

def resume(chat: Chat, id: String) -> Result[Chat]
  session = try Client.session(chat.server, id)
  ok(attach(note(chat, "[session #{id}]"), session, false))
end

# Prints the history the client has not shown yet, then subscribes to what the snapshot of the session says. While a
# turn runs, the replay from the start of the turn gives the whole turn; `skip_replay` reads only what comes next, for
# a server that no longer has that start.
def attach(chat: Chat, session: Protocol.Session, skip_replay: Bool) -> Chat
  missed = session.history.drop(chat.known)
  shown = chat
  if not missed.empty?
    shown = note(chat, Render.history(missed))
  end

  running = session.turn_id.some?
  if chat.turn and not running
    shown = note(chat, "[the turn ended while the stream was away]")
  end

  from = session.last_event_id
  if running and not skip_replay
    from = session.turn_from_event_id.unwrap_or(session.last_event_id)
  end

  fresh = shown.with(
    known: session.history.size,
    turn: running,
    stopping: false,
    pending: session.pending_approvals,
    inherited: shown.inherited + session.pending_approvals.map { |p| p.approval_id },
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
        return ok(step.exit.unwrap!) if step.exit.some?

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

def on_event(chat: Chat, id: Optional[Int], event: Protocol.Event) -> Result[Step]
  seen = id.unwrap_or(chat.last_event_id)
  repeated = id.some? and seen <= chat.shown_id
  shown = chat.with(last_event_id: seen, shown_id: [chat.shown_id, seen].max.unwrap!)
  if not repeated
    shown = show(shown, Render.event(event, chat.style))
  end

  changed = case event
    Protocol.Event.TurnStarted(started) ->
      shown.with(turn: true, stopping: false, known: started.history_size.unwrap_or(shown.known))
    Protocol.Event.TurnFinished(finished) ->
      shown.with(
        turn: false,
        stopping: false,
        known: finished.history_size.unwrap_or(shown.known),
        status: exit_status(finished.stop_reason),
      )
    Protocol.Event.ApprovalRequested(request) -> shown.with(pending: added(shown.pending, request))
    Protocol.Event.ApprovalResolved(resolved) -> forgotten(shown, resolved.approval_id)
    _ -> shown
  end

  settled(prompted(changed))
end

def on_line(chat: Chat, raw: String) -> Result[Step]
  text = raw.strip
  return ok(Step(chat: chat, exit: some(0))) if text == "/quit"

  return answered(chat, text) if chat.asked

  return stop(chat) if text == "/stop" and chat.turn

  return ok(Step(chat: chat)) if text == ""

  send(chat, text)
end

# A line sent while a turn runs is queued: the turn reads it before its next model call. A one-shot run that cannot
# send its task fails.
def send(chat: Chat, text: String) -> Result[Step]
  case Client.send_message(chat.server, chat.id, text)
    ok(_) -> ok(Step(chat: chat.with(turn: true)))
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

def stop(chat: Chat) -> Result[Step]
  case Client.stop(chat.server, chat.id)
    ok(_) -> ok(Step(chat: note(chat, "[stopping the turn: Ctrl+C again leaves]").with(stopping: true)))
    error(e) -> ok(Step(chat: note(chat, "[error] the stop was not sent: #{e.message}").with(stopping: true)))
  end
end

def on_interrupt(chat: Chat) -> Result[Step]
  return stop(chat) if chat.turn and not chat.stopping

  ok(Step(chat: note(chat, "[interrupted]"), exit: some(EXIT_INTERRUPTED)))
end

# The end of the input leaves once no turn runs; a one-shot run with the status of its turn.
def settled(chat: Chat) -> Result[Step]
  return ok(Step(chat: chat, exit: some(chat.status))) if chat.eof and not chat.turn and chat.once
  return ok(Step(chat: chat, exit: some(0))) if chat.eof and not chat.turn

  ok(Step(chat: chat))
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

# Asks the first pending approval once the replay is over. With `--yolo` the approvals of this run are allowed; the
# ones pending before it are asked. With the input at its end nobody can answer: every pending approval left is
# denied, however many come.
def prompted(chat: Chat) -> Chat
  state = chat
  while not state.pending.empty? and state.last_event_id >= state.replay_until
    head = state.pending[0]
    if state.yolo and not state.inherited.include?(head.approval_id)
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
