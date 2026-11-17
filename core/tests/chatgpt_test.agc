# The ChatGPT login: a device login against a fake OAuth server and a fake Codex, its tokens in a private file of the
# state folder, the turns of a `chatgpt` session with them, a refresh after a 401, and a logout. No token goes to an
# event, a session file or an error.

import Protocol from "pkg/protocol/protocol"
import Chatgpt from "../src/providers/chatgpt"
import Fake from "support/fake_llm"
import H from "support/harness"

TOKENS = Chatgpt.Tokens(access: "at-secret-1", refresh: "rt-secret-1", account: "acct-1", models: ["gpt-test-codex"])

def test_a_device_login_stores_the_tokens_and_a_401_refreshes_them() -> Result[Void]
  replies = [
    "codex_usercode.json",
    "403:codex_pending.json",
    "codex_grant.json",
    "codex_tokens.json",
    "codex_models.json",
    "401:codex_unauthorized.json",
    "codex_refreshed.json",
    "text.sse",
  ]

  setup = H.Setup(replies: replies, api: "openai_responses", chatgpt: true)
  H.using(setup) do |h|
    path = "#{h.state_dir}/#{Chatgpt.FILE}"
    started = try Protocol.decode_device_login((try H.post(h, Protocol.auth_path("chatgpt"), "{}")).text)
    try Test.eq([started.user_code, started.url], ["ABCD-1234", "#{H.fake_root(h.fake)}/auth/codex/device"])
    try Test.eq(try waited(h), Protocol.DeviceState(state: "done", message: ""))
    try Test.eq((try File.stat(path)).mode, 384)
    providers = try Protocol.decode_provider_list((try H.get(h, Protocol.PROVIDERS_PATH)).text)
    codex = providers.providers.select { |p| p.name == "chatgpt" }
    try Test.eq(codex.map { |p| p.models }, [["gpt-test-codex", "gpt-test-mini"]])
    login = [try H.next_request(h), try H.next_request(h), try H.next_request(h), try H.next_request(h)]
    try Test.eq(
      login.map { |seen| "#{seen.method} #{seen.path}" },
      [
        "POST /auth/api/accounts/deviceauth/usercode",
        "POST /auth/api/accounts/deviceauth/token",
        "POST /auth/api/accounts/deviceauth/token",
        "POST /auth/oauth/token",
      ],
    )

    try Test.eq(JSON.parse(login[0].body), JSON.parse("{\"client_id\": \"#{Chatgpt.CLIENT_ID}\"}"))
    try Test.eq(login[3].body.include?("code=code-1&redirect_uri="), true)
    try Test.eq(login[3].body.include?("code_verifier=verifier-1"), true)
    models = try H.next_request(h)
    try Test.eq(
      [models.path, bearer(models), header(models, "chatgpt-account-id")],
      ["/codex/models", "at-secret-1", "acct-1"],
    )

    id = try H.new_session_in(h, h.work, none, some("chatgpt"))
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Hi.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    refused = try H.next_request(h)
    refresh = try H.next_request(h)
    turn = try H.next_request(h)
    try Test.eq(
      [refused.path, bearer(refused), header(refused, "originator")],
      ["/codex/responses", "at-secret-1", "llm-async-codex"],
    )

    body = try JSON.parse(refused.body)
    try Test.eq([JSON.get(body, "model").ok?, JSON.get(body, "max_output_tokens").ok?], [true, false])
    try Test.eq(try JSON.get(body, "model"), JSON.from("gpt-test-codex"))
    try Test.eq([refresh.path, refresh.body.include?("refresh_token=rt-secret-1").to_s], ["/auth/oauth/token", "true"])
    try Test.eq([turn.path, bearer(turn)], ["/codex/responses", "at-secret-2"])
    fresh = TOKENS.with(access: "at-secret-2", refresh: "rt-secret-2", models: ["gpt-test-codex", "gpt-test-mini"])
    try Test.eq(try Chatgpt.load(H.chatgpt_login(h.fake, h.base)), some(fresh))

    try Test.eq((try File.read_text(H.session_file(h, id))).include?("secret"), false)
    try Test.eq("#{a.seen.map { |s| s.event }}".include?("secret"), false)
    out = try H.call(h, "DELETE", Protocol.auth_path("chatgpt"), "", H.auth(h))
    try Test.eq([out.status.to_s, File.stat(path).ok?.to_s], ["200", "false"])
    after = try Protocol.decode_provider_list((try H.get(h, Protocol.PROVIDERS_PATH)).text)
    Test.eq(after.providers.any? { |p| p.name == "chatgpt" }, false)
  end
end

# A refresh that fails says only the status, also when the server quotes the token; a session whose token another
# session already refreshed takes the file's tokens without a call; a file others may read is not used.
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
      ok(_) -> error("expected a refusal")
      error(e) -> Test.eq([e.message.include?("may be read by others"), e.message.include?("secret")], [true, false])
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

def bearer(seen: Fake.Seen) -> String = header(seen, "authorization").replace("Bearer ", "")

def header(seen: Fake.Seen, name: String) -> String
  seen.headers.select { |x| x.name.downcase == name }.map { |x| x.value }.join(",")
end
