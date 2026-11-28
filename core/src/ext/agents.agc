## The built-in subagent tools: `agent` starts one child session per task, sends it its prompt and either waits
## for their answers or returns their ids; `agent_send` sends a follow-up message to a child, waiting or not; and
## `agent_stop` stops a child's turn. They run over the session's own handle (`Spec.Context.host`), so a stranger's
## id, a deleted child and the session itself are refused exactly as the handle refuses them. A child's answer comes
## back cut at `MAX_ANSWER_CHARS` characters, under its name and provider and model. A wait ends when the child's
## turn does, when `Limits.timeout_ms` stops it, or when the parent's turn stops first: then the children this call
## started are stopped and deleted, while older ones only stop their turn.

import Protocol from "pkg/protocol/protocol"
import Spec from "../tools/spec"

## A profile a subagent may run, with the provider and model it would take on this session (the session's own when
## the profile keeps them; a project's profile never names another provider).
struct Profile
  name: String
  description: String
  provider: String
  model: String
end

## What bounds the subagents of a session: at most `max` children with a running turn (0 for no cap), and a child's
## turn stops `timeout_ms` after its prompt was sent (0 for no timeout).
struct Limits
  max: Int = 0
  timeout_ms: Int = 0
end

## The subagent tools: a roster read fresh on every call (and naming the profiles in their description), the bounds,
## and the ids of the live children this session started, for the cap. The description is made when the tools are, so
## a session reads its profiles again on every turn.
def tools(roster: Fn[List[Profile]], limits: Limits, running: ATS[String, Int]) -> List[Spec.Tool]
  [
    Spec.Tool(
      name: AGENT,
      description: agent_description(roster),
      input_schema: JSON.schema(AgentArgs),
      asks: false,
      run: ->(ctx: Spec.Context, input: JSON.Value) { run_all(ctx, input, roster, limits, running) },
      target: ->(_ctx: Spec.Context, input: JSON.Value) { ok(agent_target(input)) },
    ),
    Spec.Tool(
      name: SEND,
      description: (
        "Send a follow-up message to one of the session's subagents. With `wait` (the default) it answers with " +
        "the child's next answer, or the part of it there is when `FINN_SUBAGENT_TIMEOUT_MS` stops its turn; " +
        "without it, it answers with the id and the answer wakes this session."
      ),
      input_schema: JSON.schema(SendArgs),
      asks: false,
      run: ->(ctx: Spec.Context, input: JSON.Value) { run_send(ctx, input, limits) },
      target: ->(_ctx: Spec.Context, input: JSON.Value) { ok(send_target(input)) },
    ),
    Spec.Tool(
      name: STOP,
      description: "Stop the turn of one of the session's subagents: `stopped`, or `idle` when no turn runs.",
      input_schema: JSON.schema(StopArgs),
      asks: false,
      run: ->(ctx: Spec.Context, input: JSON.Value) { run_stop(ctx, input) },
      target: ->(_ctx: Spec.Context, input: JSON.Value) { ok(stop_target(input)) },
    ),
  ]
end

private

AGENT = "agent"
SEND = "agent_send"
STOP = "agent_stop"
## The most characters of an answer a result keeps.
MAX_ANSWER_CHARS = 8000
## How long a wait with no timeout waits at once before it checks its children again.
WAIT_MS = 3_600_000

struct AgentTask
  agent: Optional[String] = none
  prompt: String
end

struct AgentArgs
  tasks: List[AgentTask]
  wait: Optional[Bool] = none
end

struct SendArgs
  id: String
  text: String
  wait: Optional[Bool] = none
end

struct StopArgs
  id: String
end

## A child this call waits for: its task, its display name and when its turn times out (none without a timeout).
struct Active
  index: Int
  id: String
  name: String
  deadline: Optional[Int] = none
end

## A `turn_finished` of a child: its id and the reason its turn ended.
struct Heard
  id: String
  reason: String
end

def agent_description(roster: Fn[List[Profile]]) -> String
  lines = roster.call().map { |p| "- #{p.name}: #{shown_description(p)} (#{p.provider}/#{p.model})" }
  base = (
    "Start one subagent per task: a child session with its own provider, model and profile that works on its " +
    "prompt and reports back, in parallel. `agent` names the profile it runs (the session's own when empty), " +
    "from the roster below; a profile whose provider is not set up is left out. With `wait` (the default) it " +
    "answers with each answer in input order, each under `NAME (provider/model): reason`; without it, it answers " +
    "with their ids, one per line, and each answer wakes this session."
  )

  return "#{base} No profile is set up, so no subagent can start." if lines.empty?

  "#{base} Profiles:\n#{lines.join("\n")}"
end

def shown_description(profile: Profile) -> String
  return "no description" if profile.description.strip.empty?

  profile.description.strip
end

def agent_target(input: JSON.Value) -> String
  case Spec.args(input, AgentArgs.codec)
    ok(args) ->
      names = args.tasks.map { |t| t.agent.unwrap_or("") }.select { |n| not n.empty? }
      return "#{args.tasks.size} tasks: #{names.join(", ")}" if not names.empty?

      "#{args.tasks.size} tasks"
    error(_) -> AGENT
  end
end

def send_target(input: JSON.Value) -> String
  case Spec.args(input, SendArgs.codec)
    ok(args) -> args.id
    error(_) -> SEND
  end
end

def stop_target(input: JSON.Value) -> String
  case Spec.args(input, StopArgs.codec)
    ok(args) -> args.id
    error(_) -> STOP
  end
end

def run_all(
  ctx: Spec.Context,
  input: JSON.Value,
  roster: Fn[List[Profile]],
  limits: Limits,
  running: ATS[String, Int],
) -> Result[String]
  args = try Spec.args(input, AgentArgs.codec)
  return error("agent needs at least one task") if args.tasks.empty?

  host = try need_host(ctx, AGENT)
  own = try need_session(ctx, AGENT)
  listed = roster.call()
  for task in args.tasks
    return error("a task needs a prompt") if task.prompt.strip.empty?
    for name in option_list(task.agent)
      if not listed.any? { |p| p.name == name }
        return error("unknown profile #{name.inspect}: one of #{listed.map { |p| p.name }.join(", ")}")
      end
    end
  end

  parent = try parent_profile(host, own)
  if args.wait.unwrap_or(true)
    run_waiting(host, parent, args.tasks, limits, running)
  else
    run_async(host, own, parent, args.tasks, limits, running)
  end
end

def run_send(ctx: Spec.Context, input: JSON.Value, limits: Limits) -> Result[String]
  args = try Spec.args(input, SendArgs.codec)
  return error("agent_send needs some text") if args.text.strip.empty?

  host = try need_host(ctx, SEND)
  own = try need_session(ctx, SEND)
  return error("agent_send takes a subagent id, not the session's own") if args.id == own

  if args.wait.unwrap_or(true)
    send_waiting(host, args, limits)
  else
    send_async(host, own, args)
  end
end

def run_stop(ctx: Spec.Context, input: JSON.Value) -> Result[String]
  args = try Spec.args(input, StopArgs.codec)
  host = try need_host(ctx, STOP)

  case host.stop.call(args.id)
    ok(false) -> ok("idle")
    ok(_) -> ok("stopped")
    error(e) -> error(e)
  end
end

# Every task's child, started up to `limits.max` at once (in input order) and collected as they finish, in input
# order. A child that fails to start fails only its task.
def run_waiting(
  host: Spec.Host,
  parent: String,
  tasks: List[AgentTask],
  limits: Limits,
  running: ATS[String, Int],
) -> Result[String]
  done: Channel[Heard] = Channel.new([2 * tasks.size + 2, 4].max.unwrap!)
  live: List[Active] = []
  results: Map[Int, String] = {}
  next = 0
  while next < tasks.size or not live.empty?
    while next < tasks.size and (limits.max == 0 or running_now(host, running) < limits.max)
      name = named(tasks[next], parent)
      case start_child(host, tasks[next], name, next, limits, done, running)
        ok(active) -> live = live.push(active)
        error(e) -> results = results.put(next, "#{name}: #{e.message}")
      end

      next = next + 1
    end

    if live.empty?
      # The cap is held by older children: the rest cannot start.
      while next < tasks.size
        results = results.put(next, "#{named(tasks[next], parent)}: #{capped(limits.max)}")
        next = next + 1
      end

      break
    end

    case done.recv(wait_ms(live))
      ok(heard) ->
        case live.find { |a| a.id == heard.id }
          ok(active) ->
            live = live.select { |a| a.id != active.id }
            results = results.put(active.index, collected(host, active, heard.reason, running, true))
          error(_) -> nil
        end

      error(_) ->
        overdue = live.select { |a| past?(a) }
        if limits.timeout_ms > 0 and not overdue.empty?
          for active in overdue
            _ = host.stop.call(active.id)
            results = results.put(active.index, partial(host, active, limits))
            live = live.select { |a| a.id != active.id }
          end
        else
          for active in live
            _ = host.stop.call(active.id)
            _ = host.delete.call(active.id)
            running.delete(active.id)
          end

          return error("the agent call stopped with its turn")
        end
    end
  end

  ok(ordered(results, tasks.size).join("\n\n"))
end

def ordered(results: Map[Int, String], count: Int) -> List[String]
  out: List[String] = []
  for index in 0...count
    out = out.push(results.get(index).unwrap_or(""))
  end

  out
end

# Every task's child at once, unless the cap is reached; each answer wakes the session when it comes.
def run_async(
  host: Spec.Host,
  own: String,
  parent: String,
  tasks: List[AgentTask],
  limits: Limits,
  running: ATS[String, Int],
) -> Result[String]
  ids: List[String] = []
  for task in tasks
    return error(capped(limits.max)) if limits.max > 0 and running_now(host, running) >= limits.max

    name = named(task, parent)
    child = try host.create.call(Spec.NewChild(profile: task.agent))
    running.put(child, 1)
    case host.watch.call(child, ["turn_finished"], ->(seen: Spec.Seen) { woken(host, own, child, name, seen) })
      error(e) ->
        cleanup(host, running, child)
        return error(e.message)
      ok(_) -> nil
    end

    case host.send.call(child, task.prompt)
      error(e) ->
        cleanup(host, running, child)
        return error(e.message)
      ok(_) -> ids = ids.push(child)
    end
  end

  ok(ids.join("\n"))
end

def capped(max: Int) -> String
  "at most #{max} subagents run at once of this session: wait for one with agent_send, or stop one with agent_stop"
end

def send_waiting(host: Spec.Host, args: SendArgs, limits: Limits) -> Result[String]
  done: Channel[Heard] = Channel.new(4)
  id = args.id
  case host.watch.call(
    id,
    ["turn_finished"],
    ->(seen: Spec.Seen) { _ = done.send(Heard(id: id, reason: reason_of(seen)), 0) },
  )
    error(e) -> return error(e.message)
    ok(_) -> nil
  end

  case host.send.call(id, args.text)
    error(e) -> return error(e.message)
    ok(_) -> nil
  end

  active = Active(index: 0, id: id, name: id, deadline: deadline(limits))
  track: ATS[String, Int] = ATS.new()
  case done.recv(wait_ms([active]))
    ok(heard) -> ok(collected(host, active, heard.reason, track, false))
    error(_) ->
      if limits.timeout_ms > 0 and past?(active)
        _ = host.stop.call(id)
        return ok(partial(host, active, limits))
      end

      _ = host.stop.call(id)
      error("the agent call stopped with its turn")
  end
end

def send_async(host: Spec.Host, own: String, args: SendArgs) -> Result[String]
  id = args.id
  case host.watch.call(id, ["turn_finished"], ->(seen: Spec.Seen) { woken(host, own, id, id, seen) })
    error(e) -> return error(e.message)
    ok(_) -> nil
  end

  case host.send.call(id, args.text)
    error(e) -> error(e.message)
    ok(_) -> ok(id)
  end
end

# One finished child: its last answer under its name, or why it cannot be read. A child this call started is deleted
# with its answer, so no worker of it is left.
def collected(host: Spec.Host, active: Active, reason: String, running: ATS[String, Int], remove: Bool) -> String
  text = case host.snapshot.call(active.id)
    ok(session) ->
      "#{head(active.name, session.provider, session.model, reason)}\n#{cut(last_answer(session.history))}"
    error(e) -> "#{active.name}: could not read the answer: #{e.message}"
  end

  if remove
    _ = host.delete.call(active.id)
    running.delete(active.id)
  end

  text
end

# A child past its deadline: its turn is stopped, and the result holds the part of the answer there is.
def partial(host: Spec.Host, active: Active, limits: Limits) -> String
  text = "timed out after #{limits.timeout_ms} ms"
  case host.snapshot.call(active.id)
    ok(session) -> "#{head(active.name, session.provider, session.model, text)}\n#{cut(last_answer(session.history))}"
    error(e) -> "#{active.name}: #{text}: #{e.message}"
  end
end

def head(name: String, provider: String, model: String, reason: String) -> String
  "#{name} (#{provider}/#{model}): #{reason}"
end

def named(task: AgentTask, parent: String) -> String = task.agent.unwrap_or(parent)

def parent_profile(host: Spec.Host, own: String) -> Result[String]
  case host.snapshot.call(own)
    ok(session) ->
      for profile in option_list(session.profile)
        return ok(profile.name)
      end

      ok("build")
    error(e) -> error(e.message)
  end
end

def start_child(
  host: Spec.Host,
  task: AgentTask,
  name: String,
  index: Int,
  limits: Limits,
  done: Channel[Heard],
  running: ATS[String, Int],
) -> Result[Active]
  child = try host.create.call(Spec.NewChild(profile: task.agent))
  running.put(child, 1)
  active = Active(index: index, id: child, name: name, deadline: deadline(limits))
  case host.watch.call(
    child,
    ["turn_finished"],
    ->(seen: Spec.Seen) { _ = done.send(Heard(id: child, reason: reason_of(seen)), 0) },
  )
    error(e) ->
      cleanup(host, running, child)
      return error(e.message)
    ok(_) -> nil
  end

  case host.send.call(child, task.prompt)
    error(e) ->
      cleanup(host, running, child)
      return error(e.message)
    ok(_) -> nil
  end

  ok(active)
end

def cleanup(host: Spec.Host, running: ATS[String, Int], child: String) -> Void
  _ = host.delete.call(child)
  running.delete(child)
end

# The watcher that wakes the session with an answer: one event wakes once, and a child gone since is no wake. The
# wake comes from the extension, since only a child's own handle wakes as the child.
def woken(host: Spec.Host, parent: String, id: String, name: String, seen: Spec.Seen) -> Void
  snapshot = case host.snapshot.call(id)
    ok(session) -> some(session)
    error(_) -> none
  end

  for session in option_list(snapshot)
    headed = head(name, session.provider, session.model, reason_of(seen))
    _ = host.send.call(parent, "#{headed}\n#{cut(last_answer(session.history))}")
  end
end

# How many children this session started still run: the gone ones leave the table, the idle ones stay but count not.
def running_now(host: Spec.Host, running: ATS[String, Int]) -> Int
  running.keys().count { |id| runs?(host, running, id) }
end

def runs?(host: Spec.Host, running: ATS[String, Int], id: String) -> Bool
  case host.snapshot.call(id)
    ok(session) -> session.turn_id.some?
    error(e) -> forgotten(running, id, e.kind)
  end
end

def forgotten(running: ATS[String, Int], id: String, kind: String) -> Bool
  if kind == Protocol.KIND_SESSION_NOT_FOUND
    running.delete(id)
  end

  false
end

def last_answer(history: List[Protocol.Message]) -> String
  said = history.select { |m| not m.thinking and m.tool.none? and m.stop.none? }
  return "" if said.empty?

  said.last.text
end

def reason_of(seen: Spec.Seen) -> String
  JSON.string(JSON.get(seen.data, "stop_reason").unwrap_or(JSON.from(""))).unwrap_or("ended")
end

def cut(answer: String) -> String
  return answer if answer.length <= MAX_ANSWER_CHARS

  shown = answer.slice(0, MAX_ANSWER_CHARS)
  "#{shown}\n[answer cut: #{answer.length} characters, the first #{MAX_ANSWER_CHARS} are shown]"
end

def need_host(ctx: Spec.Context, tool: String) -> Result[Spec.Host]
  case ctx.host
    some(host) -> ok(host)
    none -> error("#{tool} needs a session to run in")
  end
end

def need_session(ctx: Spec.Context, tool: String) -> Result[String]
  case ctx.session
    some(id) -> ok(id)
    none -> error("#{tool} needs a session to run in")
  end
end

def deadline(limits: Limits) -> Optional[Int]
  return none if limits.timeout_ms == 0

  some(Time.monotonic_ms + limits.timeout_ms)
end

def past?(active: Active) -> Bool
  for end_at in option_list(active.deadline)
    return Time.monotonic_ms >= end_at
  end

  false
end

def wait_ms(live: List[Active]) -> Int
  ends = live.flat_map { |a| option_list(a.deadline) }
  return WAIT_MS if ends.empty?

  [[ends.min.unwrap! - Time.monotonic_ms, 0].max.unwrap!, WAIT_MS].min.unwrap!
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
