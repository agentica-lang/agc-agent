## The logins of the server: the providers it offers now and the keys a login stored (`Auth`). One actor holds them, so
## a login or a logout changes the providers of every later request. The check of a key, one `GET /models` at the
## provider's own base URL, runs in the caller's task; the key goes to the file and to the providers, never to a
## message.

import Actor from "std/actor"
import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import Auth from "auth"
import Providers from "providers"

CALL_MS = 5000
FROM_ENV = "env"
FROM_FILE = "stored"

## What a login needs, from `Config.from_env`.
struct Setup
  ## The file of the keys; none without a home folder.
  path: Optional[String]
  stored: Auth.Stored
  ## The providers a key logs in to: `anthropic`, the presets, and those of the config file with a `key_env`.
  entries: List[Providers.Custom]
  read: Fn[String, Result[String]]
  ## Every provider of the server with these stored keys.
  rebuild: Fn[Map[String, String], Result[Map[String, Providers.Provider]]]
  ## The provider `name` at its base URL with `key`, for the check.
  probe: Fn[String, String, Result[LLM.Provider]]
end

## What a list of the logins shows of a provider. `from` is where its key comes from: `env`, `stored` or empty.
struct Status
  name: String
  label: String = ""
  key_env: String = ""
  from: String = ""
  coming: Bool = false
end

## The logins, and `first`: no key file and no key of a provider in the environment, so a client offers a login.
struct Listing
  providers: List[Status]
  first: Bool
end

struct Holder
  ref: Actor.Ref[State, Msg]
end

## Holds `providers`; without `setup` there is no login (`list` is empty).
def start(providers: Map[String, Providers.Provider], setup: Optional[Setup]) -> Holder
  stored = setup.map { |s| s.stored }.unwrap_or(Auth.Stored())
  init = -> { State(providers: providers, setup: setup, stored: stored) }
  Holder(ref: Actor.start(Actor.Behaviour(init: init, handle: &handle)))
end

def stop(holder: Holder) -> Void
  _ = Actor.stop(holder.ref, CALL_MS)
end

## The providers the server offers now.
def providers(holder: Holder) -> Result[Map[String, Providers.Provider]]
  Actor.call(holder.ref.address, CALL_MS) do |reply| Msg.Current(reply) end
end

def list(holder: Holder) -> Result[Listing]
  state = try now(holder)
  return ok(Listing(providers: [], first: false)) if state.setup.none?

  setup = state.setup.unwrap!
  shown = setup.entries.map { |entry| status_of(setup, state.stored, entry) }
  coming = Providers.coming().map { |c| Status(name: c.name, label: c.label, coming: true) }
  first = not state.stored.found and not shown.any? { |s| s.from == FROM_ENV }
  ok(Listing(providers: shown + coming, first: first))
end

## Checks `key` at the provider `name`, then stores it: the provider is offered from now on, unless its variable is
## set, which wins.
def login(holder: Holder, name: String, key: String) -> Result[Status]
  state = try now(holder)
  setup = try usable(state)
  found = setup.entries.select { |entry| entry.name == name }
  if found.empty?
    names = setup.entries.map { |entry| entry.name }.join(", ")
    return error("no login for #{name}: one of #{names}", kind: Protocol.KIND_INVALID)
  end

  return error("the key is empty", kind: Protocol.KIND_INVALID) if key.strip.empty?

  try checked(found[0], setup.probe.call(name, key))
  stored: Result[Result[Status]] = Actor.call(holder.ref.address, CALL_MS) do |reply| Msg.Store(name, key, reply) end
  inner = try stored
  inner
end

## Removes the stored key of `name`, or every key (the file stays, empty) when none.
def logout(holder: Holder, name: Optional[String]) -> Result[Void]
  state = try now(holder)
  _ = try usable(state)
  for one in option_list(name)
    return error("no key of #{one} is stored", kind: Protocol.KIND_INVALID) if not state.stored.keys.has_key?(one)
  end

  removed: Result[Result[Void]] = Actor.call(holder.ref.address, CALL_MS) do |reply| Msg.Remove(name, reply) end
  inner = try removed
  inner
end

private

struct State
  providers: Map[String, Providers.Provider]
  setup: Optional[Setup]
  stored: Auth.Stored
end

enum Msg
  Current(Channel[Map[String, Providers.Provider]])
  Now(Channel[State])
  Store(String, String, Channel[Result[Status]])
  Remove(Optional[String], Channel[Result[Void]])
end

def handle(state: State, msg: Msg) -> Actor.Step[State]
  case msg
    Msg.Current(reply) ->
      Actor.reply(reply, state.providers)
      Actor.continue(state)
    Msg.Now(reply) ->
      Actor.reply(reply, state)
      Actor.continue(state)
    Msg.Store(name, key, reply) ->
      case saved(state, state.stored.keys.put(name, key))
        ok(next) ->
          setup = next.setup.unwrap!
          entry = setup.entries.select { |e| e.name == name }[0]
          Actor.reply(reply, ok(status_of(setup, next.stored, entry)))
          Actor.continue(next)
        error(e) ->
          Actor.reply(reply, error(e))
          Actor.continue(state)
      end

    Msg.Remove(name, reply) ->
      keys: Map[String, String] = {}
      for one in option_list(name)
        keys = state.stored.keys.delete(one)
      end

      case saved(state, keys)
        ok(next) ->
          Actor.reply(reply, ok())
          Actor.continue(next)
        error(e) ->
          Actor.reply(reply, error(e))
          Actor.continue(state)
      end
  end
end

# The file first: a key that cannot be written is not offered.
def saved(state: State, keys: Map[String, String]) -> Result[State]
  setup = try usable(state)
  path = try setup.path.to_result("there is no home folder for #{Auth.FILE}")
  stored_file = Auth.save(path, keys)
  case stored_file
    ok(_) -> nil
    error(e) -> return error("#{path} cannot be written: #{e.message}", kind: Protocol.KIND_LOGIN_STORAGE)
  end

  providers = try setup.rebuild.call(keys)
  ok(state.with(providers: providers, stored: Auth.Stored(keys: keys, found: true)))
end

def now(holder: Holder) -> Result[State] = Actor.call(holder.ref.address, CALL_MS) do |reply| Msg.Now(reply) end

def usable(state: State) -> Result[Setup]
  setup = try state.setup.to_result("this server has no login")
  return error(state.stored.refused, kind: Protocol.KIND_LOGIN_STORAGE) if not state.stored.refused.empty?

  ok(setup)
end

def status_of(setup: Setup, stored: Auth.Stored, entry: Providers.Custom) -> Status
  from = ""
  if stored.keys.has_key?(entry.name)
    from = FROM_FILE
  end

  if not setup.read.call(entry.key_env).unwrap_or("").empty?
    from = FROM_ENV
  end

  Status(name: entry.name, key_env: entry.key_env, from: from)
end

# What the provider said goes back only as its kind: a body might quote the request.
def checked(entry: Providers.Custom, probe: Result[LLM.Provider]) -> Result[Void]
  provider = try probe
  case LLM.models(provider)
    ok(_) -> ok()
    error(e) if e.kind == "llm.auth" -> error("#{entry.name} refused the key", kind: Protocol.KIND_LOGIN_REJECTED)
    error(e) -> error("#{entry.base_url} did not answer the check (#{e.kind})", kind: Protocol.KIND_LOGIN_REJECTED)
  end
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
