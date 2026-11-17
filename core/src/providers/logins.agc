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
## The variable of the base URL of `local`, which wins over a stored one.
LOCAL_ENV = "FINN_BASE_URL"

## What a login needs, from `Config.from_env`.
struct Setup
  ## The file of the keys; none without a home folder. `owner` is the user who may own it.
  path: Optional[String]
  owner: Optional[Int] = none
  stored: Auth.Stored
  ## The providers a key logs in to: `anthropic`, the presets, and those of the config file with a `key_env`.
  entries: List[Providers.Custom]
  read: Fn[String, Result[String]]
  ## Every provider of the server with these stored keys and base URLs; quick, it calls nothing.
  rebuild: Fn[Map[String, String], Map[String, String], Result[Map[String, Providers.Provider]]]
  ## The base URL of `local` without a stored one (its variable, else the default); empty: no login sets it.
  local_url: String = ""
  ## The variable that sets it (`FINN_BASE_URL` or its old name), which wins over a stored one; empty when none is set.
  local_env: String = ""
  ## `FINN_API_KEY`, sent to the check of a base URL as the turns send it.
  local_key: String = ""
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
  ## What a login gives: a key, or the base URL of a local server (`base_url` is the one it uses now).
  asks: String = Protocol.ASKS_KEY
  base_url: String = ""
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

## The providers the server offers now, and the base URL `local` uses now (empty when no login sets it).
struct Current
  providers: Map[String, Providers.Provider]
  local_url: String = ""
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

## The providers the server offers now, and the base URL `local` uses now.
def current(holder: Holder) -> Result[Current]
  state = try now(holder)
  url = state.setup.map { |setup| local_status(setup, state.stored).map { |l| l.base_url }.join("") }
  ok(Current(providers: state.providers, local_url: url.unwrap_or("")))
end

def list(holder: Holder) -> Result[Listing]
  state = try now(holder)
  return ok(Listing(providers: [], first: false)) if state.setup.none?

  setup = state.setup.unwrap!
  shown = local_status(setup, state.stored) + setup.entries.map { |entry| status_of(setup, state.stored, entry) }
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

## Checks that `url` is the base URL of a server of the OpenAI API (its `GET /models` answers), then stores it as the
## base URL of `local`, unless its variable is set, which wins.
def login_url(holder: Holder, name: String, url: String) -> Result[Status]
  setup = try usable(try now(holder))
  if name != Providers.LOCAL or setup.local_url.empty?
    return error("only #{Providers.LOCAL} takes a base URL", kind: Protocol.KIND_INVALID)
  end

  base = url
  while base.end_with?("/")
    base = base.slice(0, base.length - 1)
  end

  if not plain_url?(base)
    return error(
      "a base URL is http:// or https://, a host and a path, as http://127.0.0.1:8080/v1: no user, password, query or spaces",
      kind: Protocol.KIND_INVALID,
    )
  end

  for path in (option_list(setup.path).select { |p| File.stat(p).ok? })
    for why in option_list(Auth.refusal(path, setup.owner))
      return error(why, kind: Protocol.KIND_LOGIN_STORAGE)
    end
  end

  try check_url(base, setup.local_key)
  stored: Result[Result[Status]] = Actor.call(holder.ref.address, CALL_MS) do |reply|
    Msg.StoreUrl(name, base, reply)
  end

  inner = try stored
  inner
end

## Removes the stored key (or base URL) of `name`, or every one (the file stays, empty) when none.
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
  Now(Channel[State])
  Store(String, String, Channel[Result[Status]])
  StoreUrl(String, String, Channel[Result[Status]])
  Remove(Optional[String], Channel[Result[Void]])
  Skip(Channel[Result[Void]])
end

# Checks that `GET /models` at `base` answers, once, without following a redirect; with `FINN_API_KEY` (`key`) as a
# Bearer token when it is set.
def check_url(base: String, key: String) -> Result[Void]
  headers: List[HTTP.Header] = []
  if not key.empty?
    headers = [HTTP.Header(name: "Authorization", value: "Bearer #{key}")]
  end

  client = try HTTP.client(HTTP.ClientOptions(timeout_ms: CHECK_MS))
  answer = HTTP.request(client, "GET", "#{base}/models", "".bytes, headers)
  HTTP.close_client(client)
  case answer
    ok(response) if response.status >= 200 and response.status < 300 -> ok()
    ok(response) -> rejected("the server did not answer GET /models (HTTP #{response.status})")
    error(_) -> rejected("the server cannot be reached")
  end
end

# `http://` or `https://`, a host, and a path at most: the URL goes into requests and the clients show it, so it
# carries no user or password, query, fragment, space, control character (C0, C1) or bidi control.
def plain_url?(url: String) -> Bool
  rest = ""
  for scheme in ["http://", "https://"]
    if url.start_with?(scheme)
      rest = url.slice(scheme.length, url.length - scheme.length)
    end
  end

  host = rest.split("/")[0]
  return false if (host.empty? or host.start_with?(":") or ["@", "?", "#"].any? { |c| url.include?(c) })

  url.split("").all? { |c| plain_char?(c.code) }
end

def plain_char?(code: Int) -> Bool
  return false if code <= 32 or (code >= 127 and code <= 159) or code == 0x061C or code == 0x200E or code == 0x200F

  not ((code >= 0x202A and code <= 0x202E) or (code >= 0x2066 and code <= 0x2069))
end

def handle(state: State, msg: Msg) -> Actor.Step[State]
  case msg
    Msg.Now(reply) ->
      Actor.reply(reply, state)
      Actor.continue(state)
    Msg.Store(name, key, reply) ->
      changed = saved(state, ->(now: Auth.Stored) { ok(now.with(keys: now.keys.put(name, key))) })
      Actor.reply(reply, status_after(changed, name))
      Actor.continue(changed.unwrap_or(state))
    Msg.StoreUrl(name, url, reply) ->
      changed = saved(state, ->(now: Auth.Stored) { ok(now.with(urls: now.urls.put(name, url))) })
      Actor.reply(reply, status_after(changed, name))
      Actor.continue(changed.unwrap_or(state))
    Msg.Remove(name, reply) ->
      changed = saved(state, ->(now: Auth.Stored) { removed(now, name) })
      Actor.reply(reply, done(changed))
      Actor.continue(changed.unwrap_or(state))
    Msg.Skip(reply) ->
      changed = skipped(state)
      Actor.reply(reply, done(changed))
      Actor.continue(changed.unwrap_or(state))
  end
end

def removed(now: Auth.Stored, name: Optional[String]) -> Result[Auth.Stored]
  for one in option_list(name)
    if not now.keys.has_key?(one) and not now.urls.has_key?(one)
      return error("nothing of that provider is stored", kind: Protocol.KIND_INVALID)
    end

    return ok(now.with(keys: now.keys.delete(one), urls: now.urls.delete(one)))
  end

  ok(now.with(keys: {}, urls: {}))
end

def status_after(changed: Result[State], name: String) -> Result[Status]
  state = try changed
  setup = state.setup.unwrap!
  return ok(local_status(setup, state.stored)[0]) if name == Providers.LOCAL

  ok(status_of(setup, state.stored, setup.entries.select { |e| e.name == name }[0]))
end

def done(changed: Result[State]) -> Result[Void]
  _ = try changed
  ok()
end

# The keys and URLs of the file now, changed by `change`; the providers are built before the file is written.
def saved(state: State, change: Fn[Auth.Stored, Result[Auth.Stored]]) -> Result[State]
  setup = try usable(state)
  path = try setup.path.to_result("there is no home folder for #{Auth.FILE}")
  now = Auth.load(path, setup.owner)
  return error(now.refused, kind: Protocol.KIND_LOGIN_STORAGE) if not now.refused.empty?

  next = try change.call(now)
  providers = try setup.rebuild.call(next.keys, next.urls)
  case Auth.save(path, next.keys, next.urls, setup.owner)
    ok(_) -> ok(state.with(providers: providers, stored: Auth.Stored(keys: next.keys, urls: next.urls, found: true)))
    error(e) -> error("#{path} cannot be written: #{e.message}", kind: Protocol.KIND_LOGIN_STORAGE)
  end
end

def skipped(state: State) -> Result[State]
  setup = try usable(state)
  path = try setup.path.to_result("there is no home folder for #{Auth.FILE}")
  found = state.with(stored: state.stored.with(found: true))
  return ok(found) if File.stat(path).ok?

  # Never over a file another process made since the check above.
  case Auth.create(path, {}, {})
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

# The login of `local` when the setup has its URL: the one it uses now, from its variable, a login or the default.
def local_status(setup: Setup, stored: Auth.Stored) -> List[Status]
  return [] if setup.local_url.empty?

  from = ""
  base_url = setup.local_url
  if stored.urls.has_key?(Providers.LOCAL)
    from = FROM_FILE
    base_url = stored.urls[Providers.LOCAL]
  end

  key_env = LOCAL_ENV
  if not setup.local_env.empty?
    from = FROM_ENV
    key_env = setup.local_env
    base_url = setup.local_url
  end

  label = "a local server of the OpenAI API (llama.cpp)"
  [
    Status(
      name: Providers.LOCAL,
      label: label,
      key_env: key_env,
      from: from,
      asks: Protocol.ASKS_URL,
      base_url: base_url,
    ),
  ]
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
