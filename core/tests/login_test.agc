# Logins: a key is checked at the provider's own `GET /models`, stored in a file only its user can read, and offers the
# provider from then on, also after a restart; a logout takes it back. The key goes to no session file, event
# or answer.

import Protocol from "pkg/protocol/protocol"
import Auth from "../src/config/auth"
import Fake from "support/fake_llm"
import H from "support/harness"

def test_a_login_checks_the_key_stores_it_privately_and_offers_the_provider() -> Result[Void]
  replies = ["401:bad_request.json", "models_small.json", "text.sse"]
  setup = H.Setup(replies: replies, logins: ["paid"])
  H.using(setup) do |h|
    listed = try Protocol.decode_login_list((try H.get(h, Protocol.AUTH_PATH)).text)
    try Test.eq(
      listed.providers.map { |p| "#{p.name} #{p.from} #{p.coming}" },
      ["paid  false", "claude  true", "chatgpt  true"],
    )

    try Test.eq(listed.first, true)
    wrong = try login(h, "paid", "sk-wrong")
    try Test.eq(
      [wrong.status.to_s, (try Protocol.decode_failure(wrong.text)).kind],
      ["400", Protocol.KIND_LOGIN_REJECTED],
    )

    try Test.eq(File.stat(H.auth_file(h.base)).ok?, false)
    try Test.eq((try offered(h)).include?("paid"), false)
    right = try login(h, "paid", "sk-right")
    try Test.eq(right.status, 200)
    try Test.eq((try Protocol.decode_login_status(right.text)).from, "stored")
    try Test.eq((try File.stat(H.auth_file(h.base))).mode, 384)
    try Test.eq(try Dir.list("#{h.base}/config/finn"), [Auth.FILE])
    try Test.eq((try offered(h)).include?("paid"), true)
    checks = [try H.next_request(h), try H.next_request(h)]
    try Test.eq(
      checks.map { |c| "#{c.method} #{c.path} #{bearer(c)}" },
      ["GET /paid/models sk-wrong", "GET /paid/models sk-right"],
    )

    id = try H.new_session_in(h, h.work, none, some("paid"))
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Hi.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    turn = try H.next_request(h)
    try Test.eq([turn.path, bearer(turn)], ["/paid/chat/completions", "sk-right"])
    try Test.eq((try File.read_text(H.session_file(h, id))).include?("sk-right"), false)
    try Test.eq("#{a.seen.map { |s| s.event }}".include?("sk-right"), false)
    H.restarted(h, setup, "") do |r|
      again = try Protocol.decode_login_list((try H.get(r, Protocol.AUTH_PATH)).text)
      try Test.eq([again.providers[0].from, again.first.to_s], ["stored", "false"])
      try Test.eq((try offered(r)).include?("paid"), true)
      out = try H.call(r, "DELETE", Protocol.auth_path("paid"), "", H.auth(r))
      try Test.eq(out.status, 200)
      try Test.eq((try offered(r)).include?("paid"), false)
      Test.eq(File.read_text(H.auth_file(r.base)), ok("{\"keys\":{}}"))
    end
  end
end

# A key file that others may read is not used, and a login does not write to it; a key in the environment wins.
def test_an_open_key_file_is_refused_and_the_environment_wins() -> Result[Void]
  setup = H.Setup(replies: [], logins: ["paid", "envy=OPENAI_API_KEY"])
  H.using(setup) do |h|
    try Dir.mkdir("#{h.base}/config/finn")
    try File.write_text(H.auth_file(h.base), "{\"keys\": {\"paid\": \"sk-old\"}}")
    try chmod("644", H.auth_file(h.base))
    H.restarted(h, setup, "") do |r|
      listed = try Protocol.decode_login_list((try H.get(r, Protocol.AUTH_PATH)).text)
      try Test.eq(listed.providers.take(2).map { |p| "#{p.name} #{p.from}" }, ["paid ", "envy env"])
      try Test.eq(listed.first, false)
      try Test.eq((try offered(r)).include?("paid"), false)
      refused = try login(r, "paid", "sk-new")
      try Test.eq(
        [refused.status.to_s, (try Protocol.decode_failure(refused.text)).kind],
        ["500", Protocol.KIND_LOGIN_STORAGE],
      )

      Test.eq(File.read_text(H.auth_file(r.base)), ok("{\"keys\": {\"paid\": \"sk-old\"}}"))
    end
  end
end

# The check goes to the provider's base URL only: a redirect is not followed with the key, and nothing is stored.
def test_a_redirect_at_the_check_is_not_followed() -> Result[Void]
  H.using(H.Setup(replies: ["302>/stolen"], logins: ["paid"])) do |h|
    moved = try login(h, "paid", "sk-right")
    try Test.eq(
      [moved.status.to_s, (try Protocol.decode_failure(moved.text)).kind],
      ["400", Protocol.KIND_LOGIN_REJECTED],
    )

    try Test.eq((try H.next_request(h)).path, "/paid/models")
    try Test.error?(h.fake.seen.recv(200))
    Test.eq(File.stat(H.auth_file(h.base)).ok?, false)
  end
end

def login(h: H.Harness, name: String, key: String) -> Result[H.Answer]
  H.post(h, Protocol.auth_path(name), Protocol.encode_login(Protocol.Login(key: key)))
end

def offered(h: H.Harness) -> Result[List[String]]
  ok((try Protocol.decode_provider_list((try H.get(h, Protocol.PROVIDERS_PATH)).text)).providers.map { |p| p.name })
end

def bearer(seen: Fake.Seen) -> String
  seen.headers.select { |x| x.name.downcase == "authorization" }.map { |x| x.value.replace("Bearer ", "") }.join(",")
end

def chmod(mode: String, path: String) -> Result[Void]
  code = try H.run("chmod", [mode, path])
  return error("chmod failed") if code != 0

  ok()
end
