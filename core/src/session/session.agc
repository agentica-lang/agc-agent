## The sessions of the server: a registry actor that lists the session files and creates, finds, loads and deletes
## sessions, and the calls on one session by its id (`actor.agc` is the session itself).
##
## The sessions live in `sessions/` of the data folder (0700), one file each (`Store`). At start the registry reads only
## the first line of each file, for the list; a session is loaded from its file on its first request, in a task of its
## own, so a big file never holds up the requests of other sessions.

import Actor from "std/actor"
import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import Extension from "../approval/extension"
import Config from "../config/config"
import Skills from "../ext/skills"
import Sandbox from "../tools/sandbox"
import Tools from "../tools/tools"
import SessionActor from "actor"
import Prompt from "prompt"
import Store from "store"

SESSIONS_DIR = "sessions"
CALL_MS = 5000
## A request for a session that is not loaded yet waits for its load.
LOAD_MS = 60_000
## A session whose file names a model API this server does not have; its 503 says so.
KIND_UNKNOWN_API = "core.unknown_api"
## The requests that may wait for one load; past them a request answers 503.
MAX_WAITING = 64

## The registry, which owns the sessions.
struct Sessions
  registry: Actor.Ref[Registry, Msg]
  dir: String
end

## The folder of the session files.
def folder(options: Config.Options) -> String = "#{options.data_dir}/#{SESSIONS_DIR}"

## Starts the registry, which lists the session files of `options`.
def start(options: Config.Options) -> Sessions
  init = -> {
    inbox: Channel[Msg] = Actor.inbox()
    Registry(options: options, sessions: load_sessions(options), address: inbox.address)
  }

  registry = Actor.start(Actor.Behaviour(init: init, handle: &handle, terminate: some(&terminate)))
  Sessions(registry: registry, dir: folder(options))
end

## Stops the registry and the sessions it runs.
def stop(sessions: Sessions) -> Void
  _ = Actor.stop(sessions.registry, CALL_MS)
end

## A new session: its id.
def create(sessions: Sessions, request: Protocol.NewSession) -> Result[String]
  created: Result[Result[String]] = Actor.call(sessions.registry.address, CALL_MS) do |reply|
    Msg.Create(request, reply)
  end

  inner = try created
  inner
end

## The sessions, the last changed first.
def list(sessions: Sessions) -> Result[List[Protocol.SessionSummary]]
  registry = sessions.registry.address
  entries: Result[List[Entry]] = Actor.call(registry, CALL_MS) do |reply| Msg.List(reply) end
  read = (try entries).map { |entry| cached(entry) }
  _ = Actor.cast(registry, Msg.Listed(read), CALL_MS)
  ok(read.map { |found| summary_now(found) }.sort_by { |s| -s.updated_s })
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

## Stops the running turn of a session.
def stop_turn(sessions: Sessions, id: String) -> Result[Bool] = SessionActor.stop(try find(sessions, id))

def answer(sessions: Sessions, id: String, approval_id: String, decision: Protocol.Decision) -> Result[Void]
  SessionActor.answer(try find(sessions, id), approval_id, decision)
end

def tree(sessions: Sessions, id: String) -> Result[Protocol.SessionTree] = SessionActor.tree(try find(sessions, id))

def branch(sessions: Sessions, id: String, entry: Int) -> Result[Protocol.Branched]
  SessionActor.branch(try find(sessions, id), entry)
end

## A new session with the history of session `id` up to `entry` of its tree, all of it when none. It keeps the
## session's folder, system prompt, model API, model and thinking level.
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
    _ = Path.remove(copied.file)
    _ = Path.remove(Store.settings_file(copied.file))
  end

  _ = try adopted
  ok(Protocol.Branched(id: header.id, text: copied.text))
end

private

TITLE_CHARS = 200

struct Entry
  summary: Protocol.SessionSummary
  header: Store.Header
  file: String
  ## None until the session is first used.
  session: Optional[Actor.Ref[SessionActor.State, SessionActor.Msg]]
  ## The requests that wait while the session loads; a load runs while it is not empty.
  waiting: List[Channel[Result[Address[SessionActor.Msg]]]] = []
  listed: Optional[Cached] = none
end

# The context of a session and its approval extension.
struct Opened
  context: Tools.Context
  approvals: Optional[Extension.Approvals]
end

## What the task that loads a session read from its file.
struct Loaded
  saved: Store.Saved
  opened: Opened
end

struct Listed
  file: String
  header: Store.Header
end

struct Registry
  options: Config.Options
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
  Adopt(Store.Header, String, Channel[Bool])
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
    end
  end
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
          removed = remove_file(entry.file)
          if removed.ok?
            _ = Path.remove(Store.settings_file(entry.file))
          end

          Actor.reply(reply, removed)
          sessions = registry.sessions.map { |e| replaced(e, entry) }
          if removed.ok?
            # What a load still running reads finds no entry, and is dropped.
            for waiting in entry.waiting
              Actor.reply(waiting, error("no session #{id}", kind: Protocol.KIND_SESSION_NOT_FOUND))
            end

            sessions = sessions.select { |e| e.summary.id != id }
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
  case File.stat(entry.file)
    ok(info) ->
      size = info.size_bytes
      modified = info.modified_seconds
    error(_) -> nil
  end

  for old in option_list(entry.listed)
    return old.with(summary: entry.summary) if old.size == size and old.modified_s == modified
  end

  listing = Store.listing(entry.file).unwrap_or(Store.Listing())
  Cached(id: entry.summary.id, summary: entry.summary, size: size, modified_s: modified, listing: listing)
end

# A session with its model now (a `PATCH` changes it after the header), when it last changed and its first message
# without control characters.
def summary_now(found: Cached) -> Protocol.SessionSummary
  title = found.listing.title
  cut = title.slice(0, [title.length, TITLE_CHARS].min.unwrap!)
  found.summary.with(
    model: found.listing.model.unwrap_or(found.summary.model),
    updated_s: found.modified_s,
    title: cut.split("").map { |c| printable(c) }.join(""),
  )
end

def printable(c: String) -> String
  code = c.code
  return " " if code < 0x20 or (code >= 0x7f and code < 0xa0)

  c
end

def open_session(registry: Registry, request: Protocol.NewSession) -> Result[Entry]
  options = registry.options
  ctx = case Tools.context(request.cwd, options.env, options.tools, options.late_tools)
    ok(ctx) -> ok(ctx)
    error(e) -> error("cwd: #{e.message}", kind: Protocol.KIND_INVALID)
  end

  context = try ctx
  approvals = try approvals_of(options, context.root)
  api = request.api.unwrap_or(options.api)
  if not options.apis.has_key?(api)
    return error("unknown api #{api.inspect}: one of #{options.apis.keys.join(", ")}", kind: Protocol.KIND_INVALID)
  end

  header = Store.Header(
    id: new_id(registry.sessions.size),
    cwd: context.root,
    model: request.model.unwrap_or(default_model(options, api)),
    created_ms: Time.now_ms,
    system: some(Prompt.with_catalog(Prompt.system_prompt(context.root), skills_of(options, context.root).skills)),
    api: some(api),
  )

  file = try Store.create(folder(options), header)
  entry(options, header, opened(context, approvals), file, none)
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

def remove_file(file: String) -> Result[Void]
  info = try File.lstat(file)
  return error("#{file}: not a regular file") if info.kind != "file"

  Path.remove(file)
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

  info = try File.lstat(listed.file)
  return error("not a regular file") if info.kind != "file"

  saved = try Store.load(listed.file)
  if saved.skipped > 0
    IO.warn("session #{saved.header.id}: #{saved.skipped} records skipped")
  end

  context = try Tools.context(saved.header.cwd, options.env, options.tools, options.late_tools)
  ok(Loaded(saved: saved, opened: opened(context, try approvals_of(options, context.root))))
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
      IO.warn("session #{id} cannot be loaded now: #{e.message}")
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

  entry(options, loaded.saved.header, loaded.opened, listed.file, some(loaded.saved))
end

def entry(
  options: Config.Options,
  header: Store.Header,
  opened: Opened,
  file: String,
  saved: Optional[Store.Saved],
) -> Result[Entry]
  name = header.api.unwrap_or(options.api)
  return error("unknown API #{name}", kind: KIND_UNKNOWN_API) if not options.apis.has_key?(name)

  api = options.apis[name]
  context = opened.context
  found = skills_of(options, context.root)
  for warning in found.warnings
    IO.warn("skills: #{warning}")
  end

  system = header.system.unwrap_or(Prompt.system_prompt(context.root))
  skills = Skills.restrict(found.skills, system)
  setup = SessionActor.Setup(
    id: header.id,
    cwd: context.root,
    model: header.model,
    provider: api.provider,
    system: system,
    ctx: context.with(read_roots: skills.map { |skill| skill.dir }),
    skills: skills,
    keep_events: options.keep_events,
    approval_timeout_ms: options.approval_timeout_ms,
    file: file,
    window: options.context_window.unwrap_or(0),
    compact_model: own(options, name, options.compact_model),
    props_url: if_local(api, options.props_url),
    api_key: if_local(api, options.api_key),
    extra: api.extra,
    cache: api.cache,
    refresh: api.refresh,
    code_mode: options.code_mode,
    catalog: options.catalog,
    catalog_provider: catalog_provider(options.models_provider, api.provider),
    take_ms: options.take_ms,
    catalog_wait_ms: options.catalog_wait_ms,
    approvals: opened.approvals,
  )

  ok(
    Entry(
      summary: summary_of(options, header),
      header: header,
      file: file,
      session: some(SessionActor.start(setup, saved)),
    ),
  )
end

# A session on another API than the server's takes that API's model, when it names one; on an OpenAI API of a server
# whose API has its own model, `default`.
def default_model(options: Config.Options, api: String) -> String
  return options.model if api == options.api
  return options.apis[api].model if options.apis[api].model != ""
  return Config.DEFAULT_MODEL if options.apis[options.api].model != ""

  options.model
end

# `FINN_COMPACT_MODEL` is a model of the server's API.
def own(options: Config.Options, api: String, value: String) -> String
  return "" if api != options.api

  value
end

def if_local(api: Config.ModelApi, url: String) -> String
  return "" if not api.local

  url
end

def summary_of(options: Config.Options, header: Store.Header) -> Protocol.SessionSummary
  Protocol.SessionSummary(id: header.id, cwd: header.cwd, model: header.model, api: header.api.unwrap_or(options.api))
end

# In the order they were made, not loaded yet. A file whose first line is not a session is left out, with a warning.
def load_sessions(options: Config.Options) -> List[Entry]
  dir = folder(options)
  names: List[String] = []
  case Dir.list(dir)
    ok(found) -> names = found.select { |name| name.end_with?(Store.EXTENSION) }
    error(e) -> IO.warn("sessions not listed: #{e.message}")
  end

  listed: List[Listed] = []
  for name in names
    file = "#{dir}/#{name}"
    case listed_session(file)
      ok(header) -> listed = listed.push(Listed(file: file, header: header))
      error(e) -> IO.warn("session #{name} not listed: #{e.message}")
    end
  end

  sorted = listed.sort_by { |one| one.header.id }.sort_by { |one| one.header.created_ms }
  sorted.map { |one|
    Entry(summary: summary_of(options, one.header), header: one.header, file: one.file, session: none)
  }
end

def listed_session(file: String) -> Result[Store.Header]
  info = try File.lstat(file)
  return error("not a regular file") if info.kind != "file"

  Store.header(file)
end

# `AGENTS.md` goes to the model only when it is a regular file inside the folder: a link out of it could be any file.
def skills_of(options: Config.Options, root: String) -> Skills.Found
  Skills.discover(root, options.home, trusted?(options, root))
end

# A session folder under a folder of `FINN_TRUSTED_DIRS`, whose own skills and allow rules count.
def trusted?(options: Config.Options, root: String) -> Bool
  options.trusted.any? { |dir| Sandbox.inside?(Path.real(dir).unwrap_or(dir), root) }
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end

# The approval extension of a session in `root`, when the server turns it on: the rules of the project file of the
# folder join the server's; a broken file is an invalid request.
def approvals_of(options: Config.Options, root: String) -> Result[Optional[Extension.Approvals]]
  for rules in option_list(options.approvals)
    case Extension.open(rules, root, trusted?(options, root))
      ok(approvals) -> return ok(some(approvals))
      error(e) -> return error(e.message, kind: Protocol.KIND_INVALID)
    end
  end

  ok(none)
end

# A deny rule of `read_file` hides its files from `glob` and `grep` too.
def opened(context: Tools.Context, approvals: Optional[Extension.Approvals]) -> Opened
  case approvals
    some(a) ->
      Opened(
        context: context.with(hidden: some(->(path: String) { Extension.hidden?(a, path) })),
        approvals: approvals,
      )
    none -> Opened(context: context, approvals: none)
  end
end

def catalog_provider(given: String, provider: LLM.Provider) -> String
  return given if not given.empty?
  return "anthropic" if provider.name == "anthropic"

  "openai"
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
