## One session on the terminal: the loop that reads what the user types, the signals and the events of the server, and
## what it does with each. The state is one immutable `Chat`; each input gives the next one.

import Protocol from "pkg/protocol/protocol"
import Args from "args"
import Client from "client"
import Inbox from "inbox"
import Render from "render"
import Stream from "stream"

INBOX_CAPACITY = 256
WAIT_MS = 3_600_000
SEND_MS = 30_000
RECONNECT_MS = 300
MAX_FAILURES = 3
EXIT_INTERRUPTED = 130
EXIT_TERMINATED = 143

## Runs the session until the user leaves: the exit code, or an error when the session cannot go on.
def run(server: Client.Server, options: Args.Options, style: Render.Style) -> Result[Int]
  inbox: Channel[Inbox.Input] = Channel.new(INBOX_CAPACITY)
  _ = Task.spawn(&read_lines, inbox)
  _ = Task.spawn(&watch_signals, inbox)
  chat = try open(Chat(server: server, id: "", style: style, inbox: inbox), options)
  loop(chat)
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
  turn: Bool = false
  stopping: Bool = false
  pending: List[Protocol.ApprovalRequested] = []
  asked: Bool = false
  flow: Render.Flow = Render.Flow.Idle
  eof: Bool = false
  failures: Int = 0
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

  id = try Client.create_session(chat.server, Protocol.NewSession(cwd: cwd, model: options.model))
  print_line("[session #{id}]")
  ok(subscribe(chat.with(id: id), 0))
end

def resume(chat: Chat, id: String) -> Result[Chat]
  session = try Client.session(chat.server, id)
  print_line("[session #{id}]")
  if not session.history.empty?
    print_line(Render.history(session.history))
  end

  running = session.turn_id.some?
  from = session.last_event_id
  if running
    from = session.turn_from_event_id.unwrap_or(session.last_event_id)
  end

  resumed = chat.with(turn: running, pending: session.pending_approvals, replay_until: session.last_event_id)
  ok(prompted(subscribe(resumed, from)))
end

# Reads the events after `from`; what an older stream still sends is dropped by its generation.
def subscribe(chat: Chat, from: Int) -> Chat
  case chat.stream
    some(old) -> Task.cancel(old)
    none -> Task.sleep(0)
  end

  generation = chat.generation + 1
  feed = Stream.Feed(
    server: chat.server,
    session_id: chat.id,
    last_event_id: from,
    generation: generation,
    inbox: chat.inbox,
  )

  chat.with(stream: some(Stream.start(feed)), generation: generation, last_event_id: from)
end

def loop(chat: Chat) -> Result[Int]
  state = chat
  while true
    case state.inbox.recv(WAIT_MS)
      ok(input) ->
        step = try handle(state, input)
        state = step.chat
        case step.exit
          some(code) -> return ok(code)
          none -> Task.sleep(0)
        end

      error(_) -> next
    end
  end

  ok(0)
end

def handle(chat: Chat, input: Inbox.Input) -> Result[Step]
  case input
    Inbox.Input.Line(text) -> on_line(chat, text)
    Inbox.Input.Eof -> on_eof(chat.with(eof: true))
    Inbox.Input.Interrupt -> on_interrupt(chat)
    Inbox.Input.Terminate -> ok(Step(chat: chat, exit: some(EXIT_TERMINATED)))
    Inbox.Input.Stream(generation, item) -> on_stream(chat, generation, item)
  end
end

def on_stream(chat: Chat, generation: Int, item: Inbox.Item) -> Result[Step]
  return ok(Step(chat: chat)) if generation != chat.generation

  case item
    Inbox.Item.Event(id, Protocol.Event.Resync) -> resync(chat.with(last_event_id: id.unwrap_or(chat.last_event_id)))
    Inbox.Item.Event(id, event) ->
      on_event(chat.with(last_event_id: id.unwrap_or(chat.last_event_id), failures: 0), event)
    Inbox.Item.Ended(reason) -> reconnect(chat, reason)
  end
end

def on_event(chat: Chat, event: Protocol.Event) -> Result[Step]
  shown = show(chat, Render.event(event, chat.style))
  changed = case event
    Protocol.Event.TurnStarted(_) -> shown.with(turn: true, stopping: false)
    Protocol.Event.TurnFinished(_) -> shown.with(turn: false, stopping: false)
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

  return ok(Step(chat: note(chat, "[a turn is running: Ctrl+C or /stop stops it]"))) if chat.turn
  return ok(Step(chat: chat)) if text == ""

  send(chat, text)
end

def send(chat: Chat, text: String) -> Result[Step]
  case Client.send_message(chat.server, chat.id, text)
    ok(_) -> ok(Step(chat: chat.with(turn: true)))
    error(e) if e.kind == Protocol.KIND_SESSION_BUSY ->
      ok(Step(chat: note(chat, "[a turn is already running]").with(turn: true)))
    error(e) -> ok(Step(chat: note(chat, "[error] #{e.message}")))
  end
end

def answered(chat: Chat, text: String) -> Result[Step]
  case Render.answer(text)
    some(decision) -> decide(chat, decision)
    none -> ok(Step(chat: note(chat, Render.ANSWER_HINT)))
  end
end

# Sends the decision for the first pending approval. Another client may have answered first: that is not a failure.
def decide(chat: Chat, decision: Protocol.Decision) -> Result[Step]
  request = chat.pending[0]
  sent = Client.approve(chat.server, chat.id, request.approval_id, decision)
  informed = case sent
    ok(_) -> chat
    error(e) if e.kind == Protocol.KIND_APPROVAL_RESOLVED or e.kind == Protocol.KIND_APPROVAL_NOT_FOUND ->
      note(chat, "[approval #{request.approval_id}] already answered")
    error(e) -> note(chat, "[error] #{e.message}")
  end

  settled(prompted(forgotten(informed, request.approval_id)))
end

def stop(chat: Chat) -> Result[Step]
  case Client.stop(chat.server, chat.id)
    ok(_) -> ok(Step(chat: note(chat, "[stopping the turn: Ctrl+C again leaves]").with(stopping: true)))
    error(e) -> ok(Step(chat: note(chat, "[error] #{e.message}")))
  end
end

def on_interrupt(chat: Chat) -> Result[Step]
  return stop(chat) if chat.turn and not chat.stopping

  ok(Step(chat: note(chat, "[interrupted]"), exit: some(EXIT_INTERRUPTED)))
end

# The end of the input leaves once no turn runs; a pending approval is denied, as nobody can answer it.
def on_eof(chat: Chat) -> Result[Step]
  return decide(chat, Protocol.Decision.Deny) if chat.asked

  settled(chat)
end

def settled(chat: Chat) -> Result[Step]
  return ok(Step(chat: chat, exit: some(0))) if chat.eof and not chat.turn

  ok(Step(chat: chat))
end

def resync(chat: Chat) -> Result[Step]
  if chat.failures >= MAX_FAILURES
    return error("the server keeps asking to read the session again", kind: "cli.resync")
  end

  noted = note(chat, "[resync: reading the session again]")
  session = try Client.session(noted.server, noted.id)
  running = session.turn_id.some?
  from = session.last_event_id
  if running
    from = session.turn_from_event_id.unwrap_or(session.last_event_id)
  end

  fresh = noted.with(
    turn: running,
    stopping: false,
    pending: session.pending_approvals,
    asked: false,
    replay_until: session.last_event_id,
    failures: noted.failures + 1,
  )

  ok(Step(chat: prompted(subscribe(fresh, from))))
end

def reconnect(chat: Chat, reason: String) -> Result[Step]
  failures = chat.failures + 1
  return error("lost the event stream: #{reason}", kind: "cli.stream") if failures > MAX_FAILURES

  IO.warn("[the event stream ended: #{reason}; reconnecting]")
  Task.sleep(RECONNECT_MS * failures)
  ok(Step(chat: subscribe(chat.with(failures: failures), chat.last_event_id)))
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

def prompted(chat: Chat) -> Chat
  return chat if chat.asked or chat.pending.empty? or chat.last_event_id < chat.replay_until

  show(chat, some(Render.prompt(chat.pending[0]))).with(asked: true)
end

def note(chat: Chat, text: String) -> Chat = show(chat, some(Render.line(text)))

def show(chat: Chat, out: Optional[Render.Out]) -> Chat
  case out
    none -> chat
    some(piece) ->
      written = Render.put(chat.flow, piece)
      print(written.text)
      IO.flush()
      chat.with(flow: written.flow)
  end
end

def print_line(text: String) -> Void
  puts(text)
  IO.flush()
end
