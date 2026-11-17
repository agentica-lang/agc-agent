## What the extensions of a server add (`Core.serve`): tools, wrappers of the runs of every tool, text after the
## system prompt of a new session, handlers of events, and services that run as long as the server. Code of an
## extension runs in a task of its own: a crash or a hang there fails that call, never the session or the server.

import LLM from "pkg/llm/llm"
import Sandbox from "../tools/sandbox"
import Spec from "../tools/spec"

## How long a `Message` or `Fold` handler, and the start or the stop of a service, may take.
HANDLER_MS = 5000
## How long a call of a tool may take once an extension is in it: the longest `bash` call, and some.
TOOL_MS = 660_000
## Names an extension tool cannot take: those of the tools of the core that `Tools.all` does not list, and the prefix
## of the MCP tools.
RESERVED = ["apply_patch", "run_script", "activate_skill"]
MCP_PREFIX = "mcp__"

## A call of a tool, made by the core: the session folder and the input of the model. More fields may come.
struct Call
  root: String
  input: JSON.Value
  hidden: Optional[Fn[String, Bool]] = none
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

## A handler of an event of a session. `Message` gets the text of a user message after the skills it names are
## expanded, and gives the text the model gets (the session file keeps what was typed too); a crash or a hang refuses
## the message. `Fold` gets the texts of the messages that stay when the history folds, and gives text to add after the
## summary; a crash or a hang adds nothing.
enum Event
  Message(Fn[String, String])
  Fold(Fn[List[String], String])
end

## Something that runs with the server: `start` once the server holds its lock, before it listens (an error stops the
## start), `stop` after it stops listening, before its files go.
struct Service
  name: String
  start: Fn[Result[Void]]
  stop: Fn[Void]
end

## Gets the name of the tool, the call, and the run it wraps (the tool's, or the next wrapper's), and gives the output.
## It runs on every call of every tool but `activate_skill` and `run_script` (whose calls inside are wrapped); keep it
## free of state of its own. The approval decides on the tool as it is, never on what a wrapper does.
type Wrapper = Fn[String, Call, Fn[Call, Result[String]], Result[String]]

struct Registry
  tools: List[Tool] = []
  wrappers: List[Wrapper] = []
  prompts: List[String] = []
  events: List[Event] = []
  services: List[Service] = []
  ## How long a `Message` or `Fold` handler may take, and a call of a tool once an extension is in it.
  handler_ms: Int = HANDLER_MS
  tool_ms: Int = TOOL_MS
end

## `path` of a call resolved inside its session folder (through its links), unless a deny rule of `read_file` hides it.
def resolve(call: Call, path: String) -> Result[String]
  real = try Sandbox.resolve(call.root, path)
  for hidden in option_list(call.hidden)
    return error("#{path} is hidden by a rule of the config") if hidden.call(path)
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

## `text` after the `Message` handlers, in the order they were added; an error when one crashes or hangs.
def message(registry: Registry, text: String) -> Result[String]
  out = text
  for handle in message_handlers(registry)
    before = out
    out = try bounded("a message handler", registry.handler_ms, -> { ok(handle.call(before)) })
  end

  ok(out)
end

## The text the `Fold` handlers add after a summary, each on its own lines; a handler that crashes or hangs adds none
## and is warned about.
def fold(registry: Registry, staying: List[LLM.Message]) -> String
  texts = staying.map { |message| text_of(message) }
  out = ""
  for handle in fold_handlers(registry)
    case bounded("a fold handler", registry.handler_ms, -> { ok(handle.call(texts)) })
      ok(extra) if not extra.empty? -> out = "#{out}\n\n#{extra}"
      ok(_) -> nil
      error(e) -> IO.warn(e.message)
    end
  end

  out
end

## `system` with the prompts of the extensions after it.
def prompt(registry: Registry, system: String) -> String = ([system] + registry.prompts).join("\n\n")

## Starts the services in order. One that answers an error stops those started before it, in the reverse order, and
## the start fails; one that crashes or hangs is warned about and left out.
def start_services(services: List[Service]) -> Result[List[Service]]
  done: List[Service] = []
  for service in services
    ran = bounded("service #{service.name}", HANDLER_MS, -> { ok(service.start.call()) })
    if not ran.ok?
      IO.warn(ran.message)
    elsif ran.unwrap!.ok?
      done = done.push(service)
    else
      stop_services(done)
      return error("service #{service.name}: #{ran.unwrap!.message}")
    end
  end

  ok(done)
end

## Stops the services in the reverse order; one that crashes or hangs is warned about.
def stop_services(services: List[Service]) -> Void
  for service in services.reverse
    case bounded("service #{service.name}", HANDLER_MS, -> { stopped(service) })
      ok(_) -> nil
      error(e) -> IO.warn(e.message)
    end
  end
end

private

def stopped(service: Service) -> Result[Void]
  service.stop.call()
  ok()
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
      guarded(tool.name, ms, -> { tool.target.call(call_of(ctx, input)) })
    },
  )
end

def call_of(ctx: Spec.Context, input: JSON.Value) -> Call = Call(root: ctx.root, input: input, hidden: ctx.hidden)

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
  guarded(name, ms, -> { wrapper.call(name, call_of(ctx, input), ->(call: Call) { next.call(ctx, call.input) }) })
end

# The code of an extension in a task: a crash or a hang there is an error of the call.
def guarded(name: String, ms: Int, body: Fn[Result[String]]) -> Result[String]
  ran = try bounded("the tool #{name}", ms, -> { ok(body.call()) })
  ran
end

def bounded[T](what: String, ms: Int, body: Fn[Result[T]]) -> Result[T]
  task = Task.spawn do body.call() end
  case Task.await(task, ms)
    Await.Done(ok(value)) -> ok(value)
    Await.Done(error(e)) -> error("#{what} failed: #{e.message}")
    _ ->
      Task.cancel(task)
      error("#{what} took over #{ms} ms")
  end
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
