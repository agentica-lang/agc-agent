# The ChatGPT login: a device login against a fake OAuth server and a fake Codex, its tokens in a private file of the
# state folder, the turns of a `chatgpt` session with them, a refresh after each 401, and a logout. No token goes to an
# event, a session file or an error.

import Protocol from "pkg/protocol/protocol"
import Chatgpt from "../src/providers/chatgpt"
import Config from "../src/config/config"
import Fake from "support/fake_llm"
import H from "support/harness"

TOKENS = Chatgpt.Tokens(access: "at-secret-1", refresh: "rt-secret-1", account: "acct-1", models: ["gpt-test-codex"])
POLL_MS = 150

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
    started = try Protocol.decode_device_login((try H.post(h, Protocol.auth_path("chatgpt"), "{}")).text)
    try Test.eq([started.user_code, started.url], ["ABCD-1234", "#{H.fake_root(h.fake)}/auth/codex/device"])
    try Test.eq(try waited(h), Protocol.DeviceState(state: "done", message: ""))
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
