## The ChatGPT login (Codex): OpenAI's device-code login, the tokens it gives, kept in `chatgpt.json` of the state
## folder (0600), their refresh, and the provider that sends the turns to the Responses API of Codex with them. The
## tokens go only to that file and to the requests of the login and the turns: never to a message, an event, a log
## or an error, which say only a status.

import HTTP from "std/http"
import URI from "std/uri"
import LLM from "pkg/llm/llm"
import Auth from "auth"
import Quota from "chatgpt_quota"
import Providers from "providers"
import Logger from "std/logger"

NAME = "chatgpt"
LABEL = "ChatGPT Plus or Pro (Codex)"
FILE = "chatgpt.json"
## The public client of the Codex CLI, which OpenAI's device-code login knows.
CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
ISSUER = "https://auth.openai.com"
BASE_URL = "https://chatgpt.com/backend-api/codex"
## The variables that move the login (`ISSUER`) and the API (`BASE_URL`) elsewhere: a proxy, or a test.
ISSUER_ENV = "FINN_CHATGPT_AUTH_URL"
BASE_URL_ENV = "FINN_CHATGPT_URL"
CALL_MS = 15_000
USAGE_MAX_BYTES = 1_048_576
## How long a usage answer is kept, and how long a failed one: the second failure in a row waits longer.
USAGE_CACHE_MS = 60_000
USAGE_RETRY_MS = 300_000
USAGE_RETRY_MAX_MS = 600_000
USAGE_LOCK = "usage"
## How often a device login polls when the login does not say, in seconds.
DEFAULT_INTERVAL_S = 5
MIN_INTERVAL_S = 1
MAX_INTERVAL_S = 60
## A device login waits this long for the user at most.
DEVICE_MS = 900_000
## The key of the lock in `Login.lock`.
LOCK = "refresh"

## Where the login and the API are, how a device login polls (the interval the server asks, at least `min_poll_ms`,
## plus `poll_margin_ms`) and waits for the user (`device_ms`), and how long a call of the login may take.
struct Endpoints
  issuer: String = ISSUER
  base_url: String = BASE_URL
  min_poll_ms: Int = 1000
  poll_margin_ms: Int = 3000
  device_ms: Int = DEVICE_MS
  call_ms: Int = CALL_MS
  ## A holder of the lock keeps it one call and this long at most.
  lock_margin_ms: Int = 5000
end

## What a login keeps: the tokens, the account they are of, and the models Codex listed at the login.
struct Tokens
  access: String
  refresh: String
  account: String
  models: List[String]
end

## The login of a server: the file and who may own it (`Auth.refusal`), the endpoints, and the lock that makes the
## refreshes and saves of its tokens go one at a time (its holder and until when it holds it).
struct Login
  path: String
  owner: Optional[Int] = none
  endpoints: Endpoints
  lock: ATS[String, String]
  usage_cache: ATS[String, CachedUsage]
end

## A cached subscription response, bound to the login that produced it.
struct CachedUsage
  access: String
  account: String
  at_ms: Int
  result: Result[List[Quota.Window]]
  ## How many reads failed in a row, this one included.
  failures: Int = 0
end

## A device login that started: the code the user types at `url`. `id` asks for its end and stays on the server.
struct Device
  user_code: String
  url: String
  interval_ms: Int
  id: String
end

## The endpoints of the variables: `https://`, or `http://` on this machine only (a test).
def endpoints(read: Fn[String, Result[String]]) -> Result[Endpoints]
  ok(Endpoints(issuer: try given(read, ISSUER_ENV, ISSUER), base_url: try given(read, BASE_URL_ENV, BASE_URL)))
end

def login(state_dir: String, owner: Optional[Int], read: Fn[String, Result[String]]) -> Result[Login]
  ok(
    Login(
      path: "#{state_dir}/#{FILE}",
      owner: owner,
      endpoints: try endpoints(read),
      lock: ATS.new(),
      usage_cache: ATS.new(),
    ),
  )
end

## The tokens of the file, none when it is missing. A file others may read, of another user or not a login is an
## error that says only why.
def load(login: Login) -> Result[Optional[Tokens]]
  return ok(none) if not File.lstat(login.path).ok?

  try usable(login)

  case JSON.decode(try File.read_text(login.path), TokenFile)
    ok(file) ->
      ok(
        some(
          Tokens(
            access: file.access_token,
            refresh: file.refresh_token,
            account: file.account_id,
            models: file.models,
          ),
        ),
      )
    error(_) -> error("#{login.path} is not a ChatGPT login: log in again")
  end
end

## Writes the file, one save or refresh at a time (`save`).
def store(login: Login, tokens: Tokens) -> Result[Void]
  holder = try locked(login)
  result = save(login, tokens)
  unlock(login, holder)
  result
end

## Writes the file, private from the start: a new one under another name in the same folder, then renamed.
def save(login: Login, tokens: Tokens) -> Result[Void]
  text = JSON.encode(
    JSON.object({
      "access_token": JSON.from(tokens.access),
      "refresh_token": JSON.from(tokens.refresh),
      "account_id": JSON.from(tokens.account),
      "models": JSON.from(tokens.models),
    }),
  )

  # One there is checked again (its mode may have changed) and replaced in one step, keeping its mode.
  if File.lstat(login.path).ok?
    try usable(login)
    return File.replace(login.path, text.bytes)
  end

  # `Path.rename` refuses an existing target: that is how a lost race is detected (`io.exists`), where `Path.replace`
  # would win it.
  temp = "#{login.path}.#{OpenSSL.Random.hex(8)}.tmp"
  moved = written(temp, login.path, text)
  if not moved.ok?
    _ = Path.remove(temp)
  end

  moved
end

## Removes the login file after the refresh in progress, or without waiting for it when that does not end.
def remove(login: Login) -> Result[Void]
  held = locked(login)
  result = remove_locked(login)
  case held
    ok(holder) -> unlock(login, holder)
    error(_) -> nil
  end

  result
end

def remove_locked(login: Login) -> Result[Void]
  login.usage_cache.delete(USAGE_LOCK)
  return ok() if not File.stat(login.path).ok?

  Path.remove(login.path)
end

## Asks OpenAI for a device code.
def start(endpoints: Endpoints) -> Result[Device]
  body = JSON.encode(JSON.object({"client_id": JSON.from(CLIENT_ID)}))
  answer = try post(endpoints, "/api/accounts/deviceauth/usercode", body, JSON_TYPE)
  return error("the ChatGPT login did not start (HTTP #{answer.status})") if answer.status != 200

  code = try usercode(try text_of(answer))
  interval = [code.interval * 1000, endpoints.min_poll_ms].max.unwrap!
  ok(
    Device(
      user_code: code.user_code,
      url: "#{endpoints.issuer}/codex/device",
      interval_ms: interval,
      id: code.device_auth_id,
    ),
  )
end

## Polls until the user confirmed the code, then takes the tokens and the models of the account; at most `wait_ms`.
def finish(endpoints: Endpoints, device: Device) -> Result[Tokens]
  deadline = Time.monotonic_ms + endpoints.device_ms
  body = JSON.encode(JSON.object({"device_auth_id": JSON.from(device.id), "user_code": JSON.from(device.user_code)}))
  while Time.monotonic_ms < deadline
    Task.sleep(device.interval_ms + endpoints.poll_margin_ms)
    answer = try post(endpoints, "/api/accounts/deviceauth/token", body, JSON_TYPE)
    next if [403, 404].include?(answer.status)
    return error("the ChatGPT login failed (HTTP #{answer.status})") if answer.status != 200

    grant = try answered(JSON.decode(try text_of(answer), Grant))
    form = [
      URI.Pair(name: "grant_type", value: "authorization_code"),
      URI.Pair(name: "code", value: grant.authorization_code),
      URI.Pair(name: "redirect_uri", value: "#{endpoints.issuer}/deviceauth/callback"),
      URI.Pair(name: "client_id", value: CLIENT_ID),
      URI.Pair(name: "code_verifier", value: grant.code_verifier),
    ]

    granted = try token_call(endpoints, form, "the ChatGPT login failed")
    account = account_of(granted)
    models = try listed(endpoints, granted.access_token, account)
    return ok(
      Tokens(
        access: granted.access_token,
        refresh: granted.refresh_token.unwrap_or(""),
        account: account,
        models: models,
      ),
    )
  end

  error("the ChatGPT login was not confirmed in time")
end

## New tokens for `tokens`: a refresh gives a new refresh token too, and the old one stops working.
def refreshed(endpoints: Endpoints, tokens: Tokens) -> Result[Tokens]
  return error("the ChatGPT login has no refresh token: log in again") if tokens.refresh.empty?

  form = [
    URI.Pair(name: "grant_type", value: "refresh_token"),
    URI.Pair(name: "refresh_token", value: tokens.refresh),
    URI.Pair(name: "client_id", value: CLIENT_ID),
  ]

  granted = try token_call(endpoints, form, "the ChatGPT token was not refreshed")
  account = account_of(granted)
  if account.empty?
    account = tokens.account
  end

  ok(
    tokens.with(
      access: granted.access_token,
      refresh: granted.refresh_token.unwrap_or(tokens.refresh),
      account: account,
    ),
  )
end

## The tokens after a 401 with `used`, one refresh at a time: those of the file when another session refreshed them
## since, else refreshed and saved. Tokens that cannot be saved still serve this server.
def renewed(login: Login, used: String) -> Result[Tokens]
  holder = try locked(login)
  result = renewed_locked(login, used)
  unlock(login, holder)
  result
end

## The subscription windows with the current login. A 401 does not renew the login: the chat calls do that, and a
## lasting 401 here would rotate the refresh token again and again.
def usage(login: Login) -> Result[List[Quota.Window]]
  tokens = try (try load(login)).to_result("the ChatGPT login is gone: log in again")
  usage_read(login.endpoints, tokens)
end

## The subscription windows shared by clients: cached for a minute (longer after a failure) and read by one at a time;
## while one reads, the clients get the last good answer.
def cached_usage(login: Login) -> Result[List[Quota.Window]]
  tokens = try (try load(login)).to_result("the ChatGPT login is gone: log in again")
  previous = usage_entry(login, tokens)
  for entry in option_list(previous)
    return entry.result if usage_current?(entry)
  end

  now = Time.monotonic_ms
  holder = OpenSSL.Random.hex(8)
  until_ms = now + (login.endpoints.call_ms + login.endpoints.lock_margin_ms) * 5
  if not login.lock.put_new(USAGE_LOCK, "#{holder} #{until_ms}")
    held = login.lock.get(USAGE_LOCK).unwrap_or("")
    if held.empty? or until_of(held) >= now or not login.lock.put_new("takeover #{held}", holder)
      for entry in option_list(previous)
        return entry.result if entry.result.ok?
      end

      return error("the ChatGPT usage request is already running")
    end

    login.lock.put(USAGE_LOCK, "#{holder} #{until_ms}")
  end

  result = refresh_usage(login, tokens, holder)
  if login.lock.get(USAGE_LOCK).unwrap_or("").start_with?("#{holder} ")
    login.lock.delete(USAGE_LOCK)
  end

  result
end

def refresh_usage(login: Login, tokens: Tokens, holder: String) -> Result[List[Quota.Window]]
  initial = try load(login)
  return error("the ChatGPT login changed during the usage request") if initial != some(tokens)

  failures = 0
  for entry in option_list(usage_entry(login, tokens))
    return entry.result if usage_current?(entry)

    failures = entry.failures
  end

  result = usage_read(login.endpoints, tokens)
  case result
    ok(_) -> failures = 0
    error(e) ->
      failures += 1
      Logger.debug("the ChatGPT usage read failed: #{e.message}")
  end

  same_account = load(login) == ok(some(tokens))
  owned = login.lock.get(USAGE_LOCK).unwrap_or("").start_with?("#{holder} ")
  if same_account and owned
    login.usage_cache.put(
      USAGE_LOCK,
      CachedUsage(
        access: tokens.access,
        account: tokens.account,
        at_ms: Time.monotonic_ms,
        result: result,
        failures: failures,
      ),
    )
  end

  return error("the ChatGPT login changed during the usage request") if not same_account
  return error("the ChatGPT usage request expired") if not owned

  result
end

## The provider of the file's tokens; none without a login. Its first model is the default one.
def offered(login: Login, options: LLM.Options) -> Optional[Providers.Provider]
  case load(login)
    ok(some(tokens)) if not tokens.access.empty? -> some(provider_of(login, tokens, options))
    _ -> none
  end
end

## `built` with the provider of the login's tokens, when there are some.
def added(
  built: Result[Map[String, Providers.Provider]],
  login: Login,
  options: LLM.Options,
) -> Result[Map[String, Providers.Provider]]
  providers = try built
  for provider in option_list(offered(login, options))
    providers = providers.put(NAME, provider)
  end

  ok(providers)
end

## Why the file is not used, when it is there but cannot be.
def refusal(login: Login) -> Optional[String]
  case load(login)
    error(e) -> some(e.message)
    ok(_) -> none
  end
end

## The device code the login answered: `interval` is a number of seconds or the text of one (the login answers `"5"`),
## and may be left out; it is kept between 1 and 60 so that a wait is never long nor an overflow.
def usercode(text: String) -> Result[UserCode]
  json = try answered(JSON.parse(text))
  id = try answered(JSON.string(try answered(JSON.get(json, "device_auth_id"))))
  code = try answered(JSON.string(try answered(JSON.get(json, "user_code"))))
  interval = DEFAULT_INTERVAL_S
  case JSON.get(json, "interval")
    ok(value) -> interval = seconds_of(JSON.node(value))
    error(_) -> nil
  end

  ok(UserCode(device_auth_id: id, user_code: code, interval: interval))
end

def seconds_of(node: JSON.Node) -> Int
  case node
    JSON.Node.Int(n) -> clamped(n)
    JSON.Node.String(text) -> clamped(text.strip.to_i.unwrap_or(DEFAULT_INTERVAL_S))
    _ -> DEFAULT_INTERVAL_S
  end
end

def clamped(seconds: Int) -> Int = [[seconds, MIN_INTERVAL_S].max.unwrap!, MAX_INTERVAL_S].min.unwrap!

private

LOOPBACK = ["http://127.0.0.1:", "http://127.0.0.1/", "http://localhost:", "http://localhost/", "http://[::1]:"]
JSON_TYPE = "application/json"
FORM_TYPE = "application/x-www-form-urlencoded"
USED = "used"

struct TokenFile
  access_token: String
  refresh_token: String
  account_id: String
  models: List[String]
end

struct UserCode
  device_auth_id: String
  user_code: String
  ## Seconds.
  interval: Int
end

struct Grant
  authorization_code: String
  code_verifier: String
end

struct Granted
  access_token: String
  refresh_token: Optional[String]
  id_token: Optional[String]
end

struct Claims
  chatgpt_account_id: Optional[String]
end

def usage_url(endpoints: Endpoints) -> String
  root = endpoints.base_url
  while root.end_with?("/")
    root = root.slice(0, root.length - 1)
  end

  if root.end_with?("/codex")
    root = root.slice(0, root.length - "/codex".length)
  end

  "#{root}/wham/usage"
end

def usage_entry(login: Login, tokens: Tokens) -> Optional[CachedUsage]
  case login.usage_cache.get(USAGE_LOCK)
    ok(entry) if entry.access == tokens.access and entry.account == tokens.account -> some(entry)
    _ -> none
  end
end

def usage_current?(entry: CachedUsage) -> Bool
  ttl = USAGE_CACHE_MS
  if not entry.result.ok?
    ttl = USAGE_RETRY_MS
    if entry.failures > 1
      ttl = USAGE_RETRY_MAX_MS
    end
  end

  Time.monotonic_ms - entry.at_ms < ttl
end

def usage_read(endpoints: Endpoints, tokens: Tokens) -> Result[List[Quota.Window]]
  case usage_request(endpoints, tokens)
    ok(response) -> usage_answer(response)
    error(e) -> error(e.message)
  end
end

def usage_request(endpoints: Endpoints, tokens: Tokens) -> Result[HTTP.Response]
  client = try HTTP.client(HTTP.ClientOptions(timeout_ms: endpoints.call_ms, max_body_bytes: USAGE_MAX_BYTES))
  headers = [
    HTTP.Header(name: "Authorization", value: "Bearer #{tokens.access}"),
    HTTP.Header(name: "ChatGPT-Account-Id", value: tokens.account),
  ]

  answer = HTTP.request(client, "GET", usage_url(endpoints), "".bytes, headers)
  HTTP.close_client(client)
  case answer
    ok(response) -> ok(response)
    error(_) -> error("the ChatGPT usage request failed")
  end
end

def usage_answer(response: HTTP.Response) -> Result[List[Quota.Window]]
  return error("the ChatGPT usage request failed (HTTP #{response.status})") if response.status != 200

  case String.from_bytes(response.body)
    ok(text) ->
      case Quota.parse(text)
        ok(windows) -> ok(windows)
        error(_) -> error("the ChatGPT usage response was invalid")
      end

    error(_) -> error("the ChatGPT usage response was invalid")
  end
end

def given(read: Fn[String, Result[String]], name: String, fallback: String) -> Result[String]
  url = case read.call(name)
    ok(value) if not value.empty? -> value
    _ -> fallback
  end

  return ok(url) if (url.start_with?("https://") or LOOPBACK.any? { |start| url.start_with?(start) })

  error("#{name} must be an https:// URL (http:// only on this machine)")
end

# A file there must be a regular file (not a link) that only its user may read.
def usable(login: Login) -> Result[Void]
  return error("#{login.path} is not a regular file: it is not used") if (try File.lstat(login.path)).kind != "file"

  for why in option_list(Auth.refusal(login.path, login.owner))
    return error(why)
  end

  ok()
end

# Each session gets its own refresh (`renewer`), which knows the token its provider sends: the one of the start, then
# the one of its last refresh.
def provider_of(login: Login, tokens: Tokens, options: LLM.Options) -> Providers.Provider
  url = login.endpoints.base_url
  access = tokens.access
  api = Providers.ModelApi(
    provider: LLM.codex(url, tokens.access, tokens.account, options),
    extra: Providers.stateless(),
    model: tokens.models.take(1).join(""),
    local: false,
    renewer: some(-> { session_refresh(login, access, options) }),
  )

  Providers.Provider(apis: {"openai_responses": api}, api: "openai_responses", catalog: NAME, models: tokens.models)
end

def session_refresh(login: Login, access: String, options: LLM.Options) -> Fn[Result[LLM.Provider]]
  used: ATS[String, String] = ATS.new()
  used.put(USED, access)
  -> { fresh_provider(login, used, options) }
end

def fresh_provider(login: Login, used: ATS[String, String], options: LLM.Options) -> Result[LLM.Provider]
  fresh = try renewed(login, used.get(USED).unwrap_or(""))
  used.put(USED, fresh.access)
  ok(LLM.codex(login.endpoints.base_url, fresh.access, fresh.account, options))
end

def renewed_locked(login: Login, used: String) -> Result[Tokens]
  now = try (try load(login)).to_result("the ChatGPT login is gone: log in again")
  return ok(now) if now.access != used

  fresh = try refreshed(login.endpoints, now)
  case save(login, fresh)
    ok(_) -> nil
    error(e) -> Logger.warning("the refreshed ChatGPT login was not saved: #{e.message}")
  end

  ok(fresh)
end

# Takes the lock, and gives the holder's name. A holder keeps it one call and `lock_margin_ms` at most: one cancelled
# or crashed in between never gives it back, so after that time it is taken over. Of the waiters that find it stale,
# only the one that first marks that very entry as taken over (`put_new` of its own key) takes it.
def locked(login: Login) -> Result[String]
  holder = OpenSSL.Random.hex(8)
  hold_ms = login.endpoints.call_ms + login.endpoints.lock_margin_ms
  give_up = Time.monotonic_ms + hold_ms * 2
  while true
    now = Time.monotonic_ms
    return ok(holder) if login.lock.put_new(LOCK, "#{holder} #{now + hold_ms}")

    held = login.lock.get(LOCK).unwrap_or("")
    if until_of(held) < now and login.lock.put_new("takeover #{held}", holder)
      login.lock.put(LOCK, "#{holder} #{now + hold_ms}")
      return ok(holder)
    end

    return error("another refresh of the ChatGPT login did not end") if now >= give_up

    Task.sleep(10 + Random.int(0, 20))
  end

  error("unreachable")
end

def unlock(login: Login, holder: String) -> Void
  if login.lock.get(LOCK).unwrap_or("").start_with?("#{holder} ")
    login.lock.delete(LOCK)
  end
end

def until_of(held: String) -> Int
  parts = held.split(" ")
  return 0 if parts.size != 2

  parts[1].to_i.unwrap_or(0)
end

def token_call(endpoints: Endpoints, form: List[URI.Pair], failed: String) -> Result[Granted]
  answer = try post(endpoints, "/oauth/token", URI.encode_www_form(form), FORM_TYPE)
  return error("#{failed} (HTTP #{answer.status})") if answer.status != 200

  granted = try answered(JSON.decode(try text_of(answer), Granted))
  return error("#{failed}: no access token") if granted.access_token.empty?

  ok(granted)
end

# The models of the account, in the order Codex lists them.
def listed(endpoints: Endpoints, access: String, account: String) -> Result[List[String]]
  case LLM.models(LLM.codex(endpoints.base_url, access, account, LLM.Options(timeout_ms: endpoints.call_ms, tries: 1)))
    ok(models) if not models.empty? -> ok(models.map { |m| m.id })
    ok(_) -> error("Codex listed no model for this account")
    error(e) -> error("Codex did not list the models (#{e.kind})")
  end
end

# The ChatGPT account of the id token (else the access token): its claims, read without a check of the signature, which
# only the server that made the token needs.
def account_of(granted: Granted) -> String
  for token in option_list(granted.id_token) + [granted.access_token]
    found = claimed(token)
    return found if not found.empty?
  end

  ""
end

def claimed(token: String) -> String
  parts = token.split(".")
  return "" if parts.size != 3

  case Base64.urlsafe_decode64(parts[1])
    ok(bytes) ->
      case JSON.parse(String.from_bytes(bytes).unwrap_or(""))
        ok(claims) -> account_in(claims)
        error(_) -> ""
      end

    error(_) -> ""
  end
end

def account_in(claims: JSON.Value) -> String
  for at in [claims, JSON.get(claims, "https://api.openai.com/auth").unwrap_or(JSON.object({}))]
    case JSON.decode(JSON.encode(at), Claims)
      ok(found) if found.chatgpt_account_id.unwrap_or("") != "" -> return found.chatgpt_account_id.unwrap!
      _ -> nil
    end
  end

  ""
end

def post(endpoints: Endpoints, path: String, body: String, kind: String) -> Result[HTTP.Response]
  client = try HTTP.client(HTTP.ClientOptions(timeout_ms: endpoints.call_ms))
  headers = [HTTP.Header(name: "Content-Type", value: kind), HTTP.Header(name: "Accept", value: JSON_TYPE)]
  answer = HTTP.request(client, "POST", "#{endpoints.issuer}#{path}", body.bytes, headers)
  HTTP.close_client(client)
  case answer
    ok(response) -> ok(response)
    error(_) -> error("#{endpoints.issuer} cannot be reached")
  end
end

def text_of(answer: HTTP.Response) -> Result[String]
  case String.from_bytes(answer.body)
    ok(text) -> ok(text)
    error(_) -> error("the ChatGPT login answered what is not text")
  end
end

# A body that does not decode is said without its text: it may hold a token.
def answered[T](result: Result[T]) -> Result[T]
  case result
    ok(value) -> ok(value)
    error(_) -> error("the ChatGPT login answered what this server does not read")
  end
end

def written(temp: String, path: String, text: String) -> Result[Void]
  try File.open(temp, "create_private") do |handle| File.write(handle, text) end
  # `Path.rename` refuses an existing target: that is how a lost race is detected (`io.exists`), where `Path.replace`
  # would win it.
  Path.rename(temp, path)
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
