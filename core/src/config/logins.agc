## The logins of the server: the providers it offers now and the keys a login stored (`Auth`). One actor holds them, so
## a login or a logout changes the providers of every later request. The check of a key, one call at the provider's
## own base URL, runs in the caller's task; the key goes to the file and to the providers, never to a message. A
## change reads the file again first (another server may have written it), builds the providers, then writes: the
## state changes only when both work.

import Actor from "std/actor"
import HTTP from "std/http"
import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import Auth from "auth"
import Providers from "providers"

CALL_MS = 5000
## The check of a key at a login waits at most this long.
CHECK_MS = 10_000
FROM_ENV = "env"
FROM_FILE = "stored"
## A token in this variable wins over a stored key of `anthropic`, as `ANTHROPIC_API_KEY` does.
ANTHROPIC_TOKEN_ENV = "ANTHROPIC_AUTH_TOKEN"

## What a login needs, from `Config.from_env`.
struct Setup
  ## The file of the keys; none without a home folder. `owner` is the user who may own it.
  path: Optional[String]
  owner: Optional[Int] = none
  stored: Auth.Stored
  ## The providers a key logs in to: `anthropic`, the presets, and those of the config file with a `key_env`.
  entries: List[Providers.Custom]
  read: Fn[String, Result[String]]
  ## Every provider of the server with these stored keys; quick, it calls nothing.
  rebuild: Fn[Map[String, String], Result[Map[String, Providers.Provider]]]
  ## The server's provider was chosen (`FINN_BASE_URL`, `FINN_PROVIDER` or `FINN_API` is set): no login is offered.
  chosen: Bool = false
end

## What a list of the logins shows of a provider. `from` is where its key comes from: `env`, `stored` or empty.
struct Status
  name: String
  label: String = ""
  key_env: String = ""
  from: String = ""
  coming: Bool = false
end

## The logins, and `first`: no key file, no key of a provider in the environment and no provider chosen for the server,
## so a client offers a login.
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
  first = not state.stored.found and not setup.chosen and not shown.any? { |s| s.from == FROM_ENV }
  ok(Listing(providers: shown + coming, first: first))
end

## Checks `key` at the provider `name`, then stores it: the provider is offered from now on, unless its variable is
## set, which wins. An unknown name is not repeated: it may be a key typed in the wrong place.
def login(holder: Holder, name: String, key: String) -> Result[Status]
  state = try now(holder)
  setup = try usable(state)
  found = setup.entries.select { |entry| entry.name == name }
  if found.empty?
    names = setup.entries.map { |entry| entry.name }.join(", ")
    return error("no login for that provider: one of #{names}", kind: Protocol.KIND_INVALID)
  end

  return error("the key is empty", kind: Protocol.KIND_INVALID) if key.strip.empty?

  # A key file that cannot take the key is said before the key goes anywhere.
  for path in (option_list(setup.path).select { |p| File.stat(p).ok? })
    for why in option_list(Auth.refusal(path, setup.owner))
      return error(why, kind: Protocol.KIND_LOGIN_STORAGE)
    end
  end

  try check_key(found[0], key)
  stored: Result[Result[Status]] = Actor.call(holder.ref.address, CALL_MS) do |reply| Msg.Store(name, key, reply) end
  inner = try stored
  inner
end

## Removes the stored key of `name`, or every key (the file stays, empty) when none.
def logout(holder: Holder, name: Optional[String]) -> Result[Void]
  removed: Result[Result[Void]] = Actor.call(holder.ref.address, CALL_MS) do |reply| Msg.Remove(name, reply) end
  inner = try removed
  inner
end

## Makes an empty key file when there is none, so the first start does not offer a login again; a file that is there
## stays as it is.
def skip(holder: Holder) -> Result[Void]
  skipped: Result[Result[Void]] = Actor.call(holder.ref.address, CALL_MS) do |reply| Msg.Skip(reply) end
  inner = try skipped
  inner
end

## Checks `key` at the provider's own base URL, once, without following a redirect: `GET /models` of Anthropic, else
## `GET` of its `check_path` with the key as a Bearer token. What the provider said goes back only as its status or
## kind: a body might quote the request.
def check_key(entry: Providers.Custom, key: String) -> Result[Void]
  return anthropic_checked(entry, key) if entry.api == "anthropic"

  client = try HTTP.client(HTTP.ClientOptions(timeout_ms: CHECK_MS))
  headers = [HTTP.Header(name: "Authorization", value: "Bearer #{key}")]
  answer = HTTP.request(client, "GET", "#{entry.base_url}#{entry.check_path}", "".bytes, headers)
  HTTP.close_client(client)
  case answer
    ok(response) if response.status >= 200 and response.status < 300 -> ok()
    ok(response) if [401, 403].include?(response.status) -> rejected("#{entry.name} refused the key")
    ok(response) -> rejected("#{entry.base_url} did not check the key (HTTP #{response.status})")
    error(_) -> rejected("#{entry.base_url} cannot be reached")
  end
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
  Skip(Channel[Result[Void]])
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
      changed = saved(state, ->(keys: Map[String, String]) { ok(keys.put(name, key)) })
      Actor.reply(reply, status_after(changed, name))
      Actor.continue(changed.unwrap_or(state))
    Msg.Remove(name, reply) ->
      changed = saved(state, ->(keys: Map[String, String]) { removed(keys, name) })
      Actor.reply(reply, done(changed))
      Actor.continue(changed.unwrap_or(state))
    Msg.Skip(reply) ->
      changed = skipped(state)
      Actor.reply(reply, done(changed))
      Actor.continue(changed.unwrap_or(state))
  end
end

def removed(keys: Map[String, String], name: Optional[String]) -> Result[Map[String, String]]
  for one in option_list(name)
    return error("no key of that provider is stored", kind: Protocol.KIND_INVALID) if not keys.has_key?(one)

    return ok(keys.delete(one))
  end

  ok({})
end

def status_after(changed: Result[State], name: String) -> Result[Status]
  state = try changed
  setup = state.setup.unwrap!
  ok(status_of(setup, state.stored, setup.entries.select { |e| e.name == name }[0]))
end

def done(changed: Result[State]) -> Result[Void]
  _ = try changed
  ok()
end

# The keys of the file now, changed by `change`; the providers are built before the file is written.
def saved(state: State, change: Fn[Map[String, String], Result[Map[String, String]]]) -> Result[State]
  setup = try usable(state)
  path = try setup.path.to_result("there is no home folder for #{Auth.FILE}")
  now = Auth.load(path, setup.owner)
  return error(now.refused, kind: Protocol.KIND_LOGIN_STORAGE) if not now.refused.empty?

  keys = try change.call(now.keys)
  providers = try setup.rebuild.call(keys)
  case Auth.save(path, keys, setup.owner)
    ok(_) -> ok(state.with(providers: providers, stored: Auth.Stored(keys: keys, found: true)))
    error(e) -> error("#{path} cannot be written: #{e.message}", kind: Protocol.KIND_LOGIN_STORAGE)
  end
end

def skipped(state: State) -> Result[State]
  setup = try usable(state)
  path = try setup.path.to_result("there is no home folder for #{Auth.FILE}")
  found = state.with(stored: state.stored.with(found: true))
  return ok(found) if File.stat(path).ok?

  # Never over a file another process made since the check above.
  case Auth.create(path, {})
    ok(_) -> ok(found)
    error(e) if e.kind == "io.exists" -> ok(found)
    error(e) -> error("#{path} cannot be written: #{e.message}", kind: Protocol.KIND_LOGIN_STORAGE)
  end
end

def now(holder: Holder) -> Result[State] = Actor.call(holder.ref.address, CALL_MS) do |reply| Msg.Now(reply) end

def usable(state: State) -> Result[Setup] = state.setup.to_result("this server has no login")

def status_of(setup: Setup, stored: Auth.Stored, entry: Providers.Custom) -> Status
  from = ""
  if stored.keys.has_key?(entry.name)
    from = FROM_FILE
  end

  if (env_names(entry).any? { |name| not setup.read.call(name).unwrap_or("").empty? })
    from = FROM_ENV
  end

  Status(name: entry.name, key_env: entry.key_env, from: from)
end

def env_names(entry: Providers.Custom) -> List[String]
  return [entry.key_env, ANTHROPIC_TOKEN_ENV] if entry.name == Providers.ANTHROPIC

  [entry.key_env]
end

def anthropic_checked(entry: Providers.Custom, key: String) -> Result[Void]
  case LLM.models(LLM.anthropic(entry.base_url, key, LLM.Options(timeout_ms: CHECK_MS, tries: 1)))
    ok(_) -> ok()
    error(e) if e.kind == "llm.auth" -> rejected("#{entry.name} refused the key")
    error(e) -> rejected("#{entry.base_url} did not check the key (#{e.kind})")
  end
end

def rejected(message: String) -> Result[Void] = error(message, kind: Protocol.KIND_LOGIN_REJECTED)

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
