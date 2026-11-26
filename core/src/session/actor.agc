## A session: an actor that owns the history, the events and the running turn. HTTP handlers and the turn's task send
## it messages; every subscriber gets the same events.
##
## The events are numbered from 1. The session keeps the last `keep_events` of them, and every event of the running
## turn however many, so a client that attaches from `turn_from_event_id` replays the whole turn. A `Last-Event-ID`
## outside what it keeps gets `resync`.
##
## Every event and message goes to the session's file before a client sees it, so a session started again from its
## file keeps its ids. Text and thinking deltas are the exception: they are not saved. The first delta after a saved
## event reserves a block of `RESERVE` ids in the file, so a restart that cuts a run of deltas starts after them.
## After a restart, a `Last-Event-ID` before a delta that was not saved gets `resync`. A turn that a restart cut ends
## then as `cancelled`. When a write fails, the event gets no id: the clients get an `error` without one, the running
## turn stops, and no turn starts until a write works again.

import Actor from "std/actor"
import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import Agent from "../agent/agent"
import Compaction from "../agent/compaction"
import Extensions from "../config/registry"
import Branch from "branch"
import Export from "export"
import Profiles from "../config/profiles"
import Session from "state"
import Store from "store"
import Stream from "stream"
import Tools from "../tools/tools"
import Turn from "turn"

export Session.Endpoint
export Session.Setup
export Session.Reopened
export Session.Reloaded
export Session.Msg
export Session.State
export Session.Load
export Session.Copying
export Session.Copied
export Session.Fold

## The command outputs that wait for the next message, and their size together.
MAX_SHELLS = 20
MAX_SHELL_BYTES = 1_048_576

## Starts a session; from what its file saved when there is one.
def start(setup: Session.Setup, saved: Optional[Store.Saved] = none) -> Actor.Ref[Session.State, Session.Msg]
  init = -> {
    case saved
      some(s) -> restore(setup, s)
      none -> Session.State(setup: setup, window: setup.window)
    end
  }

  Actor.start(Actor.Behaviour(init: init, handle: &handle, terminate: some(&terminate)))
end

def snapshot(address: Address[Session.Msg]) -> Result[Protocol.Session]
  Actor.call(address, Session.CALL_MS) do |reply| Session.Msg.Snapshot(reply) end
end

def load(address: Address[Session.Msg]) -> Result[Session.Load]
  Actor.call(address, Session.CALL_MS) do |reply| Session.Msg.Load(reply) end
end

## The event stream from after `last_event_id` (from now when none), as SSE bytes.
def subscribe(address: Address[Session.Msg], last_event_id: Optional[Int]) -> Result[Channel[Bytes]]
  Actor.call(address, Session.CALL_MS) do |reply| Session.Msg.Subscribe(last_event_id, reply) end
end

## Starts a turn or queues the message into the running one; `session.busy` when it cannot.
def send(address: Address[Session.Msg], text: String) -> Result[Protocol.MessageAccepted]
  sent: Result[Result[Protocol.MessageAccepted]] = Actor.call(address, Session.CALL_MS) do |reply|
    Session.Msg.Send(text, reply)
  end

  ok(try try sent)
end

def answer(address: Address[Session.Msg], approval_id: String, decision: Protocol.Decision) -> Result[Void]
  answered: Result[Result[Void]] = Actor.call(address, Session.CALL_MS) do |reply|
    Session.Msg.Answer(approval_id, decision, reply)
  end

  try try answered
  ok()
end

## Ends the session when no turn runs; `session.busy` while one does.
def end_session(address: Address[Session.Msg]) -> Result[Void]
  closed: Result[Result[Void]] = Actor.call(address, Session.CALL_MS) do |reply| Session.Msg.Close(reply) end
  try try closed
  ok()
end

## Changes the model or the thinking level from the next turn on, and keeps them in the session's file.
def update(address: Address[Session.Msg], change: Protocol.UpdateSession) -> Result[Void]
  updated: Result[Result[Void]] = Actor.call(address, Session.CALL_MS) do |reply| Session.Msg.Update(change, reply) end
  try try updated
  ok()
end

## Reads the session's system prompt (`AGENTS.md` and the skills), extensions and approval again. A turn that runs keeps
## what it started with: the next one uses them.
def reload(address: Address[Session.Msg]) -> Result[Session.Reloaded]
  reloaded: Result[Result[Session.Reloaded]] = Actor.call(address, Session.CALL_MS) do |reply|
    Session.Msg.Reload(reply)
  end

  ok(try try reloaded)
end

## `setup` on `endpoint`, with its default model.
def switched(setup: Session.Setup, endpoint: Session.Endpoint) -> Session.Setup
  setup.with(
    provider_name: endpoint.name,
    refused: "",
    api: endpoint.api,
    model: endpoint.model,
    provider: endpoint.provider,
    extra: endpoint.extra,
    cache: endpoint.cache,
    headers: endpoint.headers,
    refresh: endpoint.refresh,
    props_url: endpoint.props_url,
    api_key: endpoint.api_key,
    compact_model: endpoint.compact_model,
    catalog_provider: endpoint.catalog_provider,
  )
end

## `setup` with the profile `name` of `loaded`: its tools, the text after the system prompt and what clients see of it.
## A profile that does not load shows no tool and refuses turns, also after a provider switch.
def applied(setup: Session.Setup, loaded: Profiles.Loaded, name: String) -> Session.Setup
  case Profiles.find(loaded, name)
    ok(found) ->
      seen = Protocol.Profile(
        name: found.name,
        source: found.source,
        description: found.description,
        warnings: Profiles.warnings_of(loaded, found, Profiles.known_tools()),
      )

      setup.with(
        system: Profiles.system(setup.base_system, found),
        shows: some(->(tool: String) { Profiles.exposes?(found, tool) }),
        profile: some(seen),
        profile_refused: "",
      )
    error(e) ->
      setup.with(
        system: setup.base_system,
        shows: some(->(_tool: String) { false }),
        profile: some(Protocol.Profile(name: name, source: "", warnings: [e.message])),
        profile_refused: e.message,
      )
  end
end

## Folds the history into a summary now, as a turn past the limit would; false when there is nothing to fold.
## `session.busy` while a turn or another compaction runs. The summary is asked outside the session, which only
## refuses new turns meanwhile.
def compact_now(address: Address[Session.Msg]) -> Result[Bool]
  taken: Result[Result[Session.Fold]] = Actor.call(address, Session.CALL_MS) do |reply| Session.Msg.Fold(reply) end
  fold = try try taken
  summary: Result[Optional[Compaction.Compaction]] = ok(none)
  for span in option_list(fold.span)
    renewal = Agent.with_token(
      fold.settings.provider.unwrap_or(fold.provider),
      fold.refresh,
      ->(p: LLM.Provider) { Compaction.summarize(p, fold.settings, fold.history, span) },
    )

    for provider in option_list(renewal.fresh)
      _ = Actor.cast(address, Session.Msg.Renewed(provider), Session.CALL_MS)
    end

    summary = case renewal.result
      ok(compaction) -> ok(some(compaction))
      error(e) -> error("the history was not compacted: #{e.message}", kind: Compaction.KIND_FAILED, cause: e)
    end
  end

  nothing: Optional[Compaction.Compaction] = none
  found = summary.unwrap_or(nothing)
  done: Result[Result[Void]] = Actor.call(address, Session.CALL_MS) do |reply| Session.Msg.Folded(found, reply) end
  _ = try summary
  try try done
  ok(found.some?)
end

## Runs a command in the session folder as the `bash` tool would, after the approval rules: `shell.denied` when a deny
## rule refuses it (the user typed it, so a rule that asks does not ask), `session.busy` while a turn, a compaction or
## another command runs. Its output comes in `shell_finished`.
def shell(address: Address[Session.Msg], request: Protocol.RunShell) -> Result[Protocol.ShellAccepted]
  run: Result[Result[Protocol.ShellAccepted]] = Actor.call(address, Session.CALL_MS) do |reply|
    Session.Msg.Shell(request, reply)
  end

  ok(try try run)
end

## Stops the running turn or command, with `turn_id` only that turn while it runs; whether one ran.
def stop(address: Address[Session.Msg], turn_id: Optional[String]) -> Result[Bool]
  Actor.call(address, Session.CALL_MS) do |reply| Session.Msg.Stop(turn_id, reply) end
end

## The folder of the session and what its rules hide, for reads outside the actor.
def place(address: Address[Session.Msg]) -> Result[Session.Place]
  Actor.call(address, Session.CALL_MS) do |reply| Session.Msg.Place(reply) end
end

## The user messages of every branch of the session.
def tree(address: Address[Session.Msg]) -> Result[Protocol.SessionTree]
  read: Result[Result[Protocol.SessionTree]] = Actor.call(address, Session.CALL_MS) do |reply|
    Session.Msg.Tree(reply)
  end

  ok(try try read)
end

## The branch the session is on, for a file.
def exported(address: Address[Session.Msg]) -> Result[Protocol.SessionExport]
  read: Result[Result[Protocol.SessionExport]] = Actor.call(address, Session.CALL_MS) do |reply|
    Session.Msg.Exported(reply)
  end

  ok(try try read)
end

## Goes on from `entry` of the tree; `session.busy` while a turn or a compaction runs. The clients get `resync`.
def branch(address: Address[Session.Msg], entry: Int) -> Result[Protocol.Branched]
  moved: Result[Result[Protocol.Branched]] = Actor.call(address, Session.CALL_MS) do |reply|
    Session.Msg.Branch(entry, reply)
  end

  ok(try try moved)
end

## Writes a new session file with the history up to `entry` (as `branch`), all of it when none; `session.busy` while a
## turn or a compaction runs.
def copy(address: Address[Session.Msg], entry: Optional[Int], to: Session.Copying) -> Result[Session.Copied]
  copied: Result[Result[Session.Copied]] = Actor.call(address, Session.CALL_MS) do |reply|
    Session.Msg.Copy(entry, to, reply)
  end

  ok(try try copied)
end

private

# A turn that a restart cut, with its approvals still waiting.
struct Cut
  turn_id: String
  approvals: List[String]
end

# A stop for a turn that is no longer the running one stops nothing.
def stops?(state: Session.State, turn_id: Optional[String]) -> Bool
  turn_id.none? or state.turn.map { |turn| turn.id } == turn_id
end

def handle(state: Session.State, msg: Session.Msg) -> Actor.Step[Session.State]
  case msg
    Session.Msg.Snapshot(reply) ->
      Actor.reply(reply, session(state))
      Actor.continue(state)
    Session.Msg.Load(reply) ->
      running = state.turn.some? or state.shell.some?
      Actor.reply(reply, Session.Load(running: running, asking: running and not state.pending.empty?))
      Actor.continue(state)
    Session.Msg.Subscribe(last, reply) -> Actor.continue(Stream.attach(state, last, reply))
    Session.Msg.Send(text, reply) -> Actor.continue(Turn.start_turn(state, text, reply))
    Session.Msg.Answer(approval_id, decision, reply) ->
      Actor.continue(Turn.answer_approval(state, approval_id, decision, reply))
    Session.Msg.Close(reply) ->
      if state.turn.some? or state.shell.some?
        Actor.reply(reply, error(Session.busy_reason(state), kind: Protocol.KIND_SESSION_BUSY))
        return Actor.continue(state)
      end

      Actor.reply(reply, ok())
      Actor.done(state)
    Session.Msg.Stop(turn_id, reply) if not stops?(state, turn_id) ->
      Actor.reply(reply, false)
      Actor.continue(state)
    Session.Msg.Place(reply) ->
      Actor.reply(reply, Session.Place(root: state.setup.ctx.root, hidden: state.setup.ctx.hidden))
      Actor.continue(state)
    Session.Msg.Stop(_, reply) ->
      Actor.reply(reply, state.turn.some? or state.shell.some?)
      Actor.continue(stop_shell(Turn.stop_turn(state)))
    Session.Msg.Emit(turn_id, event) ->
      Actor.continue(if_current(state, turn_id, ->(s) { Stream.emit_counted(s, event) }))
    Session.Msg.Ask(turn_id, call, reply) ->
      Actor.continue(if_current(state, turn_id, ->(s) { Turn.ask(s, call, reply) }))
    Session.Msg.Expire(turn_id) -> Actor.continue(if_current(state, turn_id, ->(s) { Turn.expire(s) }))
    Session.Msg.Take(turn_id, after, reply) -> Actor.continue(Turn.take(state, turn_id, after, reply))
    Session.Msg.Commit(turn_id, history, marks, read) ->
      Actor.continue(if_current(state, turn_id, ->(s) { Turn.commit(s, history, marks, read) }))
    Session.Msg.Compacted(turn_id, compaction) ->
      Actor.continue(if_current(state, turn_id, ->(s) { Turn.compact(s, compaction) }))
    Session.Msg.Window(window) -> Actor.continue(state.with(window: window))
    Session.Msg.Stripped(turn_id) -> Actor.continue(if_current(state, turn_id, ->(s) { Turn.stripped(s) }))
    Session.Msg.Renewed(provider) -> Actor.continue(state.with(setup: state.setup.with(provider: provider)))
    Session.Msg.Finished(turn_id, reason, limit) ->
      Actor.continue(if_current(state, turn_id, ->(s) { Turn.finish(s, reason, limit) }))
    Session.Msg.Update(change, reply) -> Actor.continue(update_setup(state, change, reply))
    Session.Msg.Reload(reply) -> Actor.continue(reload_setup(state, reply))
    Session.Msg.Fold(reply) -> Actor.continue(Turn.start_fold(state, reply))
    Session.Msg.Folded(found, reply) -> Actor.continue(Turn.end_fold(state, found, reply))
    Session.Msg.Exported(reply) ->
      Actor.reply(reply, Export.of(state.setup.file))
      Actor.continue(state)
    Session.Msg.Tree(reply) ->
      case Branch.indexed(state)
        ok(known) ->
          Actor.reply(reply, ok(Store.tree(known.entries.unwrap!)))
          Actor.continue(known)
        error(e) ->
          Actor.reply(reply, error(e))
          Actor.continue(state)
      end

    Session.Msg.Branch(entry, reply) -> Actor.continue(Branch.branch_to(state, entry, reply))
    Session.Msg.Copy(entry, to, reply) ->
      Actor.reply(reply, Branch.copied(state, entry, to))
      Actor.continue(state)
    Session.Msg.Shell(request, reply) -> Actor.continue(run_shell(state, request, reply))
    Session.Msg.ShellDone(id, output, duration_ms) -> Actor.continue(shell_done(state, id, output, duration_ms))
    Session.Msg.ShellDown(id, down) -> Actor.continue(shell_down(state, id, down))
  end
end

def terminate(state: Session.State) -> Void
  for turn in option_list(state.turn)
    Task.cancel(turn.task)
  end

  for run in option_list(state.shell)
    Task.cancel(run.task)
  end

  for out in state.subscribers
    out.close
  end
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end

# A message of a turn that was stopped is dropped.
def if_current(state: Session.State, turn_id: String, change: Fn[Session.State, Session.State]) -> Session.State
  case state.turn
    some(turn) if turn.id == turn_id -> change.call(state)
    _ -> state
  end
end

def session(state: Session.State) -> Protocol.Session
  Protocol.Session(
    id: state.setup.id,
    cwd: state.setup.cwd,
    model: state.setup.model,
    last_event_id: state.counter,
    turn_id: state.turn.map { |t| t.id },
    turn_from_event_id: state.turn.map { |t| t.from_event_id },
    pending_approvals: state.pending.map { |w| w.request },
    history: state.turn.map { |t| state.display.take(t.shown) }.unwrap_or(state.display),
    accept_edits: state.setup.approver.map { |a| a.accept_edits }.unwrap_or(false),
    confine: state.setup.ctx.confine,
    cost: state.cost,
    effort: state.setup.effort,
    provider: state.setup.provider_name,
    api: state.setup.api,
    shell_id: state.shell.map { |run| run.id },
    usage: state.usage,
    todos: state.todos,
    profile: state.setup.profile,
  )
end

def update_setup(state: Session.State, change: Protocol.UpdateSession, reply: Channel[Result[Void]]) -> Session.State
  asking = state.setup.approver.map { |a| a.asking }.unwrap_or(false)
  if change.accept_edits.some? and not asking
    Actor.reply(reply, error("accept_edits needs the approvals on (FINN_APPROVALS=1)", kind: Protocol.KIND_INVALID))

    return state
  end

  if change.profile.some? and Session.busy?(state)
    busy = "#{Session.busy_reason(state)}: change the profile after it"
    Actor.reply(reply, error(busy, kind: Protocol.KIND_SESSION_BUSY))
    return state
  end

  setup = state.setup
  for name in option_list(change.profile)
    case profiled(setup, name)
      ok(found) -> setup = found
      error(e) ->
        Actor.reply(reply, error(e.message, kind: Protocol.KIND_INVALID))
        return state
    end
  end

  for name in option_list(change.provider)
    case resolve_endpoint(setup, name)
      ok(endpoint) -> setup = switched(setup, endpoint)
      error(e) ->
        Actor.reply(reply, error(e.message, kind: Protocol.KIND_INVALID))
        return state
    end
  end

  setup = setup.with(model: change.model.unwrap_or(setup.model))
  if change.model.some? or change.provider.some?
    case Turn.route(setup)
      error(e) ->
        Actor.reply(reply, error(e.message, kind: Protocol.KIND_INVALID))
        return state
      ok(_) -> nil
    end
  end

  for on in option_list(change.accept_edits)
    setup = setup.with(approver: setup.approver.map { |a| a.with_accept_edits.call(on) })
  end

  for on in option_list(change.confine)
    setup = setup.with(ctx: setup.ctx.with(confine: on))
  end

  case change.effort
    some(level) if level == Protocol.EFFORT_DEFAULT -> setup = setup.with(effort: none)
    some(level) -> setup = setup.with(effort: some(level))
    none -> nil
  end

  case Stream.save(state, -> { Store.append_settings(state.setup.file, Session.choice(setup)) })
    ok(_) ->
      Actor.reply(reply, ok())
      state.with(setup: setup, broken: none)
    error(e) ->
      Actor.reply(
        reply,
        error("the session file cannot be written: #{e.message}", kind: Protocol.KIND_SESSION_STORAGE),
      )

      state.with(broken: some(e.message))
  end
end

# The setup with what a reload read again; the accept-edits mode stays, the answers of "allow" do not. A session that
# cannot read it again keeps its setup and says why.
def reload_setup(state: Session.State, reply: Channel[Result[Session.Reloaded]]) -> Session.State
  setup = state.setup
  for read in option_list(setup.reopen)
    case read.call()
      error(e) ->
        Actor.reply(reply, error(e.message, kind: e.kind))
        return state
      ok(fresh) ->
        warnings = fresh.warnings
        prompt_pending = state.prompt_pending
        if prompt_pending or some(fresh.prompt) != setup.prompt
          case Store.save_prompt(setup.file, fresh.prompt)
            error(e) ->
              warnings = warnings.push("could not save the session prompt: #{e.message}")
              prompt_pending = true
            ok(_) -> prompt_pending = false
          end
        end

        approver = fresh.approver
        for old in option_list(setup.approver)
          approver = fresh.approver.map { |a| a.with_accept_edits.call(old.accept_edits) }
        end

        ctx = setup.ctx.with(read_roots: Extensions.read_roots(fresh.builtins), hidden: approver.map { |a| a.hidden })
        next = setup.with(
          system: fresh.system,
          base_system: fresh.system,
          prompt: some(fresh.prompt),
          builtins: fresh.builtins,
          approver: approver,
          ctx: ctx,
          skills: fresh.skills,
        )

        for profile in option_list(setup.profile)
          loaded = setup.profiles.map { |load| load.call() }.unwrap_or(Profiles.Loaded(profiles: Profiles.builtins()))
          next = applied(next, loaded, profile.name)
        end

        Actor.reply(
          reply,
          ok(
            Session.Reloaded(
              added: fresh.skills.select { |name| not setup.skills.include?(name) },
              removed: setup.skills.select { |name| not fresh.skills.include?(name) },
              warnings: warnings,
            ),
          ),
        )

        return state.with(setup: next, prompt_pending: prompt_pending)
    end
  end

  Actor.reply(reply, ok(Session.Reloaded()))
  state
end

# `setup` with the profile `name`, and its model and thinking level when it sets them: `PROVIDER/NAME` moves to that
# provider when the session can, else the whole text is the model. A project's profile never moves the session to
# another provider: its model is a name on the session's.
def profiled(setup: Session.Setup, name: String) -> Result[Session.Setup]
  loaded = setup.profiles.map { |read| read.call() }.unwrap_or(Profiles.Loaded(profiles: Profiles.builtins()))
  found = try Profiles.find(loaded, name)
  done = applied(setup, loaded, name)
  if not found.model.empty?
    done = done.with(model: found.model)
    at_provider = found.model.index_of("/")
    if found.source == Profiles.PROJECT
      at_provider = none
    end

    for at in option_list(at_provider)
      case resolve_endpoint(done, found.model.slice(0, at))
        ok(endpoint) ->
          done = switched(done, endpoint).with(model: found.model.slice(at + 1, found.model.length - at - 1))
        error(_) -> nil
      end
    end
  end

  return ok(done) if found.thinking.empty?
  return ok(done.with(effort: none)) if found.thinking == Protocol.EFFORT_DEFAULT

  ok(done.with(effort: some(found.thinking)))
end

def resolve_endpoint(setup: Session.Setup, name: String) -> Result[Session.Endpoint]
  case setup.endpoint
    some(endpoint) -> endpoint.call(name, setup.api)
    none -> error("this session cannot change its provider")
  end
end

def run_shell(
  state: Session.State,
  request: Protocol.RunShell,
  reply: Channel[Result[Protocol.ShellAccepted]],
) -> Session.State
  if Session.busy?(state)
    Actor.reply(reply, error(Session.busy_reason(state), kind: Protocol.KIND_SESSION_BUSY))
    return state
  end

  # The user can stop the command, so it may run as long as a `bash` call can.
  input = JSON.object({"command": JSON.from(request.command), "timeout_ms": JSON.from(Tools.MAX_BASH_TIMEOUT_MS)})
  verdict = Turn.gate(state.setup.approver).map { |g| g.call(state.setup.ctx, Tools.BASH, input) }
  if verdict == some(Tools.Verdict.Deny)
    Actor.reply(reply, error("a rule of the config denies this command", kind: Protocol.KIND_SHELL_DENIED))
    return state
  end

  id = "shell-#{OpenSSL.Random.hex(4)}"
  inbox: Channel[Session.Msg] = Actor.inbox
  address = inbox.address
  ctx = state.setup.ctx
  started_ms = Time.monotonic_ms
  task = Task.spawn(
    -> {
      output = Tools.run(ctx, Tools.BASH, input)
      _ = Actor.cast(address, Session.Msg.ShellDone(id, output, Time.monotonic_ms - started_ms), Session.CALL_MS)
    },
  )

  Task.monitor(task, inbox) do |down| Session.Msg.ShellDown(id, down) end

  run = Session.ShellRun(
    id: id,
    command: request.command,
    context: request.context,
    task: task,
    started_ms: started_ms,
  )

  Actor.reply(reply, ok(Protocol.ShellAccepted(shell_id: id)))
  started = Protocol.ShellStarted(shell_id: id, command: request.command, context: request.context)
  Stream.emit(state.with(shell: some(run)), Protocol.Event.ShellStarted(started))
end

# The output goes to the model unless the command was stopped or the outputs waiting would pass the limits; the event
# says whether it does.
def shell_done(
  state: Session.State,
  id: String,
  output: Tools.Output,
  duration_ms: Int,
  stopped: Bool = false,
) -> Session.State
  case state.shell
    some(run) if run.id == id ->
      finished = Protocol.ShellFinished(
        shell_id: id,
        command: run.command,
        context: false,
        ok: not output.is_error,
        output: output.text,
        duration_ms: duration_ms,
      )

      text = Store.shell_context(finished)
      fits = state.shells.size < MAX_SHELLS and (state.shells + [text]).join("\n\n").bytesize <= MAX_SHELL_BYTES
      if run.context and not stopped and fits
        finished = finished.with(context: true)
      end

      if run.context and not stopped and not fits
        note = "[#{MAX_SHELLS} outputs or #{MAX_SHELL_BYTES} bytes already wait for the next message]"
        finished = finished.with(output: "#{output.text}\n#{note}")
      end

      done = Stream.emit(state.with(shell: none), Protocol.Event.ShellFinished(finished))
      return done if not finished.context or done.counter == state.counter

      done.with(shells: done.shells.push(text))
    _ -> state
  end
end

# A command whose task ended without its output (a crash, or an inbox too full for it) ends as failed.
def shell_down(state: Session.State, id: String, down: TaskDown) -> Session.State
  for run in option_list(state.shell)
    if run.id == id
      lost = Tools.Output(text: "the command ended without its output", is_error: true)
      return shell_done(state, id, lost, Time.monotonic_ms - run.started_ms, true)
    end
  end

  state
end

def stop_shell(state: Session.State) -> Session.State
  for run in option_list(state.shell)
    Task.cancel(run.task)
    stopped = Tools.Output(text: "stopped by the user", is_error: true)
    return shell_done(state, run.id, stopped, Time.monotonic_ms - run.started_ms, true)
  end

  state
end

def restore(setup: Session.Setup, saved: Store.Saved) -> Session.State
  events = saved.events
  changed = setup.with(model: saved.model.unwrap_or(setup.model))
  if saved.model.some?
    changed = changed.with(effort: saved.effort)
  end

  state = Session.State(
    setup: changed,
    counter: [saved.last_id, saved.reserved].max.unwrap!,
    reserved: [saved.last_id, saved.reserved].max.unwrap!,
    lost_below: lost_below(events),
    log: events.drop([events.size - setup.keep_events, 0].max.unwrap!),
    history: saved.history,
    marks: saved.marks,
    stripped: saved.stripped,
    display: saved.shown,
    shells: saved.shells,
    turns: saved.turns,
    approvals: saved.approvals,
    resolved: resolved_ids(events),
    output: saved.usage.map { |u| u.output }.unwrap_or(0),
    context: Session.last_usage(events).context,
    usage: saved.usage,
    todos: Session.last_todos(events),
    cost: saved.usage.map { |u| u.session_cost }.unwrap_or(none),
    window: setup.window,
  )

  # A user message after the last `turn_started` belongs to no turn of the events.
  turn_messages = state.history.size
  if saved.open_user
    turn_messages = turn_messages - 1
  end

  # The deltas of a cut turn after its last saved event are lost too, and so are the events of other branches after
  # the last of this one.
  cut_state = state
  on_branch = events.map { |logged| logged.id }.max.unwrap_or(0)
  if cut_turn(events).some? or saved.open_user or saved.last_id > on_branch
    cut_state = state.with(lost_below: state.counter)
  end

  ended_cut = case cut_turn(events)
    some(cut) -> end_cut_turn(cut_state, cut, turn_messages, saved.folded)
    none -> ended_shell(cut_state, events)
  end

  return ended_cut if not saved.open_user

  # The server stopped between the user message of a turn and its `turn_started`.
  turn_id = Turn.new_turn_id(ended_cut.turns)
  size = some(ended_cut.display.size)
  started = Stream.emit(
    ended_cut,
    Protocol.Event.TurnStarted(Protocol.TurnStarted(turn_id: turn_id, history_size: size)),
  )

  end_cut_turn(started, Cut(turn_id: turn_id, approvals: []), started.history.size, none)
end

# A command that a restart cut ends as failed, its output not for the model, so the clients stop waiting for it.
def ended_shell(state: Session.State, events: List[Store.Logged]) -> Session.State
  cut: Optional[Protocol.ShellStarted] = none
  for logged in events
    case logged.event
      Protocol.Event.ShellStarted(started) -> cut = some(started)
      # A turn starts only once no command runs: one before it ended unseen (a file of an older server).
      Protocol.Event.ShellFinished(_), Protocol.Event.TurnStarted(_) -> cut = none
      _ -> nil
    end
  end

  for started in option_list(cut)
    finished = Protocol.ShellFinished(
      shell_id: started.shell_id,
      command: started.command,
      context: false,
      ok: false,
      output: "the server stopped while it ran",
      duration_ms: 0,
    )

    return Stream.emit(state, Protocol.Event.ShellFinished(finished))
  end

  state
end

# The last id that no saved event has, below the last saved one: a delta that was not saved.
def lost_below(events: List[Store.Logged]) -> Int
  lost = 0
  last = 0
  for logged in events
    if logged.id > last + 1
      lost = logged.id - 1
    end

    last = logged.id
  end

  lost
end

def resolved_ids(events: List[Store.Logged]) -> List[String]
  ids: List[String] = []
  for logged in events
    case logged.event
      Protocol.Event.ApprovalResolved(resolved) -> ids = ids.push(resolved.approval_id)
      _ -> nil
    end
  end

  ids
end

def cut_turn(events: List[Store.Logged]) -> Optional[Cut]
  cut: Optional[Cut] = none
  for logged in events
    case logged.event
      Protocol.Event.TurnStarted(started) -> cut = some(Cut(turn_id: started.turn_id, approvals: []))
      Protocol.Event.TurnFinished(_) -> cut = none
      Protocol.Event.ApprovalRequested(request) ->
        cut = cut.map { |c| c.with(approvals: c.approvals.push(request.approval_id)) }
      Protocol.Event.ApprovalResolved(resolved) ->
        cut = cut.map { |c| c.with(approvals: c.approvals.select { |a| a != resolved.approval_id }) }
      _ -> nil
    end
  end

  cut
end

# The turn's messages are the first `messages` of the history; `folded` has its answer when it was compacted.
def end_cut_turn(state: Session.State, cut: Cut, messages: Int, folded: Optional[Store.Folded]) -> Session.State
  out = state
  for approval_id in cut.approvals
    resolved = Protocol.ApprovalResolved(
      approval_id: approval_id,
      decision: Protocol.Decision.Deny,
      source: Protocol.ApprovalSource.Stop,
    )

    out = Stream.emit(out.with(resolved: out.resolved.push(approval_id)), Protocol.Event.ApprovalResolved(resolved))
  end

  history = out.history.take(messages)
  texts = case folded
    some(f) -> f.texts + Turn.answer_texts(history.drop(f.at))
    none -> Turn.answer_texts(history.drop(turn_message(history) + 1))
  end

  Turn.ended(out, cut.turn_id, texts, Protocol.StopReason.Cancelled)
end

# Where the last turn began: its user message is the last one with text (tool results have none).
def turn_message(history: List[LLM.Message]) -> Int
  at = history.size
  for i in 0...history.size
    if history[i].role == LLM.Role.User and history[i].content.any? { |b| text_block?(b) }
      at = i
    end
  end

  at
end

def text_block?(block: LLM.Block) -> Bool
  case block
    LLM.Block.Text(_) -> true
    _ -> false
  end
end
