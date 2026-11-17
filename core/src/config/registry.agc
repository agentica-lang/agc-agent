## What the extensions of a server add (`Core.serve`): tools, wrappers of the runs of every tool, text after the
## system prompt of a new session, handlers of events, and services that run as long as the server. Code of an
## extension runs in a task of its own: a crash or a hang there fails that call, never the session or the server.

import LLM from "pkg/llm/llm"
import Sandbox from "../tools/sandbox"
import Spec from "../tools/spec"

export Spec.Seen
export Spec.Host
export Spec.NewChild

## How long all the `Message` handlers, or all the `Fold` handlers, of one event may take together: well under the
## time a client waits for the session to answer.
HANDLER_MS = 2000
## How long all the `ToolBefore` handlers of one call may take together: they run in the turn, not in the session.
TOOL_BEFORE_MS = 10_000
## The most characters of the reason of a `Stop` that the model gets.
STOP_MAX = 1000
## How long a service may take to start, or to stop.
SERVICE_MS = 30_000
## How long the target of an extension tool may take: it runs before the approval asks.
TARGET_MS = 5000
## How long the end of a task of an extension may take to be seen, once it returned or was cancelled.
END_MS = 1000
## How long a call of a tool may take once an extension is in it: the longest `bash` call, and some.
TOOL_MS = 660_000
## The events an observer may be behind by: past them, the next ones are dropped and counted.
OBSERVER_INBOX = 256
## Names an extension tool cannot take: those of the tools of the core that `Tools.all` does not list, and the prefix
## of the MCP tools.
RESERVED = ["apply_patch", "run_script", "activate_skill"]
MCP_PREFIX = "mcp__"

## A call of a tool, made by the core: the session folder, the input of the model, and how a path of the call is
## resolved (`Core.resolve`). More fields may come.
struct Call
  root: String
  input: JSON.Value
  resolve: Fn[String, Result[String]]
  ## The session of the call, and its handle on itself and its child sessions (none in `Core.call`).
  session: String = ""
  host: Optional[Spec.Host] = none
end

## A tool of an extension. `target` is what the approval shows and its rules match (a path, a command); a tool that
## `asks` waits for an answer when the approvals are on and no rule allows the call.
struct Tool
  name: String
  description: String
  input_schema: JSON.Value
  asks: Bool = true
  run: Fn[Call, Result[String]]
  target: Fn[Call, Result[String]]
end

## A call of a tool as a `ToolBefore` handler sees it: the session, its folder, the tool's name and the input.
struct Pending
  session: String
  root: String
  name: String
  input: JSON.Value
end

## What a `ToolBefore` handler decides on a call: it runs as it is (`Go`), on another input (`Input`), or not, with the
## reason the model gets (`Stop`).
enum Check
  Go
  Input(JSON.Value)
  Stop(String)
end

## A handler of an event of a session. `Message` gets the text of a user message after the skills it names are
## expanded, and gives the text the model gets (the session file keeps what was typed too); a crash or a hang refuses
## the message. `Fold` gets the texts of the messages that stay when the history folds, and gives text to add after the
## summary; a crash or a hang adds nothing. `Seen` gets the events of the names it lists, of every session, in order:
## nothing waits for it, and an observer that falls `OBSERVER_INBOX` events behind loses the next ones (counted in the
## log). A crash or a hang of one event is logged, and the next event comes. `ToolBefore` gets each call of a tool
## before its approval, and the input it gives is what the approval sees and the tool runs on; a crash or a hang fails
## the call.
enum Event
  Message(Fn[String, String])
  Fold(Fn[List[String], String])
  Seen(List[String], Fn[Spec.Seen, Void])
  ToolBefore(Fn[Pending, Check])
end

## Something that runs with the server: `start` once the server holds its lock, before it listens, and `stop` after it
## stops listening, before its files go. Both run in one task of the service's own, so what `start` opens stays open
## until `stop`. A start that fails, crashes or takes over `service_ms` stops the server's start.
struct Service
  name: String
  start: Fn[Result[Void]]
  stop: Fn[Void]
end

## Gets the name of the tool, the call, and the run it wraps (the tool's, or the next wrapper's), and gives the output.
## The run takes no input: it runs on the input the approval saw. A wrapper runs on every call of every tool but
## `activate_skill` and `run_script` (whose calls inside are wrapped); keep it free of state of its own.
type Wrapper = Fn[String, Call, Fn[Result[String]], Result[String]]

struct Registry
  tools: List[Tool] = []
  wrappers: List[Wrapper] = []
  prompts: List[String] = []
  events: List[Event] = []
  services: List[Service] = []
  ## How long the handlers of one event may take together, a service to start or stop (and up to END_MS more while
  ## its task ends), and a call of a tool once an extension is in it.
  handler_ms: Int = HANDLER_MS
  observer_inbox: Int = OBSERVER_INBOX
  tool_before_ms: Int = TOOL_BEFORE_MS
  service_ms: Int = SERVICE_MS
  tool_ms: Int = TOOL_MS
end

## An observer that runs: its inbox, which its task reads, and the events it lost. Not part of `Core`.
struct Observer
  names: List[String]
  inbox: Channel[Spec.Seen]
  dropped: ATS[String, Int]
  task: Task[Void]
end

## What a server runs with: the registry of the program (`Core.serve`) and the core's own extensions, which need more
## than the public API: the skills, the tools that come later (the MCP servers that still list them) and the approval.
## Not part of `Core`.
struct Served
  registry: Registry
  builtins: List[Builtin] = []
  late: List[Fn[List[Spec.Tool]]] = []
  approver: Optional[Fn[Place, Result[Approver]]] = none
end

## The approval of a session: it decides on each call before it runs, and keeps what the session's answers allowed;
## an answer, or a change of `accept_edits`, gives the next one.
struct Approver
  ## Whether a call runs, asks or is refused; none runs every call.
  verdict: Optional[Fn[Spec.Context, String, JSON.Value, Spec.Verdict]]
  ## Whether the session's answers allow a call of a tool on a target without asking.
  allows: Fn[String, String, Bool]
  ## The words that an answer for all such calls would allow (`git push` of `git push origin main`).
  prefix: Fn[String, String, Optional[String]]
  ## After an answer (its decision's name) to a call of a tool on a target.
  answered: Fn[String, String, String, Approver]
  ## Whether a path relative to the session folder is hidden from the tools.
  hidden: Fn[String, Bool]
  asking: Bool
  accept_edits: Bool
  with_accept_edits: Fn[Bool, Approver]
end

## A session folder as the core's own extensions see it: its skills count when it is `trusted`.
struct Place
  root: String
  home: String
  trusted: Bool
end

## One of the core's own extensions, which needs more than the public API: `system` adds to the system prompt of a new
## session, and `open` gives a session what it needs as it opens with its system prompt. Not part of `Core`.
struct Builtin
  system: Fn[Place, String, String]
  open: Fn[Place, String, Opened]
end

## What a session gets from one of the core's own extensions: folders that `read_file` reads too, the tools of its
## turns, what a user message becomes (with the names the session noted so far), and the text a fold adds.
struct Opened
  read_roots: List[String] = []
  tools: List[Spec.TurnTool] = []
  message: Fn[String, List[String], Noted]
  fold: Fn[List[String], List[LLM.Message], String]
  warnings: List[String] = []
end

## A message as an extension of the core made it, and the names it noted.
struct Noted
  text: String
  names: List[String]
end

## A service that started, in the task that owns it.
struct Running
  name: String
  task: Task[Void]
  stopping: Channel[Bool]
  news: Channel[Note]
  ms: Int
end

enum Note
  Started
  Failed(String)
  Down(TaskDown)
end

## `path` resolved inside the session folder of `ctx` (through its links), unless a deny rule of `read_file` hides
## the file it names.
def resolve(ctx: Spec.Context, path: String) -> Result[String]
  real = try Sandbox.resolve(ctx.root, path)
  for hidden in option_list(ctx.hidden)
    return error("#{path} is hidden by a rule of the config") if hidden.call(Sandbox.relative(ctx.root, real))
  end

  ok(real)
end

## Why the tools of `registry` cannot be served with the tools named `taken`, one line each; empty when they can.
def clashes(registry: Registry, taken: List[String]) -> List[String]
  out: List[String] = []
  seen = taken + RESERVED
  for tool in registry.tools
    if seen.include?(tool.name) or tool.name.start_with?(MCP_PREFIX)
      out = out.push("an extension tool cannot be named #{tool.name}: that name is taken")
    end

    seen = seen.push(tool.name)
  end

  out
end

## The tools of `registry` as tools of the core; a crash or a hang of their code fails the call.
def spec_tools(registry: Registry) -> List[Spec.Tool] = registry.tools.map { |tool| spec_tool(tool, registry.tool_ms) }

## The wrappers of `registry` around the run of a tool, the first added outermost; none without wrappers.
def wrap(registry: Registry) -> Optional[Fn[String, Spec.Run, Spec.Run]]
  return none if registry.wrappers.empty?

  wrappers = registry.wrappers
  ms = registry.tool_ms
  some(->(name: String, run: Spec.Run) { wrapped(wrappers, ms, name, run) })
end

## `text` after the `Message` handlers, in the order they were added; an error when one crashes, or when they take
## over `handler_ms` together.
def message(registry: Registry, text: String) -> Result[String]
  deadline = Time.monotonic_ms() + registry.handler_ms
  out = text
  for handle in message_handlers(registry)
    before = out
    out = try bounded("a message handler", deadline - Time.monotonic_ms(), -> { ok(handle.call(before)) })
  end

  ok(out)
end

## The input of a call after the `ToolBefore` handlers of `registry` in the session `session`, none without any: each
## handler gets the input the one before gave, and the first `Stop` ends the chain with an error of the kind
## `Spec.BLOCKED`. A crash, or a chain over `tool_before_ms`, is an error too.
def before(registry: Registry, session: String) -> Optional[Spec.Before]
  handlers = tool_before_handlers(registry)
  return none if handlers.empty?

  ms = registry.tool_before_ms
  some(
    ->(ctx: Spec.Context, name: String, input: JSON.Value) {
      checked(handlers, ms, Pending(session: session, root: ctx.root, name: name, input: input))
    },
  )
end

## The text the `Fold` handlers add after a summary, each on its own lines; a handler that crashes, or runs past
## `handler_ms` for them all, adds none and is warned about.
def fold(registry: Registry, staying: List[LLM.Message]) -> String
  deadline = Time.monotonic_ms() + registry.handler_ms
  texts = staying.map { |message| text_of(message) }
  out = ""
  for handle in fold_handlers(registry)
    case bounded("a fold handler", deadline - Time.monotonic_ms(), -> { ok(handle.call(texts)) })
      ok(extra) if not extra.empty? -> out = "#{out}\n\n#{extra}"
      ok(_) -> nil
      error(e) -> IO.warn(e.message)
    end
  end

  out
end

## Starts a task for each `Seen` handler of `registry`, which gets its events one at a time.
def observe(registry: Registry) -> List[Observer] = registry.events.flat_map { |event| observers_of(event, registry) }

## An observer of one session (`Core.Host.watch`), with the inbox and the time of the default registry.
def watcher(names: List[String], handler: Fn[Spec.Seen, Void]) -> Observer = observer(names, handler, Registry())

## Whether an observer wants the events of `name`: publishing an event that none wants costs nothing more.
def wanted?(observers: List[Observer], name: String) -> Bool = observers.any? { |o| o.names.include?(name) }

## Gives `seen` to the observers that want it, without waiting: a full inbox drops it and counts the drop.
def publish(observers: List[Observer], seen: Spec.Seen) -> Void
  for observer in (observers.select { |o| o.names.include?(seen.name) })
    if not observer.inbox.send(seen, 0).ok?
      _ = observer.dropped.add(DROPPED, 1)
    end
  end
end

## Ends the observers: each gets the events already in its inbox, for at most `END_MS` together.
def stop_observers(observers: List[Observer]) -> Void
  for observer in observers
    observer.inbox.close
  end

  deadline = Time.monotonic_ms + END_MS
  for observer in observers
    case Task.await(observer.task, [deadline - Time.monotonic_ms, 0].max.unwrap!)
      Await.Done(_) -> nil
      _ -> Task.cancel(observer.task)
    end
  end
end

## `system` with the prompts of the extensions after it.
def prompt(registry: Registry, system: String) -> String = ([system] + registry.prompts).join("\n\n")

## A call of a tool in the session folder `root`, for the tests of an extension: its paths resolve in `root`, with no
## deny rule.
def call(root: String, input: JSON.Value) -> Call
  real = Path.real(root).unwrap_or(root)
  Call(root: real, input: input, resolve: ->(path: String) { Sandbox.resolve(real, path) })
end

def add_builtin(served: Served, builtin: Builtin) -> Served = served.with(builtins: served.builtins.push(builtin))

def add_late_tools(served: Served, tools: Fn[List[Spec.Tool]]) -> Served = served.with(late: served.late.push(tools))

## The tools that come later, none without any.
def late_tools(served: Served) -> Optional[Fn[List[Spec.Tool]]]
  return none if served.late.empty?

  late = served.late
  some(-> { late.flat_map { |tools| tools.call() } })
end

## The system prompt of a new session in `place`: `system` with what the core's own extensions add.
def new_system(served: Served, place: Place, system: String) -> String
  out = system
  for builtin in served.builtins
    out = builtin.system.call(place, out)
  end

  out
end

## What the core's own extensions give a session in `place` that opens with `system`.
def open(served: Served, place: Place, system: String) -> List[Opened]
  served.builtins.map { |builtin| builtin.open.call(place, system) }
end

## The approval of a session in `place`, none when the server has none; an error when it cannot open (a broken project
## file).
def approver(served: Served, place: Place) -> Result[Optional[Approver]]
  for open in option_list(served.approver)
    return ok(some(try open.call(place)))
  end

  ok(none)
end

def read_roots(opened: List[Opened]) -> List[String] = opened.flat_map { |o| o.read_roots }

def turn_tools(opened: List[Opened]) -> List[Spec.TurnTool] = opened.flat_map { |o| o.tools }

## `text` as the core's own extensions make it, in order, each seeing the names noted before it.
def noted(opened: List[Opened], text: String, marks: List[String]) -> Noted
  out = Noted(text: text, names: [])
  for o in opened
    made = o.message.call(out.text, marks + out.names)
    out = Noted(text: made.text, names: out.names + made.names)
  end

  out
end

## The text the core's own extensions add after the summary of a fold.
def folded(opened: List[Opened], marks: List[String], staying: List[LLM.Message]) -> String
  opened.map { |o| o.fold.call(marks, staying) }.join("")
end

## Starts the services in order, each in a task of its own. One that fails, crashes or takes over `ms` stops those
## started before it, in the reverse order, and the start fails.
def start_services(services: List[Service], ms: Int = SERVICE_MS) -> Result[List[Running]]
  done: List[Running] = []
  for service in services
    case started(service, ms)
      ok(running) -> done = done.push(running)
      error(e) ->
        stop_services(done)
        return error("service #{service.name}: #{e.message}")
    end
  end

  ok(done)
end

## Stops the services in the reverse order: each runs its `stop` in its task. One that crashes, or takes over its time,
## is warned about (and cancelled).
def stop_services(services: List[Running]) -> Void
  for running in services.reverse
    _ = running.stopping.send(true, 0)
    case running.news.recv(running.ms)
      ok(Note.Down(down)) if down.reason != TaskExit.Ok -> IO.warn("service #{running.name}: #{down.message}")
      ok(_) -> nil
      error(_) ->
        cancelled(running.task, running.news)
        IO.warn("service #{running.name} took over #{running.ms} ms to stop")
    end
  end
end

private

DROPPED = "dropped"

# The task of a service: it starts it, waits for the stop, and stops it.
def owned(service: Service, news: Channel[Note], stopping: Channel[Bool], ms: Int) -> Void
  case service.start.call()
    ok(_) -> _ = news.send(Note.Started, 0)
    error(e) ->
      _ = news.send(Note.Failed(e.message), 0)
      return
  end

  while not stopping.recv(ms).ok?
    nil
  end

  service.stop.call()
end

def started(service: Service, ms: Int) -> Result[Running]
  news: Channel[Note] = Channel.new(4)
  stopping: Channel[Bool] = Channel.new(1)
  task = Task.spawn do owned(service, news, stopping, ms) end
  Task.monitor(task, news) do |down| Note.Down(down) end
  case news.recv(ms)
    ok(Note.Started) -> ok(Running(name: service.name, task: task, stopping: stopping, news: news, ms: ms))
    ok(Note.Failed(message)) ->
      _ = news.recv(END_MS)
      error(message)
    ok(Note.Down(down)) -> error("crashed: #{down.message}")
    _ ->
      cancelled(task, news)
      error("took over #{ms} ms to start")
  end
end

# A service's task is cancelled, and gone once its end is noted, so nothing of it runs after.
def cancelled(task: Task[Void], news: Channel[Note]) -> Void
  Task.cancel(task)
  # At most two notes come: a `Started` or `Failed` sent as the cancel lands, then the `Down`.
  for _i in 1..2
    case news.recv(END_MS)
      ok(Note.Down(_)) -> return
      ok(_) -> nil
      error(_) -> return
    end
  end
end

def checked(handlers: List[Fn[Pending, Check]], ms: Int, given: Pending) -> Result[JSON.Value]
  deadline = Time.monotonic_ms() + ms
  call = given
  for handle in handlers
    check = try bounded("a tool_before handler", deadline - Time.monotonic_ms(), -> { ok(handle.call(call)) })
    case check
      Check.Go -> nil
      Check.Input(changed) -> call = call.with(input: changed)
      Check.Stop(reason) -> return error(cut(reason, STOP_MAX), kind: Spec.BLOCKED)
    end
  end

  ok(call.input)
end

def cut(text: String, max: Int) -> String
  return text if text.length <= max

  text.slice(0, max)
end

def tool_before_handlers(registry: Registry) -> List[Fn[Pending, Check]]
  out: List[Fn[Pending, Check]] = []
  for event in registry.events
    case event
      Event.ToolBefore(handle) -> out = out.push(handle)
      _ -> nil
    end
  end

  out
end

def message_handlers(registry: Registry) -> List[Fn[String, String]]
  out: List[Fn[String, String]] = []
  for event in registry.events
    case event
      Event.Message(handle) -> out = out.push(handle)
      _ -> nil
    end
  end

  out
end

def fold_handlers(registry: Registry) -> List[Fn[List[String], String]]
  out: List[Fn[List[String], String]] = []
  for event in registry.events
    case event
      Event.Fold(handle) -> out = out.push(handle)
      _ -> nil
    end
  end

  out
end

def spec_tool(tool: Tool, ms: Int) -> Spec.Tool
  Spec.Tool(
    name: tool.name,
    description: tool.description,
    input_schema: tool.input_schema,
    asks: tool.asks,
    run: ->(ctx: Spec.Context, input: JSON.Value) {
      guarded(tool.name, ms, -> { tool.run.call(call_of(ctx, input)) })
    },
    target: ->(ctx: Spec.Context, input: JSON.Value) {
      guarded(tool.name, TARGET_MS, -> { tool.target.call(call_of(ctx, input)) })
    },
  )
end

def call_of(ctx: Spec.Context, input: JSON.Value) -> Call
  Call(
    root: ctx.root,
    input: input,
    resolve: ->(path: String) { resolve(ctx, path) },
    session: ctx.session,
    host: ctx.host,
  )
end

def wrapped(wrappers: List[Wrapper], ms: Int, name: String, run: Spec.Run) -> Spec.Run
  inner = run
  for wrapper in wrappers.reverse
    next = inner
    inner = ->(ctx: Spec.Context, input: JSON.Value) { layer(wrapper, ms, name, next, ctx, input) }
  end

  inner
end

def layer(
  wrapper: Wrapper,
  ms: Int,
  name: String,
  next: Spec.Run,
  ctx: Spec.Context,
  input: JSON.Value,
) -> Result[String]
  guarded(name, ms, -> { wrapper.call(name, call_of(ctx, input), -> { next.call(ctx, input) }) })
end

# The code of an extension in a task: a crash or a hang there is an error of the call.
def guarded(name: String, ms: Int, body: Fn[Result[String]]) -> Result[String]
  ran = try bounded("the tool #{name}", ms, -> { ok(body.call()) })
  ran
end

def bounded[T](what: String, ms: Int, body: Fn[Result[T]]) -> Result[T]
  return error("#{what} had no time left") if ms <= 0

  task = Task.spawn do body.call() end
  case Task.await(task, ms)
    Await.Done(ok(value)) -> ok(value)
    Await.Done(error(e)) -> error("#{what} failed: #{e.message}")
    _ ->
      Task.cancel(task)
      _ = Task.await(task, END_MS)
      error("#{what} took over #{ms} ms")
  end
end

def observers_of(event: Event, registry: Registry) -> List[Observer]
  case event
    Event.Seen(names, handler) -> [observer(names, handler, registry)]
    Event.Message(_) -> []
    Event.Fold(_) -> []
    Event.ToolBefore(_) -> []
  end
end

def observer(names: List[String], handler: Fn[Spec.Seen, Void], registry: Registry) -> Observer
  inbox: Channel[Spec.Seen] = Channel.new(registry.observer_inbox)
  dropped: ATS[String, Int] = ATS.new()
  task = Task.spawn(-> { observed(inbox, dropped, handler, registry.handler_ms) })
  Observer(names: names, inbox: inbox, dropped: dropped, task: task)
end

def observed(inbox: Channel[Spec.Seen], dropped: ATS[String, Int], handler: Fn[Spec.Seen, Void], ms: Int) -> Void
  while true
    case inbox.recv(60_000)
      ok(seen) ->
        lost = dropped.add(DROPPED, 0)
        if lost > 0
          _ = dropped.add(DROPPED, -lost)
          IO.warn("an observer of extensions: #{lost} events dropped (behind)")
        end

        case bounded("an observer of #{seen.name}", ms, -> { handled(handler, seen) })
          ok(_) -> nil
          error(e) -> IO.warn(e.message)
        end

      error(_) -> return if inbox.closed? and inbox.empty?
    end
  end
end

def handled(handler: Fn[Spec.Seen, Void], seen: Spec.Seen) -> Result[Void]
  handler.call(seen)
  ok()
end

def text_of(message: LLM.Message) -> String
  parts = message.content.map do |block|
    case block
      LLM.Block.Text(part) -> part.text
      _ -> ""
    end
  end

  parts.select { |part| not part.empty? }.join("\n")
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
