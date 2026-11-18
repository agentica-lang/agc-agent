## The sessions of the server: a registry actor that lists the session files and creates, finds, loads and deletes
## sessions, and the calls on one session by its id (`actor.agc` is the session itself).
##
## The sessions live in `sessions/` of the data folder (0700), one file each (`Store`). At start the registry reads only
## the first line of each file, for the list; a session is loaded from its file on its first request, in a task of its
## own, so a big file never holds up the requests of other sessions.

import Actor from "std/actor"
import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import Catalog from "../providers/catalog"
import Config from "../config/config"
import Commands from "../ext/commands"
import Profiles from "../config/profiles"
import Skills from "../ext/skills"
import Logins from "../providers/logins"
import Providers from "../providers/providers"
import Extensions from "../config/registry"
import Sandbox from "../tools/sandbox"
import Spec from "../tools/spec"
import Tools from "../tools/tools"
import SessionActor from "actor"
import Folder from "folder"
import Prompt from "prompt"
import Store from "store"
import Logger from "std/logger"

SESSIONS_DIR = "sessions"
CALL_MS = 5000
# How long a reload waits for another one that runs.
RELOAD_WAIT_MS = 150_000
## A request for a session that is not loaded yet waits for its load.
LOAD_MS = 60_000
## A session whose file names a model API this server does not have; its 503 says so.
KIND_UNKNOWN_API = "core.unknown_api"
## The requests that may wait for one load; past them a request answers 503.
MAX_WAITING = 64

## The registry, which owns the sessions.
struct Sessions
  registry: Actor.Ref[Registry, Msg]
  options: Config.Options
  dir: String
  ## One token: a reload holds it, so two reloads do not run at once.
  reloading: Channel[Bool]
end

## How many sessions the server has, how many of them work now (a turn or a shell command; only a loaded session can),
## and how many of those wait for something else than the answer to an approval.
struct Activity
  sessions: Int
  running: Int
  busy: Int
end

## The folder of the session files.
def folder(options: Config.Options) -> String = "#{options.data_dir}/#{SESSIONS_DIR}"

## Starts the registry, which lists the session files of `options` in `store` (on disk when none), and the holder of
## the providers.
def start(given: Config.Options, store: Optional[Store.Port] = none) -> Sessions
  observers = given.registry.map { |served| Extensions.observe(served.registry) }.unwrap_or([])
  options = given.with(logins: some(Logins.start(given.providers, given.login)), observers: observers)
  warn_profiles(options)
  port = store.unwrap_or(Store.disk())
  init = -> {
    inbox: Channel[Msg] = Actor.inbox()
    Registry(options: options, store: port, sessions: load_sessions(options, port), address: inbox.address)
  }

  registry = Actor.start(Actor.Behaviour(init: init, handle: &handle, terminate: some(&terminate)))
  gate: Channel[Bool] = Channel.new(1)
  _ = gate.send(true, 0)
  Sessions(registry: registry, options: options, dir: folder(options), reloading: gate)
end

## Stops the registry and the sessions it runs.
def stop(sessions: Sessions) -> Void
  _ = Actor.stop(sessions.registry, CALL_MS)
  Extensions.stop_observers(sessions.options.observers)
  for holder in option_list(sessions.options.logins)
    Logins.stop(holder)
  end
end

## The providers a session may use, each with the models of the config file, then the server's model for its own
## provider, then those of the catalog that call tools.
def providers(sessions: Sessions) -> Protocol.ProviderList
  options = Config.listed(sessions.options)
  infos = options.providers.keys.sort.map do |name| provider_info(options, name) end

  Protocol.ProviderList(provider: Config.now(sessions.options).provider, providers: infos)
end

## A new session: its id.
def create(sessions: Sessions, request: Protocol.NewSession) -> Result[String]
  created: Result[Result[String]] = Actor.call(sessions.registry.address, CALL_MS) do |reply|
    Msg.Create(request, reply)
  end

  id = try try created
  for name in option_list(request.profile)
    address = try find(sessions, id)
    found = try Profiles.find(profiles_of(sessions.options, (try SessionActor.snapshot(address)).cwd), name)
    if not found.model.empty? or not found.thinking.empty?
      # A model or provider of the request wins over the profile's.
      change = Protocol.UpdateSession(profile: some(name), provider: request.provider, model: request.model)
      try SessionActor.update(address, change)
    end
  end

  ok(id)
end

## The slash commands of a session: the user's and a trusted project's, and those that do not load.
def commands(sessions: Sessions, id: String) -> Result[Protocol.CommandList]
  place = place_of(sessions.options, (try snapshot(sessions, id)).cwd)
  loaded = Commands.load(Commands.user_folder(sessions.options.env), place.root, place.trusted)
  skills = Skills.discover(place.root, place.home, place.trusted, place.docs).skills.map { |s| s.name }
  notes = loaded.warnings + Commands.clashes(loaded, skills)
  listed = loaded.commands.map do |c|
    warnings = notes.select { |n| n.name == c.name }.map { |n| n.text }
    Protocol.CommandInfo(name: c.name, source: c.source, description: c.description, warnings: warnings)
  end

  broken = loaded.broken.keys.map { |name|
    Protocol.CommandInfo(name: name, source: "", warnings: [loaded.broken[name]])
  }

  ok(Protocol.CommandList(commands: (listed + broken).sort_by { |c| c.name }))
end

## The profiles a session may take: the built-in ones, the user's and a trusted project's, and those that do not load.
def profiles(sessions: Sessions, id: String) -> Result[Protocol.ProfileList]
  loaded = profiles_of(sessions.options, (try snapshot(sessions, id)).cwd)
  shown = loaded.profiles.map do |p|
    warnings = Profiles.warnings_of(loaded, p, Profiles.known_tools())
    Protocol.Profile(name: p.name, source: p.source, description: p.description, warnings: warnings)
  end

  broken = loaded.broken.keys.map { |name| Protocol.Profile(name: name, source: "", warnings: [loaded.broken[name]]) }
  ok(Protocol.ProfileList(profiles: (shown + broken).sort_by { |p| p.name }))
end

## The sessions, the last changed first.
def list(sessions: Sessions) -> Result[List[Protocol.SessionSummary]]
  registry = sessions.registry.address
  read = (try entries(sessions)).map { |entry| cached(entry) }
  _ = Actor.cast(registry, Msg.Listed(read), CALL_MS)
  ok(read.map { |found| summary_now(found) }.sort_by { |s| -s.updated_s })
end

def activity(sessions: Sessions) -> Result[Activity]
  all = try entries(sessions)
  running = 0
  busy = 0
  for session in loaded(all)
    case SessionActor.load(session)
      ok(load) if load.running ->
        running = running + 1
        if not load.asking
          busy = busy + 1
        end

      _ -> nil
    end
  end

  ok(Activity(sessions: all.size, running: running, busy: busy))
end

## Stops the running turn or shell command of every session: how many ran.
def cancel_turns(sessions: Sessions) -> Result[Int]
  stopped = 0
  for session in loaded(try entries(sessions))
    if SessionActor.stop(session, none) == ok(true)
      stopped = stopped + 1
    end
  end

  ok(stopped)
end

## Reads the config file, the MCP servers, the skills and the project instructions again. The sessions that run read
## their system prompt and approval again for their next turn (a turn that runs keeps what it started with), the others
## when they load. A config file that does not read stays as it was, said in the answer. One reload runs at a time.
def reload(sessions: Sessions) -> Result[Protocol.Reloaded]
  token = sessions.reloading.recv(RELOAD_WAIT_MS)
  return error("another reload is running") if not token.ok?

  done = reloaded(sessions)
  _ = sessions.reloading.send(true, 0)
  done
end

## Deletes a session and its file, refused while a turn runs.
def delete(sessions: Sessions, id: String) -> Result[Void]
  deleted: Result[Result[Void]] = Actor.call(sessions.registry.address, CALL_MS) do |reply| Msg.Delete(id, reply) end
  inner = try deleted
  inner
end

def snapshot(sessions: Sessions, id: String) -> Result[Protocol.Session]
  SessionActor.snapshot(try find(sessions, id))
end

## The events of a session from after `last` (from its last event when none).
def subscribe(sessions: Sessions, id: String, last: Optional[Int]) -> Result[Channel[Bytes]]
  SessionActor.subscribe(try find(sessions, id), last)
end

def send(sessions: Sessions, id: String, text: String) -> Result[Protocol.MessageAccepted]
  SessionActor.send(try find(sessions, id), text)
end

def update(sessions: Sessions, id: String, change: Protocol.UpdateSession) -> Result[Void]
  SessionActor.update(try find(sessions, id), change)
end

def compact(sessions: Sessions, id: String) -> Result[Bool] = SessionActor.compact_now(try find(sessions, id))

## Stops the running turn or shell command of a session; with `turn_id`, only that turn while it runs.
def stop_turn(sessions: Sessions, id: String, turn_id: Optional[String]) -> Result[Bool]
  SessionActor.stop(try find(sessions, id), turn_id)
end

## The files of the session's folder that its rules do not hide, read in the caller's task.
def files(sessions: Sessions, id: String) -> Result[Protocol.FileList]
  place = try SessionActor.place(try find(sessions, id))
  now = Config.applied(sessions.options)
  ok(Folder.listed(place.root, place.hidden, now.files_command, now.env))
end

def answer(sessions: Sessions, id: String, approval_id: String, decision: Protocol.Decision) -> Result[Void]
  SessionActor.answer(try find(sessions, id), approval_id, decision)
end

def shell(sessions: Sessions, id: String, request: Protocol.RunShell) -> Result[Protocol.ShellAccepted]
  SessionActor.shell(try find(sessions, id), request)
end

def tree(sessions: Sessions, id: String) -> Result[Protocol.SessionTree] = SessionActor.tree(try find(sessions, id))

def exported(sessions: Sessions, id: String) -> Result[Protocol.SessionExport]
  SessionActor.exported(try find(sessions, id))
end

def branch(sessions: Sessions, id: String, entry: Int) -> Result[Protocol.Branched]
  SessionActor.branch(try find(sessions, id), entry)
end

## A new session with the history of session `id` up to `entry` of its tree, all of it when none. It keeps the
## session's folder, system prompt, model API, model, thinking level and confinement of the file tools.
def fork(sessions: Sessions, id: String, entry: Optional[Int]) -> Result[Protocol.Branched]
  address = try find(sessions, id)
  registry = sessions.registry.address
  entries: Result[List[Entry]] = Actor.call(registry, CALL_MS) do |reply| Msg.List(reply) end
  listed = try entries
  source = try listed.find { |e| e.summary.id == id }
  header = source.header.with(id: new_id(listed.size), created_ms: Time.now_ms)
  copied = try SessionActor.copy(address, entry, SessionActor.Copying(header: header, dir: sessions.dir))
  adopted: Result[Bool] = Actor.call(registry, CALL_MS) do |reply| Msg.Adopt(header, copied.file, reply) end
  if not adopted.ok?
    _ = Store.remove(copied.file)
  end

  _ = try adopted
  # The confinement of the file tools is a setting of the session that the file does not keep.
  confined = (try SessionActor.snapshot(address)).confine
  if confined != sessions.options.confine_files
    case update(sessions, header.id, Protocol.UpdateSession(confine: some(confined)))
      ok(_) -> nil
      error(e) ->
        # A fork that is not as confined as its source must not stay.
        _ = delete(sessions, header.id)
        return error(e.message, kind: e.kind)
    end
  end

  ok(Protocol.Branched(id: header.id, text: copied.text))
end

private

TITLE_CHARS = 200

struct Entry
  summary: Protocol.SessionSummary
  header: Store.Header
  file: Store.Ref
  ## None until the session is first used.
  session: Optional[Actor.Ref[SessionActor.State, SessionActor.Msg]]
  ## The requests that wait while the session loads; a load runs while it is not empty.
  waiting: List[Channel[Result[Address[SessionActor.Msg]]]] = []
  listed: Optional[Cached] = none
end

# A session's provider and model API by name.
struct Chosen
  provider: String
  api: String
end

# The context of a session and its approval.
struct Opened
  context: Tools.Context
  approver: Optional[Extensions.Approver]
end

## What the task that loads a session read from its file.
struct Loaded
  saved: Store.Saved
  opened: Opened
end

struct Listed
  file: Store.Ref
  header: Store.Header
end

struct Registry
  options: Config.Options
  store: Store.Port
  sessions: List[Entry] = []
  address: Address[Msg]
end

## A load to run in its own task; it tells `registry` what it read.
struct Load
  options: Config.Options
  entry: Entry
  registry: Address[Msg]
end

## What `Find` gives: the session, or the channel that gets it once it loads.
enum Found
  Ready(Address[SessionActor.Msg])
  Loading(Channel[Result[Address[SessionActor.Msg]]])
end

enum Msg
  Create(Protocol.NewSession, Channel[Result[String]])
  Find(String, Channel[Result[Found]])
  Delete(String, Channel[Result[Void]])
  List(Channel[List[Entry]])
  Load(String, Result[Loaded])
  ## What a list read of session files, kept for the next list.
  Listed(List[Cached])
  ## A session file written outside the registry (a fork), to list.
  Adopt(Store.Header, Store.Ref, Channel[Bool])
end

## What a list read of one session file, valid while its size and time of change stay.
struct Cached
  id: String
  summary: Protocol.SessionSummary
  size: Int
  modified_s: Int
  listing: Store.Listing
end

def terminate(registry: Registry) -> Void
  for entry in registry.sessions
    for session in option_list(entry.session)
      _ = Actor.stop(session, CALL_MS)
      Extensions.publish(registry.options.observers, ended_seen(entry, "stopping"))
    end
  end
end

# `session_started` and `session_ended` reach only the observers: no session stream exists before or after them.
def lifecycle(id: String, root: String, name: String, data: Map[String, JSON.Value]) -> Extensions.Seen
  Extensions.Seen(session: id, root: root, name: name, data: JSON.object(data.put("id", JSON.from(id))))
end

def ended_seen(entry: Entry, reason: String) -> Extensions.Seen
  lifecycle(entry.summary.id, entry.summary.cwd, "session_ended", {"reason": JSON.from(reason)})
end

def handle(registry: Registry, msg: Msg) -> Actor.Step[Registry]
  case msg
    Msg.Create(request, reply) ->
      case open_session(registry, request)
        ok(entry) ->
          Actor.reply(reply, ok(entry.summary.id))
          Actor.continue(registry.with(sessions: registry.sessions.push(entry)))
        error(e) ->
          Actor.reply(reply, error(e))
          Actor.continue(registry)
      end

    Msg.Find(id, reply) ->
      found = registry.sessions.select { |entry| entry.summary.id == id }
      if found.empty?
        Actor.reply(reply, error("no session #{id}", kind: Protocol.KIND_SESSION_NOT_FOUND))
        return Actor.continue(registry)
      end

      listed = found[0]
      for session in option_list(listed.session)
        Actor.reply(reply, ok(Found.Ready(session.address)))
        return Actor.continue(registry)
      end

      if listed.waiting.size >= MAX_WAITING
        message = "session #{id} is loading for too many requests"
        Actor.reply(reply, error(message, kind: Protocol.KIND_SESSION_UNAVAILABLE))
        return Actor.continue(registry)
      end

      if listed.waiting.empty?
        _ = Task.spawn(&load, Load(options: registry.options, entry: listed, registry: registry.address))
      end

      loaded: Channel[Result[Address[SessionActor.Msg]]] = Channel.new(1)
      Actor.reply(reply, ok(Found.Loading(loaded)))
      waiting = listed.with(waiting: listed.waiting.push(loaded))
      Actor.continue(registry.with(sessions: registry.sessions.map { |e| replaced(e, waiting) }))

    Msg.Load(id, read) -> Actor.continue(registered(registry, id, read))

    Msg.Delete(id, reply) ->
      found = registry.sessions.select { |entry| entry.summary.id == id }
      if found.empty?
        Actor.reply(reply, error("no session #{id}", kind: Protocol.KIND_SESSION_NOT_FOUND))
        return Actor.continue(registry)
      end

      case ended(found[0])
        ok(entry) ->
          removed = Store.remove(entry.file)

          Actor.reply(reply, removed)
          sessions = registry.sessions.map { |e| replaced(e, entry) }
          if removed.ok?
            # What a load still running reads finds no entry, and is dropped.
            for waiting in entry.waiting
              Actor.reply(waiting, error("no session #{id}", kind: Protocol.KIND_SESSION_NOT_FOUND))
            end

            sessions = sessions.select { |e| e.summary.id != id }
            Extensions.publish(registry.options.observers, ended_seen(entry, "deleted"))
          end

          Actor.continue(registry.with(sessions: sessions))
        error(e) ->
          Actor.reply(reply, error(e))
          Actor.continue(registry)
      end

    Msg.Listed(read) ->
      sessions = registry.sessions.map { |entry| with_listed(entry, read) }

      Actor.continue(registry.with(sessions: sessions))
    Msg.List(reply) ->
      Actor.reply(reply, registry.sessions)
      Actor.continue(registry)
    Msg.Adopt(header, file, reply) ->
      Actor.reply(reply, true)
      adopted = Entry(summary: summary_of(registry.options, header), header: header, file: file, session: none)
      Actor.continue(registry.with(sessions: registry.sessions.push(adopted)))
  end
end

def with_listed(entry: Entry, read: List[Cached]) -> Entry
  fresh = read.select { |c| c.id == entry.summary.id }
  return entry if fresh.empty?

  entry.with(listed: some(fresh[0]))
end

# The listing of a session file, read again only when its size or time of change moved. A file that cannot be read
# keeps what its header said.
def cached(entry: Entry) -> Cached
  size = 0
  modified = 0
  case Store.changed(entry.file)
    ok(info) ->
      size = info.size
      modified = info.modified
    error(_) -> nil
  end

  for old in option_list(entry.listed)
    return old.with(summary: entry.summary) if old.size == size and old.modified_s == modified
  end

  listing = Store.listing(entry.file).unwrap_or(Store.Listing())
  Cached(id: entry.summary.id, summary: entry.summary, size: size, modified_s: modified, listing: listing)
end

# A session with its model now (a `PATCH` changes it after the header), when it last changed and its first message
# without control or bidi characters.
def summary_now(found: Cached) -> Protocol.SessionSummary
  title = found.listing.title
  cut = title.slice(0, [title.length, TITLE_CHARS].min.unwrap!)
  found.summary.with(
    model: found.listing.model.unwrap_or(found.summary.model),
    provider: found.listing.provider.map { |p| some(p) }.unwrap_or(found.summary.provider),
    api: found.listing.api.unwrap_or(found.summary.api),
    updated_s: found.modified_s,
    title: cut.split("").map { |c| Folder.printable(c) }.join(""),
    empty: found.listing.empty,
  )
end

def open_session(registry: Registry, request: Protocol.NewSession) -> Result[Entry]
  options = Config.now(registry.options)
  ctx = case Tools.context(
    request.cwd,
    options.env,
    options.confine_files,
    options.tools,
    late_of(options),
    options.diff,
    wrap_of(options),
  )
    ok(ctx) -> ok(ctx)
    error(e) -> error("cwd: #{e.message}", kind: Protocol.KIND_INVALID)
  end

  context = try ctx
  approver = try approver_of(options, context.root)
  profile = request.profile.unwrap_or(Profiles.DEFAULT)
  case Profiles.find(profiles_of(options, context.root), profile)
    error(e) -> return error(e.message, kind: Protocol.KIND_INVALID)
    ok(_) -> nil
  end

  provider = request.provider.unwrap_or(provider_of_api(options, request.api))
  if not options.providers.has_key?(provider)
    names = options.providers.keys.join(", ")
    return error("unknown provider #{provider.inspect}: one of #{names}", kind: Protocol.KIND_INVALID)
  end

  apis = options.providers[provider].apis
  api = request.api.unwrap_or(options.providers[provider].api)
  if not apis.has_key?(api)
    return error("unknown api #{api.inspect}: one of #{apis.keys.join(", ")}", kind: Protocol.KIND_INVALID)
  end

  model = ""
  case request.model
    some(named) -> model = named
    none -> model = default_model(options, provider, api)
  end

  header = Store.Header(
    id: new_id(registry.sessions.size),
    cwd: context.root,
    model: model,
    created_ms: Time.now_ms,
    system: some(new_system(options, context.root)),
    api: some(api),
    provider: some(provider),
    profile: some(profile),
  )

  file = try Store.create(registry.store, folder(options), header)
  entry(options, header, opened(context, approver), file, none)
end

def new_id(count: Int) -> String = "s#{count + 1}-#{OpenSSL.Random.hex(4)}"

# The entry with its session ended, refused while a turn runs; it loads again on its next use.
def ended(listed: Entry) -> Result[Entry]
  for session in option_list(listed.session)
    try SessionActor.end_session(session.address)
    _ = Task.await(session.task, CALL_MS)
  end

  ok(listed.with(session: none))
end

def replaced(entry: Entry, by: Entry) -> Entry
  return by if entry.summary.id == by.summary.id

  entry
end

# The load always reports, even when it crashes, so the requests that wait for it get an answer.
def load(job: Load) -> Void
  reading = Task.spawn do read(job.options, job.entry) end
  loaded = Msg.Load(job.entry.summary.id, Task.await(reading))
  while true
    case Actor.cast(job.registry, loaded, CALL_MS)
      error(e) if e.kind == "channel.timeout" -> next
      _ -> break
    end
  end

  for hook in option_list(job.options.after_load)
    hook.call(job.entry.summary.id)
  end
end

def read(options: Config.Options, listed: Entry) -> Result[Loaded]
  for hook in option_list(options.before_load)
    hook.call(listed.summary.id)
  end

  saved = try Store.load(listed.file)
  if saved.skipped > 0
    Logger.warning("session #{saved.header.id}: #{saved.skipped} records skipped")
  end

  context = try Tools.context(
    saved.header.cwd,
    options.env,
    options.confine_files,
    options.tools,
    late_of(options),
    options.diff,
    wrap_of(options),
  )

  ok(Loaded(saved: saved, opened: opened(context, try approver_of(options, context.root))))
end

# Starts the session that a load read, and answers the requests that waited for it. A load of a session deleted since
# it began is dropped.
def registered(registry: Registry, id: String, read: Result[Loaded]) -> Registry
  found = registry.sessions.select { |entry| entry.summary.id == id and not entry.waiting.empty? }
  return registry if found.empty?

  listed = found[0]
  case started(registry.options, listed, read)
    ok(entry) ->
      for waiting in listed.waiting
        Actor.reply(waiting, entry.session.map { |session| session.address }.to_result("not started"))
      end

      registry.with(sessions: registry.sessions.map { |e| replaced(e, entry) })
    error(e) ->
      Logger.warning("session #{id} cannot be loaded now: #{e.message}")
      message = "session #{id} cannot be loaded now"
      if e.kind == KIND_UNKNOWN_API
        message = "#{message}: #{e.message}"
      end

      for waiting in listed.waiting
        Actor.reply(waiting, error(message, kind: Protocol.KIND_SESSION_UNAVAILABLE))
      end

      registry.with(sessions: registry.sessions.map { |other| replaced(other, listed.with(waiting: [])) })
  end
end

def started(options: Config.Options, listed: Entry, read: Result[Loaded]) -> Result[Entry]
  loaded = try read
  if loaded.saved.open_end
    try Store.reopen(listed.file)
  end

  entry(Config.now(options), loaded.saved.header, loaded.opened, listed.file, some(loaded.saved))
end

def entry(
  options: Config.Options,
  header: Store.Header,
  opened: Opened,
  file: Store.Ref,
  saved: Optional[Store.Saved],
) -> Result[Entry]
  chosen = chosen_of(options, header)
  api = chosen.api
  provider = chosen.provider
  profile = header.profile.unwrap_or(Profiles.DEFAULT)
  for settings in option_list(saved)
    api = settings.api.unwrap_or(api)
    provider = settings.provider.unwrap_or(provider)
    profile = settings.profile.unwrap_or(profile)
  end

  endpoint = try loaded_endpoint(options, provider, api)
  context = opened.context
  system = header.system.unwrap_or(system_of(options, context.root))
  builtins = builtins_of(options, context.root, system)
  for warning in (builtins.flat_map { |b| b.warnings })
    Logger.warning(warning)
  end

  base = SessionActor.Setup(
    id: header.id,
    cwd: context.root,
    model: header.model,
    provider: endpoint.provider,
    system: system,
    base_system: system,
    ctx: context.with(
      read_roots: Extensions.read_roots(builtins),
      before: before_of(options, header.id),
      session: some(header.id),
    ),
    builtins: builtins,
    keep_events: options.keep_events,
    approval_timeout_ms: options.approval_timeout_ms,
    file: file,
    window: options.context_window.unwrap_or(0),
    code_mode: options.code_mode,
    max_tokens: options.max_tokens,
    catalog: options.catalog,
    take_ms: options.take_ms,
    catalog_wait_ms: options.catalog_wait_ms,
    approver: opened.approver,
    registry: options.registry.map { |served| served.registry },
    observers: options.observers,
    origin: "#{chosen.provider}/#{chosen.api}",
    endpoint: some(->(name: String, now: String) { switched_endpoint(Config.now(options), name, now) }),
    profiles: some(-> { profiles_of(options, context.root) }),
    reopen: some(-> { reopened(options, context.root) }),
    skills: skill_names(options, context.root, system),
  )

  setup = SessionActor.switched(base, endpoint).with(model: header.model, refused: refusal(options, provider))
  setup = SessionActor.applied(setup, profiles_of(options, context.root), profile)
  # Before the actor starts: a restore can end a cut turn with events of its own.
  started = lifecycle(header.id, context.root, "session_started", {"new": JSON.from(saved.none?)})
  Extensions.publish(options.observers, started)

  ok(
    Entry(
      summary: summary_of(options, header),
      header: header,
      file: file,
      session: some(SessionActor.start(setup, saved)),
    ),
  )
end

# A session on another provider or API than the server's takes that API's model, when it names one; else the server's
# model on the server's provider, and `default` on another.
def default_model(options: Config.Options, provider: String, api: String) -> String
  if options.model_unset and provider == options.provider
    # The provider of the last choice has no model of its own: the first model it lists, which the clients show too,
    # so a catalog that still loads is waited for.
    for catalog in option_list(options.catalog)
      _ = Catalog.wait(catalog, options.catalog_wait_ms)
    end

    listed = provider_info(options, provider).models.select { |m| m != Config.DEFAULT_MODEL }
    return listed[0] if not listed.empty?
  end

  own = options.providers[options.provider]
  return options.model if provider == options.provider and api == own.api

  model = options.providers[provider].apis[api].model
  return model if model != ""
  return Config.DEFAULT_MODEL if provider != options.provider or own.apis[own.api].model != ""

  options.model
end

# The provider and API of a session's header. A file made before providers names none: its API's built-in provider
# (`local`, or `anthropic`), never the server's default, which may be a remote one; one made before the API choice
# names neither and takes the API of the server's built-in provider.
def chosen_of(options: Config.Options, header: Store.Header) -> Chosen
  for provider in option_list(header.provider)
    own = options.providers.get(provider).map { |p| p.api }.unwrap_or("")
    return Chosen(provider: provider, api: header.api.unwrap_or(own))
  end

  for api in option_list(header.api)
    return Chosen(provider: builtin_of(api), api: api)
  end

  builtin = Providers.LOCAL
  if options.provider == Providers.ANTHROPIC
    builtin = Providers.ANTHROPIC
  end

  Chosen(provider: builtin, api: options.providers.get(builtin).map { |p| p.api }.unwrap_or(""))
end

def builtin_of(api: String) -> String
  return Providers.ANTHROPIC if api == "anthropic"

  Providers.LOCAL
end

# The provider of a session that names none: the server's, unless it does not speak `api`; then the first built-in that
# does (`--api anthropic` on a server of a local model).
def provider_of_api(options: Config.Options, api: Optional[String]) -> String
  for name in [options.provider, Providers.LOCAL, Providers.ANTHROPIC]
    found = (
      options.providers.has_key?(name) and
      api.map { |a| options.providers[name].apis.has_key?(a) } != some(false)
    )

    return name if found
  end

  options.provider
end

# The models of a provider: those of the config file, the server's on its own, and those of its catalog entry that call
# tools. A local server serves what it loaded, so `local` lists the catalog only for `FINN_MODELS_PROVIDER`.
def provider_info(options: Config.Options, name: String) -> Protocol.ProviderInfo
  found = options.providers[name]
  models = found.models
  if name == options.provider
    models = models.push(options.model)
  end

  listed = catalog_of(options, found)
  if name == Providers.LOCAL
    listed = options.models_provider
  end

  for catalog in option_list(options.catalog)
    if not listed.empty?
      models = models + Catalog.models(catalog, listed)
    end
  end

  Protocol.ProviderInfo(name: name, api: found.api, models: models.uniq)
end

# The models.dev id of a provider.
def catalog_of(options: Config.Options, found: Config.Provider) -> String
  return found.catalog if not found.catalog.empty?

  catalog_provider(options.models_provider, found.apis[found.api].provider)
end

# A session on a provider the server no longer offers (its key is unset) loads with it, on the server's endpoint, and
# refuses a turn until a `PATCH` picks another provider.
def loaded_endpoint(options: Config.Options, provider: String, api: String) -> Result[SessionActor.Endpoint]
  return endpoint_of(options, provider, api) if options.providers.has_key?(provider)

  fallback = try endpoint_of(options, options.provider, options.providers[options.provider].api)
  ok(fallback.with(name: provider, api: api))
end

def refusal(options: Config.Options, provider: String) -> String
  return "" if options.providers.has_key?(provider)

  key = options.key_envs.get(provider).unwrap_or("")
  return "provider #{provider} is not offered" if key.empty?

  "provider #{provider} is not offered (is #{key} set?)"
end

# What a session on `provider` and `api` takes from them; an unknown one is an API error.
def endpoint_of(options: Config.Options, provider: String, api: String) -> Result[SessionActor.Endpoint]
  return error("unknown provider #{provider}", kind: KIND_UNKNOWN_API) if not options.providers.has_key?(provider)

  found = options.providers[provider]
  return error("unknown API #{api}", kind: KIND_UNKNOWN_API) if not found.apis.has_key?(api)

  model_api = found.apis[api]
  compact = ""
  if provider == options.provider and api == found.api
    compact = options.compact_model
  end

  ok(
    SessionActor.Endpoint(
      name: provider,
      api: api,
      model: default_model(options, provider, api),
      provider: model_api.provider,
      extra: model_api.extra,
      cache: model_api.cache,
      headers: model_api.headers,
      refresh: refresh_of(model_api),
      props_url: if_local(model_api, options.props_url),
      api_key: if_local(model_api, options.api_key),
      compact_model: compact,
      catalog_provider: catalog_of(options, found),
    ),
  )
end

# A `PATCH` to `provider` keeps the model API in use when the provider speaks it, else takes the provider's own.
def switched_endpoint(options: Config.Options, provider: String, now: String) -> Result[SessionActor.Endpoint]
  if not options.providers.has_key?(provider)
    return error("unknown provider #{provider}: one of #{options.providers.keys.join(", ")}")
  end

  found = options.providers[provider]
  api = found.api
  if found.apis.has_key?(now)
    api = now
  end

  endpoint_of(options, provider, api)
end

# A session's own refresh when the API makes one per session, else the API's.
def refresh_of(api: Config.ModelApi) -> Optional[Fn[Result[LLM.Provider]]]
  for make in option_list(api.renewer)
    return some(make.call())
  end

  api.refresh
end

def if_local(api: Config.ModelApi, url: String) -> String
  return "" if not api.local

  url
end

def summary_of(options: Config.Options, header: Store.Header) -> Protocol.SessionSummary
  chosen = chosen_of(options, header)
  Protocol.SessionSummary(
    id: header.id,
    cwd: header.cwd,
    model: header.model,
    api: chosen.api,
    provider: some(chosen.provider),
  )
end

# In the order they were made, not loaded yet. A file whose first line is not a session is left out, with a warning.
def load_sessions(options: Config.Options, store: Store.Port) -> List[Entry]
  files: List[Store.Ref] = []
  case Store.all(store, folder(options))
    ok(found) -> files = found
    error(e) -> Logger.warning("sessions not listed: #{e.message}")
  end

  listed: List[Listed] = []
  for file in files
    case Store.header(file)
      ok(header) -> listed = listed.push(Listed(file: file, header: header))
      error(e) -> Logger.warning("session #{file.path.split("/").last} not listed: #{e.message}")
    end
  end

  sorted = listed.sort_by { |one| one.header.id }.sort_by { |one| one.header.created_ms }
  sorted.map { |one|
    Entry(summary: summary_of(options, one.header), header: one.header, file: one.file, session: none)
  }
end

# `AGENTS.md` goes to the model only when it is a regular file inside the folder: a link out of it could be any file.
def system_of(options: Config.Options, root: String) -> String
  system = Prompt.system_prompt(root)
  options.registry.map { |served| Extensions.prompt(served.registry, system) }.unwrap_or(system)
end

def before_of(options: Config.Options, session: String) -> Optional[Spec.Before]
  for served in option_list(options.registry)
    return Extensions.before(served.registry, session)
  end

  none
end

def wrap_of(options: Config.Options) -> Optional[Fn[String, Spec.Run, Spec.Run]]
  for served in option_list(options.registry)
    return Extensions.wrap(served.registry)
  end

  none
end

# The profiles of a session in `root`: the built-in ones, the user's, and a trusted project's.
def profiles_of(options: Config.Options, root: String) -> Profiles.Loaded
  Profiles.load(Profiles.user_folder(options.env), root, trusted?(options, root))
end

# The problems of the user's profiles, once at the start: the files skipped and those that do not load.
def warn_profiles(options: Config.Options) -> Void
  loaded = Profiles.load(Profiles.user_folder(options.env), "", false)
  for warning in loaded.warnings
    Logger.warning(warning.text)
  end

  for name in loaded.broken.keys.sort
    Logger.warning(loaded.broken[name])
  end
end

# The system prompt of a new session in `root`, with what the extensions add.
def new_system(options: Config.Options, root: String) -> String
  system = system_of(options, root)
  options.registry.map { |r| Extensions.new_system(r, place_of(options, root), system) }.unwrap_or(system)
end

# The names of the skills a session with `system` has.
def skill_names(options: Config.Options, root: String, system: String) -> List[String]
  place = place_of(options, root)
  found = Skills.discover(place.root, place.home, place.trusted, place.docs)
  Skills.restrict(found.skills, system).map { |skill| skill.name }
end

# What a reload gives the session in `root`: the system prompt of a new session there (`AGENTS.md` and the skills read
# again) with its extensions and its approval, under the options of now.
def reopened(options: Config.Options, root: String) -> Result[SessionActor.Reopened]
  now = Config.now(options)
  system = new_system(now, root)
  approver = try approver_of(now, root)
  builtins = builtins_of(now, root, system)
  warnings = builtins.flat_map { |b| b.warnings }

  ok(
    SessionActor.Reopened(
      system: system,
      builtins: builtins,
      approver: approver,
      skills: skill_names(now, root, system),
      warnings: warnings,
    ),
  )
end

def builtins_of(options: Config.Options, root: String, system: String) -> List[Extensions.Opened]
  options.registry.map { |r| Extensions.open(r, place_of(options, root), system) }.unwrap_or([])
end

def late_of(options: Config.Options) -> Optional[Fn[List[Tools.Tool]]]
  for registry in option_list(options.registry)
    return Extensions.late_tools(registry)
  end

  none
end

def place_of(options: Config.Options, root: String) -> Extensions.Place
  Extensions.Place(root: root, home: options.home, trusted: trusted?(options, root), docs: options.docs)
end

# A session folder under a folder of `FINN_TRUSTED_DIRS`, whose own skills and all of whose rules count (elsewhere
# only the project's deny rules).
def trusted?(options: Config.Options, root: String) -> Bool
  options.trusted.any? { |dir| Sandbox.inside?(Path.real(dir).unwrap_or(dir), root) }
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end

# The approval of a session in `root`, when the server has one; one that cannot open (a broken project file) is an
# invalid request.
def approver_of(options: Config.Options, root: String) -> Result[Optional[Extensions.Approver]]
  for served in option_list(options.registry)
    case Extensions.approver(served, place_of(options, root))
      ok(approver) -> return ok(approver)
      error(e) -> return error(e.message, kind: Protocol.KIND_INVALID)
    end
  end

  ok(none)
end

# A deny rule of `read_file` hides its files from `glob` and `grep` too.
def opened(context: Tools.Context, approver: Optional[Extensions.Approver]) -> Opened
  case approver
    some(a) -> Opened(context: context.with(hidden: some(a.hidden)), approver: approver)
    none -> Opened(context: context, approver: none)
  end
end

def catalog_provider(given: String, provider: LLM.Provider) -> String
  return given if not given.empty?
  return "anthropic" if provider.name == "anthropic"

  "openai"
end

def entries(sessions: Sessions) -> Result[List[Entry]]
  Actor.call(sessions.registry.address, CALL_MS) do |reply| Msg.List(reply) end
end

# The addresses of the sessions that are loaded.
def loaded(all: List[Entry]) -> List[Address[SessionActor.Msg]]
  all.flat_map { |entry| option_list(entry.session).map { |session| session.address } }
end

def find(sessions: Sessions, id: String) -> Result[Address[SessionActor.Msg]]
  found: Result[Result[Found]] = Actor.call(sessions.registry.address, CALL_MS) do |reply| Msg.Find(id, reply) end
  case try try found
    Found.Ready(address) -> ok(address)
    Found.Loading(loaded) ->
      case loaded.recv(LOAD_MS)
        ok(address) -> address
        error(_) -> error("session #{id} is still loading", kind: Protocol.KIND_SESSION_UNAVAILABLE)
      end
  end
end

def reloaded(sessions: Sessions) -> Result[Protocol.Reloaded]
  config = Config.reload(sessions.options)
  extensions: List[String] = []
  warnings: List[String] = []
  for step in sessions.options.reloads
    case step.call()
      ok(said) if said != "" -> extensions = extensions.push(said)
      ok(_) -> nil
      error(e) -> warnings = warnings.push("extensions: #{e.message}")
    end
  end

  added: List[String] = []
  removed: List[String] = []
  running = loaded(try entries(sessions))
  for address in running
    case SessionActor.reload(address)
      ok(found) ->
        added = (added + found.added).uniq
        removed = (removed + found.removed).uniq
        warnings = (warnings + found.warnings).uniq
      error(e) -> warnings = (warnings + ["session: #{e.message}"]).uniq
    end
  end

  if config.config.start_with?("kept")
    warnings = warnings.push("config: #{config.config}")
  end

  for warning in warnings
    Logger.warning("reload: #{warning}")
  end

  ok(
    Protocol.Reloaded(
      skills_added: added.sort,
      skills_removed: removed.sort,
      config: config.config,
      extensions: extensions,
      sessions: running.size,
      warnings: warnings,
      rules: config.rules,
      approvals: config.asking,
    ),
  )
end
