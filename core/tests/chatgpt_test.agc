# The ChatGPT login: a device login against a fake OAuth server and a fake Codex, its tokens in a private file of the
# state folder, the turns of a `chatgpt` session with them, a refresh after each 401, and a logout. No token goes to an
# event, a session file or an error.

import Protocol from "pkg/protocol/protocol"
import HTTP from "std/http"
import Chatgpt from "../src/providers/chatgpt"
import Config from "../src/config/config"
import Extensions from "../src/config/registry"
import Fake from "support/fake_llm"
import H from "support/harness"

TOKENS = Chatgpt.Tokens(access: "at-secret-1", refresh: "rt-secret-1", account: "acct-1", models: ["gpt-test-codex"])
POLL_MS = 150

def test_the_quota_segment_serves_chatgpt_sessions_and_shares_usage() -> Result[Void]
  replies = ["codex_usercode.json", "codex_grant.json", "codex_tokens.json", "codex_models.json", "codex_usage.json"]
  stuck = Extensions.StatusProvider(name: "ext.stuck", value: &stuck_segment)
  registry = Extensions.Registry(status_providers: [stuck], status_ms: 200)
  setup = H.Setup(replies: replies, api: "openai_responses", chatgpt: true, registry: some(registry))
  H.using(setup) do |h|
    local = try H.new_session(h)
    local_reply = try H.get(h, Protocol.status_segments_path(local))
    try Test.assert(local_reply.status == 200, "quota route returned #{local_reply.status}: #{local_reply.text}")
    try Test.eq((try Protocol.decode_status_segments(local_reply.text)).segments, [])
    try Test.assert(h.fake.seen.empty?, "local sessions do not request quota")
    device = try H.post(h, Protocol.auth_path("chatgpt"), "{}")
    try Test.eq(device.status, 200)
    try Test.eq((try waited(h)).state, "done")
    _ = try requests(h, 4)
    expected = Protocol.StatusSegments(
      segments: [Protocol.StatusSegment(name: "chatgpt.quota", text: "5h 72% · 7d 40%")],
    )

    first = try H.new_session_in(h, h.work, provider: some("chatgpt"))
    second = try H.new_session_in(h, h.work, provider: some("chatgpt"))
    for id in [first, second]
      answer = try H.get(h, Protocol.status_segments_path(id))
      try Test.eq(answer.status, 200)
      try Test.eq(try Protocol.decode_status_segments(answer.text), expected)
    end

    try Test.eq((try H.next_request(h)).path, "/wham/usage")
    logout = try H.call(h, "DELETE", Protocol.auth_path("chatgpt"), "", H.auth(h))
    try Test.eq(logout.status, 200)
    after = try H.get(h, Protocol.status_segments_path(first))
    try Test.eq(after.status, 200)
    try Test.eq((try Protocol.decode_status_segments(after.text)).segments, [])
    Test.assert(h.fake.seen.empty?, "both sessions share one quota request and logout makes no request")
  end
end

# A segment that never answers is left out after its own limit, and does not take the quota's time.
def stuck_segment(_context: Extensions.StatusContext) -> Result[String]
  gate: Channel[String] = Channel.new(1)
  gate.recv(30_000)
end

# With every slot taken the route answers 503, which the clients treat as a failed read and keep their last segments.
def test_a_busy_status_route_answers_503() -> Result[Void]
  stuck = Extensions.StatusProvider(name: "ext.stuck", value: &stuck_segment)
  setup = H.Setup(replies: [], registry: some(Extensions.Registry(status_providers: [stuck], status_ms: 1500)))
  H.using(setup) do |h|
    id = try H.new_session(h)
    calls = (0...6).to_a.map { |_| Task.spawn(-> { H.get(h, Protocol.status_segments_path(id)) }) }
    statuses = calls.map { |call| Task.await(call).unwrap!.status }
    try Test.assert(statuses.select { |status| status == 503 }.size >= 1, "no busy answer: #{statuses}")
    Test.eq(statuses.select { |status| status != 503 }, [200, 200, 200, 200])
  end
end

def test_usage_in_flight_does_not_cross_accounts() -> Result[Void]
  setup = H.Setup(replies: ["codex_usage.json@hold", "codex_usage.json"], api: "openai_responses", chatgpt: true)
  H.using(setup) do |h|
    login = H.chatgpt_login(h.fake, h.base)
    try Chatgpt.save(login, TOKENS)
    first = Task.spawn(-> { Chatgpt.cached_usage(login) })
    _ = try H.next_request(h)
    try Test.assert(not Chatgpt.cached_usage(login).ok?, "a concurrent request does not start another fetch")
    try Chatgpt.store(login, TOKENS.with(access: "other", account: "other"))
    H.release(h)
    try Test.assert(not Task.await(first).ok?, "the previous account's response must be discarded")
    try Test.eq((try Chatgpt.cached_usage(login)).map { |window| window.remaining }, [72.0, 40.0])
    seen = try H.next_request(h)
    Test.eq(bearer(seen), "other")
  end
end

def test_logout_waits_for_a_refresh_and_removes_its_result() -> Result[Void]
  setup = H.Setup(replies: ["codex_refreshed.json@hold"], api: "openai_responses", chatgpt: true)
  H.using(setup) do |h|
    login = H.chatgpt_login(h.fake, h.base)
    try Chatgpt.save(login, TOKENS)
    refreshing = Task.spawn(-> { Chatgpt.renewed(login, TOKENS.access) })
    _ = try H.next_request(h)
    logout = Task.spawn(-> { Chatgpt.remove(login) })
    H.release(h)
    _ = try Task.await(refreshing)
    try Task.await(logout)
    Test.eq(try Chatgpt.load(login), none)
  end
end

def test_cached_usage_is_shared_and_invalidated_by_login_change() -> Result[Void]
  setup = H.Setup(
    replies: ["codex_usage.json", "400:codex_refresh_refused.json"],
    api: "openai_responses",
    chatgpt: true,
  )

  H.using(setup) do |h|
    login = H.chatgpt_login(h.fake, h.base)
    try Chatgpt.save(login, TOKENS)
    try Test.eq((try Chatgpt.cached_usage(login)).map { |window| window.remaining }, [72.0, 40.0])
    try Test.eq((try Chatgpt.cached_usage(login)).map { |window| window.remaining }, [72.0, 40.0])
    _ = try H.next_request(h)
    try Chatgpt.save(login, TOKENS.with(access: "other", account: "other"))
    try Test.assert(not Chatgpt.cached_usage(login).ok?, "a new login must not receive the old quota")
    seen = try H.next_request(h)
    try Test.eq(bearer(seen), "other")
    try Test.assert(not Chatgpt.cached_usage(login).ok?, "a failure is cached too")
    ok()
  end
end

def test_usage_uses_the_login_and_never_returns_credentials() -> Result[Void]
  setup = H.Setup(
    replies: ["codex_usage.json", "400:codex_refresh_refused.json"],
    api: "openai_responses",
    chatgpt: true,
  )

  H.using(setup) do |h|
    login = H.chatgpt_login(h.fake, h.base)
    try Chatgpt.save(login, TOKENS)
    windows = try Chatgpt.usage(login)
    try Test.eq(windows.map { |window| window.remaining }, [72.0, 40.0])
    seen = try H.next_request(h)
    try Test.eq(
      [seen.method, seen.path, bearer(seen), header(seen, "chatgpt-account-id")],
      ["GET", "/wham/usage", "at-secret-1", "acct-1"],
    )

    case Chatgpt.usage(login)
      ok(_) -> return error("expected the usage request to fail")
      error(e) -> try Test.eq(e.message, "the ChatGPT usage request failed (HTTP 400)")
    end

    ok()
  end
end

# A 401 of the usage endpoint is a failed read, kept for a while: it never renews the login, or the refresh token
# would rotate at each read.
def test_a_401_on_usage_never_renews_the_login() -> Result[Void]
  setup = H.Setup(replies: ["401:codex_unauthorized.json"], api: "openai_responses", chatgpt: true)
  H.using(setup) do |h|
    login = H.chatgpt_login(h.fake, h.base)
    try Chatgpt.save(login, TOKENS)
    try Test.assert(not Chatgpt.cached_usage(login).ok?, "the usage was refused")
    try Test.assert(not Chatgpt.cached_usage(login).ok?, "a failure is kept")
    try Test.eq((try H.next_request(h)).path, "/wham/usage")
    try Test.assert(h.fake.seen.empty?, "one request and no refresh")
    Test.eq(try Chatgpt.load(login), some(TOKENS))
  end
end

# A logout does not fail when the refresh lock stays held: it removes the file after the wait.
def test_logout_removes_the_login_when_the_refresh_lock_is_held() -> Result[Void]
  setup = H.Setup(replies: [], api: "openai_responses", chatgpt: true)
  H.using(setup) do |h|
    login = H.chatgpt_login(h.fake, h.base, call_ms: 100, lock_margin_ms: 50)
    try Chatgpt.save(login, TOKENS)
    login.lock.put(Chatgpt.LOCK, "other #{Time.monotonic_ms + 600_000}")
    try Chatgpt.remove(login)
    Test.eq(try Chatgpt.load(login), none)
  end
end

def test_usage_refuses_redirects_and_oversized_replies() -> Result[Void]
  setup = H.Setup(replies: [], api: "openai_responses", chatgpt: true)
  H.using(setup) do |h|
    location = HTTP.Header(name: "Location", value: "#{H.fake_root(h.fake)}/redirect")
    redirect = Fake.Reply(status: 302, headers: [location], body: "".bytes)
    oversized = Fake.Reply(status: 200, body: (" " * 1_048_577).bytes)
    peer = try Fake.start([redirect, oversized])
    result = refused_usage(h, peer)
    try Fake.stop(peer)
    result
  end
end

def refused_usage(h: H.Harness, peer: Fake.Fake) -> Result[Void]
  login = H.chatgpt_login(peer, h.base)
  try Chatgpt.save(login, TOKENS)
  case Chatgpt.usage(login)
    ok(_) -> return error("expected usage to refuse a redirect")
    error(e) -> try Test.eq(e.message, "the ChatGPT usage request failed (HTTP 302)")
  end

  try Test.assert(h.fake.seen.empty?, "the redirect target must not receive any request")
  case Chatgpt.usage(login)
    ok(_) -> error("expected usage to refuse an oversized body")
    error(e) -> Test.eq(e.message, "the ChatGPT usage request failed")
  end
end

# The polls wait the interval and take 403 and 404 as pending. Each 401 of a session refreshes the token the session
# sends, again at its next turn; a session made later takes the file's newer token without a refresh.
def test_a_device_login_stores_the_tokens_and_each_401_refreshes_them() -> Result[Void]
  replies = [
    "codex_usercode.json",
    "403:codex_pending.json",
    "404:codex_pending.json",
    "codex_grant.json",
    "codex_tokens.json",
    "codex_models.json",
    "401:codex_unauthorized.json",
    "codex_refreshed.json",
    "text.sse",
    "401:codex_unauthorized.json",
    "codex_refreshed_again.json",
    "text.sse",
    "401:codex_unauthorized.json",
    "text.sse",
  ]

  setup = H.Setup(replies: replies, api: "openai_responses", chatgpt: true, chatgpt_poll_ms: POLL_MS)
  H.using(setup) do |h|
    path = "#{h.state_dir}/#{Chatgpt.FILE}"
    try Test.eq(try chatgpt_listed(h), "chatgpt  device false")
    started = try Protocol.decode_device_login((try H.post(h, Protocol.auth_path("chatgpt"), "{}")).text)
    try Test.eq([started.user_code, started.url], ["ABCD-1234", "#{H.fake_root(h.fake)}/auth/codex/device"])
    try Test.eq(try waited(h), Protocol.DeviceState(state: "done", message: "", made_default: true))
    try Test.eq(try chatgpt_listed(h), "chatgpt stored device false")
    try Test.eq((try File.stat(path)).mode, 384)
    providers = try Protocol.decode_provider_list((try H.get(h, Protocol.PROVIDERS_PATH)).text)
    codex = providers.providers.select { |p| p.name == "chatgpt" }
    try Test.eq(codex.map { |p| p.models }, [["gpt-test-codex", "gpt-test-mini"]])
    login = try requests(h, 5)
    try Test.eq(
      login.map { |seen| "#{seen.method} #{seen.path}" },
      [
        "POST /auth/api/accounts/deviceauth/usercode",
        "POST /auth/api/accounts/deviceauth/token",
        "POST /auth/api/accounts/deviceauth/token",
        "POST /auth/api/accounts/deviceauth/token",
        "POST /auth/oauth/token",
      ],
    )

    for at in 1...4
      try Test.assert(login[at].at_ms - login[at - 1].at_ms >= POLL_MS, "poll #{at} waited the interval")
    end

    try Test.eq(JSON.parse(login[0].body), JSON.parse("{\"client_id\": \"#{Chatgpt.CLIENT_ID}\"}"))
    try Test.eq(login[1].body.include?("dev-1"), true)
    try Test.eq(login[4].body.include?("code=code-1&redirect_uri="), true)
    try Test.eq(login[4].body.include?("code_verifier=verifier-1"), true)
    models = try H.next_request(h)
    try Test.eq(
      [models.path, bearer(models), header(models, "chatgpt-account-id")],
      ["/codex/models", "at-secret-1", "acct-1"],
    )

    id = try H.new_session_in(h, h.work, none, some("chatgpt"))
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Hi.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    first = try requests(h, 3)
    try Test.eq(
      [first[0].path, bearer(first[0]), header(first[0], "originator")],
      ["/codex/responses", "at-secret-1", "llm-async-codex"],
    )

    body = try JSON.parse(first[0].body)
    try Test.eq(try JSON.get(body, "model"), JSON.from("gpt-test-codex"))
    try Test.eq(JSON.get(body, "max_output_tokens").ok?, false)
    try Test.eq(
      [first[1].path, first[1].body.include?("refresh_token=rt-secret-1").to_s],
      ["/auth/oauth/token", "true"],
    )

    try Test.eq(bearer(first[2]), "at-secret-2")
    _ = try H.send(h, id, "Again.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    second = try requests(h, 3)
    try Test.eq(
      [bearer(second[0]), second[1].body.include?("refresh_token=rt-secret-2").to_s, bearer(second[2])],
      ["at-secret-2", "true", "at-secret-3"],
    )

    later = try H.new_session_in(h, h.work, none, some("chatgpt"))
    b = try H.subscribe(h, later)
    _ = try H.send(h, later, "Hi.")
    b = try H.until(b, Protocol.EventKind.TurnFinished)
    H.close(b)
    third = try requests(h, 2)
    try Test.eq(
      third.map { |seen| "#{seen.path} #{bearer(seen)}" },
      ["/codex/responses at-secret-1", "/codex/responses at-secret-3"],
    )

    fresh = TOKENS.with(access: "at-secret-3", refresh: "rt-secret-3", models: ["gpt-test-codex", "gpt-test-mini"])
    try Test.eq(try Chatgpt.load(H.chatgpt_login(h.fake, h.base)), some(fresh))
    for session in [id, later]
      try Test.eq((try File.read_text(H.session_file(h, session))).include?("secret"), false)
    end

    try Test.eq("#{a.seen.map { |s| s.event }}".include?("secret"), false)
    out = try H.call(h, "DELETE", Protocol.auth_path("chatgpt"), "", H.auth(h))
    try Test.eq([out.status.to_s, File.stat(path).ok?.to_s], ["200", "false"])
    after = try Protocol.decode_provider_list((try H.get(h, Protocol.PROVIDERS_PATH)).text)
    Test.eq(after.providers.any? { |p| p.name == "chatgpt" }, false)
  end
end

# A second start ends the wait of the first; a logout ends a wait; a denied login and one never confirmed fail.
def test_a_device_login_is_replaced_ended_denied_and_expires() -> Result[Void]
  replies = [
    "codex_usercode.json",
    "codex_usercode2.json",
    "codex_grant.json",
    "codex_tokens.json",
    "codex_models.json",
    "codex_usercode.json",
    "codex_usercode.json",
    "400:codex_pending.json",
    "codex_usercode.json",
    "403:codex_pending.json",
    "403:codex_pending.json",
    "403:codex_pending.json",
    "403:codex_pending.json",
    "403:codex_pending.json",
  ]

  setup = H.Setup(
    replies: replies,
    api: "openai_responses",
    chatgpt: true,
    chatgpt_poll_ms: 200,
    chatgpt_device_ms: 500,
  )

  H.using(setup) do |h|
    _ = try H.post(h, Protocol.auth_path("chatgpt"), "{}")
    again = try Protocol.decode_device_login((try H.post(h, Protocol.auth_path("chatgpt"), "{}")).text)
    try Test.eq(again.user_code, "EFGH-5678")
    try Test.eq((try waited(h)).state, "done")
    replaced = try requests(h, 5)
    try Test.eq(
      replaced.map { |seen| seen.path.split("/").last },
      ["usercode", "usercode", "token", "token", "models"],
    )

    try Test.eq(replaced[2].body.include?("dev-2"), true)
    _ = try H.post(h, Protocol.auth_path("chatgpt"), "{}")
    out = try H.call(h, "DELETE", Protocol.auth_path("chatgpt"), "", H.auth(h))
    try Test.eq(out.status, 200)
    try Test.eq(try waited(h), Protocol.DeviceState(state: "none", message: ""))
    try Test.eq(File.stat("#{h.state_dir}/#{Chatgpt.FILE}").ok?, false)
    _ = try H.post(h, Protocol.auth_path("chatgpt"), "{}")
    try Test.eq(try waited(h), Protocol.DeviceState(state: "failed", message: "the ChatGPT login failed (HTTP 400)"))
    ended = try requests(h, 3)
    try Test.eq(ended.map { |seen| seen.path.split("/").last }, ["usercode", "usercode", "token"])
    _ = try H.post(h, Protocol.auth_path("chatgpt"), "{}")
    expired = try waited(h)
    Test.eq(expired, Protocol.DeviceState(state: "failed", message: "the ChatGPT login was not confirmed in time"))
  end
end

# A refresh that fails says only the status, also when the server quotes the token; a session whose token another
# session already refreshed takes the file's tokens without a call; a file others may read, or a link, is not used.
def test_a_refresh_keeps_the_tokens_out_of_errors_and_takes_a_newer_file() -> Result[Void]
  setup = H.Setup(replies: ["400:codex_refresh_refused.json"], api: "openai_responses", chatgpt: true)
  H.using(setup) do |h|
    login = H.chatgpt_login(h.fake, h.base)
    try Chatgpt.save(login, TOKENS)
    case Chatgpt.renewed(login, TOKENS.access)
      ok(_) -> return error("expected the refresh to fail")
      error(e) ->
        try Test.eq(e.message, "the ChatGPT token was not refreshed (HTTP 400)")
        try Test.eq("#{e}".include?("secret"), false)
    end

    try Test.eq((try H.next_request(h)).body.include?("refresh_token=rt-secret-1"), true)
    newer = TOKENS.with(access: "at-secret-2", refresh: "rt-secret-2")
    try Chatgpt.save(login, newer)
    try Test.eq(try Chatgpt.renewed(login, TOKENS.access), newer)
    try Test.eq(h.fake.seen.empty?, true)
    try Test.eq(try H.run("chmod", ["644", login.path]), 0)
    case Chatgpt.load(login)
      ok(_) -> return error("expected a refusal")
      error(e) ->
        try Test.eq([e.message.include?("may be read by others"), e.message.include?("secret")], [true, false])
    end

    other = "#{h.base}/other.json"
    try File.write_text(other, "{}")
    try Test.eq(try H.run("chmod", ["600", other]), 0)
    try Test.eq(try H.run("rm", [login.path]), 0)
    try Test.eq(try H.run("ln", ["-s", other, login.path]), 0)
    try Test.eq(Chatgpt.load(login).ok?, false)
    try Test.eq(Chatgpt.save(login, newer).ok?, false)
    Test.eq(File.read_text(other), ok("{}"))
  end
end

# A refresh cancelled while the server does not answer gives the lock back within its hold (one call and a second).
def test_a_cancelled_refresh_does_not_keep_the_lock() -> Result[Void]
  replies = ["codex_refreshed.json@hold", "codex_refreshed.json"]
  setup = H.Setup(replies: replies, api: "openai_responses", chatgpt: true)
  H.using(setup) do |h|
    login = H.chatgpt_login(h.fake, h.base, call_ms: 300)
    try Chatgpt.save(login, TOKENS)
    stuck = Task.spawn(-> { Chatgpt.renewed(login, TOKENS.access) })
    _ = try H.next_request(h)
    Task.cancel(stuck)
    start = Time.monotonic_ms
    fresh = try Chatgpt.renewed(login, TOKENS.access)
    took = Time.monotonic_ms - start
    H.release(h)
    try Test.eq(fresh.access, "at-secret-2")
    Test.assert(took < 2000, "the second refresh waited #{took} ms")
  end
end

# Of many refreshes that find a stale lock (its holder was cancelled), one takes it over and calls; the others wait,
# then take the tokens it saved. Done a few times, so a race shows.
def test_a_stale_lock_is_taken_over_once() -> Result[Void]
  rounds = 4
  waiters = 8
  replies = (0...rounds).to_a.map { |_| "codex_refreshed.json" }
  setup = H.Setup(replies: replies, api: "openai_responses", chatgpt: true)
  H.using(setup) do |h|
    login = H.chatgpt_login(h.fake, h.base, call_ms: 300)
    for round in 0...rounds
      try Chatgpt.save(login, TOKENS)
      login.lock.put(Chatgpt.LOCK, "gone #{round}")
      tasks = (0...waiters).to_a.map { |_| Task.spawn(-> { Chatgpt.renewed(login, TOKENS.access) }) }
      for task in tasks
        try Test.eq((try Task.await(task)).access, "at-secret-2")
      end

      _ = try H.next_request(h)
      try Test.eq(["round #{round}", h.fake.seen.empty?.to_s], ["round #{round}", "true"])
    end

    ok()
  end
end

# A holder that is still within its time keeps the lock: a second refresh waits for it, then takes its tokens.
def test_a_live_holder_keeps_the_lock() -> Result[Void]
  setup = H.Setup(replies: ["codex_refreshed.json@400"], api: "openai_responses", chatgpt: true)
  H.using(setup) do |h|
    login = H.chatgpt_login(h.fake, h.base, call_ms: 1000)
    try Chatgpt.save(login, TOKENS)
    first = Task.spawn(-> { Chatgpt.renewed(login, TOKENS.access) })
    _ = try H.next_request(h)
    second = try Chatgpt.renewed(login, TOKENS.access)
    try Test.eq([(try Task.await(first)).access, second.access], ["at-secret-2", "at-secret-2"])
    Test.eq(h.fake.seen.empty?, true)
  end
end

# A server whose provider is `chatgpt` starts on the first model Codex listed; the endpoints are https, or on this
# machine.
def test_the_chatgpt_provider_brings_its_model_and_its_urls_are_checked() -> Result[Void]
  setup = H.Setup(replies: [], api: "openai_responses", chatgpt: true)
  H.using(setup) do |h|
    login = H.chatgpt_login(h.fake, h.base)
    try Chatgpt.save(login, TOKENS.with(models: ["gpt-test-codex", "gpt-test-mini"]))
    env = {
      "FINN_STATE_DIR": h.state_dir,
      "FINN_DATA_DIR": h.data_dir,
      "XDG_CONFIG_HOME": "#{h.base}/config",
      "FINN_PROVIDER": "chatgpt",
    }

    options = try Config.from_env_with(->(n) { env.get(n).to_result("not set") }, &no_ant)
    try Test.eq([options.provider, options.model], ["chatgpt", "gpt-test-codex"])
    local = env.put("FINN_CHATGPT_URL", "http://127.0.0.1:9/codex")
    try Test.eq(Config.from_env_with(->(n) { local.get(n).to_result("not set") }, &no_ant).ok?, true)
    plain = env.put("FINN_CHATGPT_AUTH_URL", "http://auth.example")
    case Config.from_env_with(->(n) { plain.get(n).to_result("not set") }, &no_ant)
      ok(_) -> error("expected a refusal")
      error(e) -> Test.eq(e.message.include?("FINN_CHATGPT_AUTH_URL"), true)
    end
  end
end

private

# How the logins list ChatGPT: a device login, `stored` once signed in.
def chatgpt_listed(h: H.Harness) -> Result[String]
  listed = try Protocol.decode_login_list((try H.get(h, Protocol.AUTH_PATH)).text)
  ok(
    listed.providers
      .select { |p| p.name == "chatgpt" }
      .map { |p| "#{p.name} #{p.from} #{p.asks} #{p.coming}" }
      .join(","),
  )
end

# The state of the device login once it is no longer waiting.
def waited(h: H.Harness) -> Result[Protocol.DeviceState]
  deadline = Time.monotonic_ms + H.WAIT_MS
  while Time.monotonic_ms < deadline
    state = try Protocol.decode_device_state((try H.get(h, Protocol.auth_path("chatgpt"))).text)
    return ok(state) if state.state != "waiting"

    Task.sleep(20)
  end

  error("the device login did not end")
end

def requests(h: H.Harness, count: Int) -> Result[List[Fake.Seen]]
  out: List[Fake.Seen] = []
  for _ in 0...count
    out = out.push(try H.next_request(h))
  end

  ok(out)
end

def no_ant() -> Result[String] = error("no ant")

def bearer(seen: Fake.Seen) -> String = header(seen, "authorization").replace("Bearer ", "")

def header(seen: Fake.Seen, name: String) -> String
  seen.headers.select { |x| x.name.downcase == name }.map { |x| x.value }.join(",")
end

# The interval of the device code is seconds, a number or text, kept from 1 to 60; a missing or unreadable one is 5.
def test_the_interval_of_a_device_code_is_read_as_a_number_or_text_and_clamped() -> Result[Void]
  head = "{\"device_auth_id\": \"d\", \"user_code\": \"U\""
  rows = [
    ["", "5"],
    [", \"interval\": 7", "7"],
    [", \"interval\": \"5\"", "5"],
    [", \"interval\": \"abc\"", "5"],
    [", \"interval\": -3", "1"],
    [", \"interval\": \"0\"", "1"],
    [", \"interval\": 99999999999", "60"],
    [", \"interval\": 99999999999999999999", "5"],
  ]

  for row in rows
    code = try Chatgpt.usercode("#{head}#{row[0]}}")
    try Test.eq("#{code.interval}", row[1])
  end

  Test.error?(Chatgpt.usercode("{\"user_code\": \"U\"}"))
end
