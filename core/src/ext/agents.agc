## The built-in subagent tools: `agent` starts one child session per task, sends it its prompt and either waits
## for their answers or returns their ids; `agent_send` sends a follow-up message to a child, waiting or not; and
## `agent_stop` stops a child's turn. They run over the session's own handle (`Spec.Context.host`), so a stranger's
## id, a deleted child and the session itself are refused exactly as the handle refuses them. A child's answer comes
## back cut at `MAX_ANSWER_CHARS` characters, under its name and provider and model. A wait ends when the child's
## turn does or when `Limits.timeout_ms` stops it; a parent's `/stop` stops the children's turns too through the
## session route, and they stay open. A child that times out stays open for `agent_send` follow-up; an async child
## stays open too, and every child dies with its parent. One watcher per child dispatches each `turn_finished` to
## the waiter of its turn or to the parent's wake, by turn id, so a waited follow-up after an async start and two
## waited follow-ups in a row each get their own answer and never wake twice. Transient waiter state (the expected
## turns and the waiter addresses) is cleared on every completion, timeout or delete, so it never grows past the live
## turns; the names keep one display name per live child.

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

## A `turn_finished` of a child: its id, the turn it ends and why it ended.
struct Heard
  id: String
  turn_id: String
  reason: String
end

## The subagent tools: a roster read fresh on every call (and naming the profiles in their description), the bounds,
## and the per-session tables of expected turns, waiter addresses and display names. The description is made when the
## tools are, so a session reads its profiles again on every turn.
def tools(
  roster: Fn[List[Profile]],
  limits: Limits,
  turns: ATS[String, String],
  waits: ATS[String, Address[Heard]],
  names: ATS[String, String],
) -> List[Spec.Tool]
  [
    Spec.Tool(
      name: AGENT,
      description: agent_description(roster),
      input_schema: JSON.schema(AgentArgs),
      asks: false,
      run: ->(ctx: Spec.Context, input: JSON.Value) { run_all(ctx, input, roster, limits, turns, waits, names) },
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
      run: ->(ctx: Spec.Context, input: JSON.Value) { run_send(ctx, input, limits, turns, waits, names) },
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

struct Reaped
  live: List[Active]
  found: Map[Int, String]
end

def agent_description(roster: Fn[List[Profile]]) -> String
  lines = roster.call().map { |p| "- #{p.name}: #{shown_description(p)} (#{p.provider}/#{p.model})" }
  base = (
    "Start one subagent per task: a child session with its own provider, model and profile that works on its " +
    "prompt and reports back, in parallel. `agent` names the profile it runs (the session's own when empty), " +
    "from the roster below; a profile whose provider is not set up is left out. With `wait` (the default) it " +
    "answers with each answer in input order, each under `NAME (provider/model): reason` and cut at 8000 characters; " +
    "without it, it answers with their ids, one per line, and each answer wakes this session."
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
  turns: ATS[String, String],
  waits: ATS[String, Address[Heard]],
  names: ATS[String, String],
) -> Result[String]
  args = try Spec.args(input, AgentArgs.codec)
  return error("agent needs at least one task") if args.tasks.empty?

  host = try need_host(ctx, AGENT)
  own = try need_session(ctx, AGENT)
  listed = roster.call()
  for task in args.tasks
    return error("a task needs a prompt") if task.prompt.strip.empty?
    for name in option_list(profile_of(task))
      if not listed.any? { |p| p.name == name }
        return error("unknown profile #{name.inspect}: one of #{listed.map { |p| p.name }.join(", ")}")
      end
    end
  end

  parent = try parent_profile(host, own)
  if args.wait.unwrap_or(true)
    run_waiting(host, parent, args.tasks, limits, turns, waits, names)
  else
    run_async(host, own, parent, args.tasks, limits, turns, waits, names)
  end
end

def run_send(
  ctx: Spec.Context,
  input: JSON.Value,
  limits: Limits,
  turns: ATS[String, String],
  waits: ATS[String, Address[Heard]],
  names: ATS[String, String],
) -> Result[String]
  args = try Spec.args(input, SendArgs.codec)
  return error("agent_send needs some text") if args.text.strip.empty?

  host = try need_host(ctx, SEND)
  own = try need_session(ctx, SEND)
  return error("agent_send takes a subagent id, not the session's own") if args.id == own

  if args.wait.unwrap_or(true)
    send_waiting(host, own, args, limits, turns, waits, names)
  else
    send_async(host, own, args, turns, waits, names)
  end
end

def run_stop(ctx: Spec.Context, input: JSON.Value) -> Result[String]
  args = try Spec.args(input, StopArgs.codec)
  host = try need_host(ctx, STOP)
  own = need_session(ctx, STOP).unwrap_or("")
  return error("agent_stop takes a subagent id, not the session's own") if args.id == own and not own.empty?

  case host.stop.call(args.id)
    ok(false) -> ok("idle")
    ok(_) -> ok("stopped")
    error(e) -> error(e)
  end
end

# Every task's child, started up to `limits.max` at once (in input order) and collected as they finish, in input
# order. A child that fails to start fails only its task. A wait with no timeout loops on its heartbeat instead of
# stopping anything; a timed-out child is stopped but stays open for follow-up.
def run_waiting(
  host: Spec.Host,
  parent: String,
  tasks: List[AgentTask],
  limits: Limits,
  turns: ATS[String, String],
  waits: ATS[String, Address[Heard]],
  names: ATS[String, String],
) -> Result[String]
  done: Channel[Heard] = Channel.new([2 * tasks.size + 2, 4].max.unwrap!)
  addr = done.address
  live: List[Active] = []
  results: Map[Int, String] = {}
  next = 0
  while next < tasks.size or not live.empty?
    while next < tasks.size and (limits.max == 0 or live_count(host, turns) < limits.max)
      name = named(tasks[next], parent)
      case start_child(host, tasks[next], name, next, limits, addr, turns, waits, names)
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
            results = results.put(active.index, collected(host, active, heard.reason, turns, waits, names, true))
          error(_) -> nil
        end

      error(_) ->
        overdue = live.select { |a| past?(a) }
        if limits.timeout_ms > 0 and not overdue.empty?
          for active in overdue
            _ = host.stop.call(active.id)
            results = results.put(active.index, partial(host, active, limits))
            forget(turns, waits, active.id)
            live = live.select { |a| a.id != active.id }
          end
        else
          # A heartbeat with nothing overdue: reap gone children and answers the watcher missed, then wait again.
          # A real parent `/stop` cancels this task, so this never stops anything.
          reaped = reap_finished(host, live, turns, waits, names)
          live = reaped.live
          for index in reaped.found.keys()
            for text in option_list(reaped.found.get(index))
              results = results.put(index, text)
            end
          end
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

# Every task's child at once when the whole batch fits; otherwise nothing starts and the call fails with the cap, so
# no started id is ever lost and no unknown child is left running. Each answer wakes the session when it comes.
def run_async(
  host: Spec.Host,
  own: String,
  parent: String,
  tasks: List[AgentTask],
  limits: Limits,
  turns: ATS[String, String],
  waits: ATS[String, Address[Heard]],
  names: ATS[String, String],
) -> Result[String]
  return error(capped(limits.max)) if limits.max > 0 and live_count(host, turns) + tasks.size > limits.max

  started: List[String] = []
  for task in tasks
    name = named(task, parent)
    created = host.create.call(Spec.NewChild(profile: profile_of(task)))
    case created
      error(e) ->
        cleanup_started(host, started, turns, waits, names)
        return error(e.message)
      ok(_) -> nil
    end

    child = created.unwrap_or("")
    started = started.push(child)
    names.put(child, name)
    case ensure_watch(host, own, child, turns, waits, names)
      error(e) ->
        cleanup_started(host, started, turns, waits, names)
        return error(e.message)
      ok(_) -> nil
    end

    case host.send.call(child, task.prompt)
      error(e) ->
        cleanup_started(host, started, turns, waits, names)
        return error(e.message)
      ok(_) -> nil
    end

    case turn_of_child(host, child)
      ok(turn) -> turns.put(child, turn)
      error(e) ->
        cleanup_started(host, started, turns, waits, names)
        return error(e.message)
    end
  end

  ok(started.join("\n"))
end

def capped(max: Int) -> String
  "at most #{max} subagents run at once of this session: wait for one with agent_send, or stop one with agent_stop"
end

def send_waiting(
  host: Spec.Host,
  own: String,
  args: SendArgs,
  limits: Limits,
  turns: ATS[String, String],
  waits: ATS[String, Address[Heard]],
  names: ATS[String, String],
) -> Result[String]
  done: Channel[Heard] = Channel.new(4)
  addr = done.address
  id = args.id
  names.put(id, id)
  case ensure_watch(host, own, id, turns, waits, names)
    error(e) -> return error(e.message)
    ok(_) -> nil
  end

  waits.put(id, addr)
  case host.send.call(id, args.text)
    error(e) ->
      forget(turns, waits, id)
      return error(e.message)
    ok(_) -> nil
  end

  case turn_of_child(host, id)
    ok(turn) -> turns.put(id, turn)
    error(e) ->
      forget(turns, waits, id)
      return error(e.message)
  end

  active = Active(index: 0, id: id, name: id, deadline: deadline(limits))
  while true
    case done.recv(wait_ms([active]))
      ok(heard) -> return ok(collected(host, active, heard.reason, turns, waits, names, false))
      error(_) ->
        if limits.timeout_ms > 0 and past?(active)
          _ = host.stop.call(id)
          text = partial(host, active, limits)
          forget(turns, waits, id)
          return ok(text)
        end

        # A heartbeat with no deadline: the turn is still running, so wait again. A child gone since is an
        # error, and an answer the watcher missed is collected from its snapshot.
        case host.snapshot.call(id)
          ok(session) ->
            if session.turn_id.some?
              nil
            else
              forget(turns, waits, id)
              return ok(collected(host, active, "ended", turns, waits, names, false))
            end

          error(e) ->
            forget(turns, waits, id)
            return error(e.message)
        end
    end
  end

  error("the agent call stopped with its turn")
end

def send_async(
  host: Spec.Host,
  own: String,
  args: SendArgs,
  turns: ATS[String, String],
  waits: ATS[String, Address[Heard]],
  names: ATS[String, String],
) -> Result[String]
  id = args.id
  names.put(id, id)
  case ensure_watch(host, own, id, turns, waits, names)
    error(e) -> return error(e.message)
    ok(_) -> nil
  end

  case host.send.call(id, args.text)
    error(e) ->
      forget(turns, waits, id)
      return error(e.message)
    ok(_) -> nil
  end

  case turn_of_child(host, id)
    ok(turn) -> turns.put(id, turn)
    error(e) ->
      forget(turns, waits, id)
      return error(e.message)
  end

  ok(id)
end

# One finished child: its last answer under its name, or why it cannot be read. A child this call started is deleted
# with its answer, so no worker of it is left; a follow-up child stays open.
def collected(
  host: Spec.Host,
  active: Active,
  reason: String,
  turns: ATS[String, String],
  waits: ATS[String, Address[Heard]],
  names: ATS[String, String],
  remove: Bool,
) -> String
  text = case host.snapshot.call(active.id)
    ok(session) ->
      "#{head(active.name, session.provider, session.model, reason)}\n#{cut(last_answer(session.history))}"
    error(e) -> "#{active.name}: could not read the answer: #{e.message}"
  end

  forget(turns, waits, active.id)
  if remove
    _ = host.delete.call(active.id)
    names.delete(active.id)
  end

  text
end

# A child past its deadline: its turn is stopped, and the result holds the part of the answer there is. The child
# stays open for `agent_send` follow-up.
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

def named(task: AgentTask, parent: String) -> String = profile_of(task).unwrap_or(parent)

def profile_of(task: AgentTask) -> Optional[String]
  case task.agent
    some(name) if not name.empty? -> some(name)
    _ -> none
  end
end

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
  addr: Address[Heard],
  turns: ATS[String, String],
  waits: ATS[String, Address[Heard]],
  names: ATS[String, String],
) -> Result[Active]
  child = try host.create.call(Spec.NewChild(profile: profile_of(task)))
  names.put(child, name)
  case ensure_watch(host, "", child, turns, waits, names)
    error(e) ->
      cleanup_one(host, child, turns, waits, names)
      return error(e.message)
    ok(_) -> nil
  end

  waits.put(child, addr)
  case host.send.call(child, task.prompt)
    error(e) ->
      cleanup_one(host, child, turns, waits, names)
      return error(e.message)
    ok(_) -> nil
  end

  case turn_of_child(host, child)
    ok(turn) -> turns.put(child, turn)
    error(e) ->
      cleanup_one(host, child, turns, waits, names)
      return error(e.message)
  end

  ok(Active(index: index, id: child, name: name, deadline: deadline(limits)))
end

# The one watcher of a child: later watches of the same names keep this first handler by the `Watch` contract, so
# every waiter registers through it. It sends the finish to the waiter of its turn, or wakes the parent when no
# waiter waits for that turn. A turn id it does not expect is stale and dropped, so no duplicate or misdirected wake
# ever runs.
def ensure_watch(
  host: Spec.Host,
  own: String,
  child: String,
  turns: ATS[String, String],
  waits: ATS[String, Address[Heard]],
  names: ATS[String, String],
) -> Result[Void]
  host.watch.call(
    child,
    ["turn_finished"],
    ->(seen: Spec.Seen) { dispatch(host, own, child, turns, waits, names, seen) },
  )
end

def dispatch(
  host: Spec.Host,
  own: String,
  child: String,
  turns: ATS[String, String],
  waits: ATS[String, Address[Heard]],
  names: ATS[String, String],
  seen: Spec.Seen,
) -> Void
  turn = turn_of(seen)
  reason = reason_of(seen)
  case turns.get(child)
    ok(expected) if turn != "" and turn != expected -> return
    ok(_) -> nil
    error(_) ->
      # No expected turn yet: the send has not recorded it. A waiter still gets it, so a fast finish cannot hang;
      # without a waiter there is nothing to wake yet.
      case waits.get(child)
        ok(addr) ->
          _ = addr.send(Heard(id: child, turn_id: turn, reason: reason), 1000)
          forget(turns, waits, child)
          return
        error(_) -> return
      end
  end

  case waits.get(child)
    ok(addr) ->
      _ = addr.send(Heard(id: child, turn_id: turn, reason: reason), 1000)
      forget(turns, waits, child)
    error(_) ->
      turns.delete(child)
      wake_parent(host, own, child, names, seen, reason)
  end
end

# The wake of an async answer: one event wakes once, and a child gone since is no wake. The wake comes from the
# extension, since only a child's own handle wakes as the child.
def wake_parent(
  host: Spec.Host,
  own: String,
  child: String,
  names: ATS[String, String],
  seen: Spec.Seen,
  reason: String,
) -> Void
  return if own.empty?

  snapshot = case host.snapshot.call(child)
    ok(session) -> some(session)
    error(_) -> none
  end

  for session in option_list(snapshot)
    display = case names.get(child)
      ok(name) -> name
      error(_) -> child
    end

    headed = head(display, session.provider, session.model, reason)
    _ = host.send.call(own, "#{headed}\n#{cut(last_answer(session.history))}")
  end
end

def cleanup_one(
  host: Spec.Host,
  child: String,
  turns: ATS[String, String],
  waits: ATS[String, Address[Heard]],
  names: ATS[String, String],
) -> Void
  forget(turns, waits, child)
  names.delete(child)
  _ = host.delete.call(child)
end

def cleanup_started(
  host: Spec.Host,
  started: List[String],
  turns: ATS[String, String],
  waits: ATS[String, Address[Heard]],
  names: ATS[String, String],
) -> Void
  for child in started
    cleanup_one(host, child, turns, waits, names)
  end
end

def forget(turns: ATS[String, String], waits: ATS[String, Address[Heard]], child: String) -> Void
  turns.delete(child)
  waits.delete(child)
end

# How many children of this session have an expected turn: the slots the cap counts. Children gone since leave the
# table, so the count never grows past the live turns. This counts optimistically from the tables, not from snapshots,
# so two calls in a row cannot evade the cap while a just-started turn is not yet visible.
def live_count(host: Spec.Host, turns: ATS[String, String]) -> Int
  for id in turns.keys()
    case host.snapshot.call(id)
      ok(_) -> nil
      error(e) if e.kind == Protocol.KIND_SESSION_NOT_FOUND -> forget_turn(turns, id)
      error(_) -> nil
    end
  end

  turns.keys().size
end

def forget_turn(turns: ATS[String, String], id: String) -> Void
  turns.delete(id)
end

# A heartbeat with nothing overdue: children gone since fail their task, and answers the watcher missed are
# collected from their snapshots, so a dropped event never hangs the call.
def reap_finished(
  host: Spec.Host,
  live: List[Active],
  turns: ATS[String, String],
  waits: ATS[String, Address[Heard]],
  names: ATS[String, String],
) -> Reaped
  kept: List[Active] = []
  found: Map[Int, String] = {}
  for active in live
    case host.snapshot.call(active.id)
      ok(session) ->
        if session.turn_id.some?
          kept = kept.push(active)
        else
          forget(turns, waits, active.id)
          found = found.put(active.index, collected(host, active, "ended", turns, waits, names, true))
        end

      error(e) ->
        forget(turns, waits, active.id)
        names.delete(active.id)
        found = found.put(active.index, "#{active.name}: #{e.message}")
    end
  end

  Reaped(live: kept, found: found)
end

def turn_of_child(host: Spec.Host, child: String) -> Result[String]
  case host.snapshot.call(child)
    ok(session) ->
      for turn in option_list(session.turn_id)
        return ok(turn)
      end

      error("the subagent ended before its turn started")
    error(e) -> error(e.message)
  end
end

def last_answer(history: List[Protocol.Message]) -> String
  said = history.select { |m| not m.thinking and m.tool.none? and m.stop.none? }
  return "" if said.empty?

  said.last.text
end

def reason_of(seen: Spec.Seen) -> String
  text = JSON.string(JSON.get(seen.data, "stop_reason").unwrap_or(JSON.from(""))).unwrap_or("")
  return "ended" if text.empty?

  text
end

def turn_of(seen: Spec.Seen) -> String
  JSON.string(JSON.get(seen.data, "turn_id").unwrap_or(JSON.from(""))).unwrap_or("")
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
