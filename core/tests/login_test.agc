# Logins: a key is checked at the provider's own `GET /models`, stored in a file only its user can read, and offers the
# provider from then on, also after a restart; a logout takes it back. The key goes to no session file, event
# or answer.

import Protocol from "pkg/protocol/protocol"
import Auth from "../src/providers/auth"
import Config from "../src/config/config"
import Logins from "../src/providers/logins"
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
    try Test.eq((try H.call(h, "PUT", Protocol.AUTH_PATH, "", H.auth(h))).status, 200)
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

# A local server's login gives its base URL, no key: it is checked with `GET /models` there, stored, and `local` goes
# there from then on, also after a restart; a logout takes it back.
def test_a_local_login_stores_the_base_url_and_moves_local_there() -> Result[Void]
  replies = ["404:bad_request.json", "models_small.json", "text.sse"]
  setup = H.Setup(replies: replies, local_login: true)
  H.using(setup) do |h|
    root = H.fake_root(h.fake)
    listed = try Protocol.decode_login_list((try H.get(h, Protocol.AUTH_PATH)).text)
    local = listed.providers[0]
    try Test.eq([local.name, local.asks, local.base_url, local.from], ["local", "url", h.fake.url, ""])
    try Test.eq(error_kind_of(try login_url(h, "local", "ftp://box/v1")), Protocol.KIND_INVALID)
    try Test.eq(error_kind_of(try login(h, "local", "sk-1")), Protocol.KIND_INVALID)
    try Test.eq(error_kind_of(try login_url(h, "local", "#{root}/none/v1")), Protocol.KIND_LOGIN_REJECTED)
    try Test.eq(File.stat(H.auth_file(h.base)).ok?, false)
    right = try login_url(h, "local", "#{root}/llama/v1/")
    try Test.eq(right.status, 200)
    status = try Protocol.decode_login_status(right.text)
    try Test.eq([status.from, status.base_url], ["stored", "#{root}/llama/v1"])
    checks = [try H.next_request(h), try H.next_request(h)]
    try Test.eq(
      checks.map { |c| "#{c.method} #{c.path} #{bearer(c)}" },
      ["GET /none/v1/models ", "GET /llama/v1/models "],
    )

    id = try H.new_session_in(h, h.work, none, some("local"))
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Hi.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq((try H.next_request(h)).path, "/llama/v1/chat/completions")
    H.restarted(h, setup, "") do |r|
      again = try Protocol.decode_login_list((try H.get(r, Protocol.AUTH_PATH)).text)
      try Test.eq([again.providers[0].from, again.providers[0].base_url], ["stored", "#{root}/llama/v1"])
      try Test.eq((try H.call(r, "DELETE", Protocol.auth_path("local"), "", H.auth(r))).status, 200)
      after = try Protocol.decode_login_list((try H.get(r, Protocol.AUTH_PATH)).text)
      try Test.eq([after.providers[0].from, after.providers[0].base_url], ["", r.fake.url])
      Test.eq(File.read_text(H.auth_file(r.base)), ok("{\"keys\":{}}"))
    end
  end
end

# On the real setup a stored base URL serves `local` after a start, and FINN_BASE_URL wins over it.
def test_finn_base_url_wins_over_a_stored_base_url() -> Result[Void]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/core-local-#{Random.int(0, 999999999)}"
  result = stored_url(dir)
  _ = Path.remove(dir)
  result
end

def stored_url(dir: String) -> Result[Void]
  try Dir.mkdir(dir)
  try Auth.create("#{dir}/finn/#{Auth.FILE}", {}, {"local": "http://127.0.0.1:9/v1"})
  no_ant = -> {
    failed: Result[String] = error("no ant")
    failed
  }

  env = {"XDG_CONFIG_HOME": dir}
  options = try Config.from_env_with(->(n) { from(env, n) }, no_ant)
  try Test.eq(options.props_url, "http://127.0.0.1:9/props")
  try Test.eq(local_of(options), ["stored", "http://127.0.0.1:9/v1"])
  set = env.put("FINN_BASE_URL", "http://127.0.0.1:7/v1")
  chosen = try Config.from_env_with(->(n) { from(set, n) }, no_ant)
  try Test.eq(chosen.props_url, "http://127.0.0.1:7/props")
  Test.eq(local_of(chosen), ["env", "http://127.0.0.1:7/v1"])
end

def local_of(options: Config.Options) -> List[String]
  holder = Logins.start(options.providers, options.login)
  listed = Logins.list(holder)
  Logins.stop(holder)
  found = listed.unwrap_or(Logins.Listing(providers: [], first: false)).providers.select { |p| p.name == "local" }
  found.flat_map { |p| [p.from, p.base_url] }
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

# The check goes to the provider's base URL only: a redirect is not followed with the key, and nothing is stored. A
# skipped first login makes the empty key file (and leaves one that is there, as above).
def test_a_redirect_at_the_check_is_not_followed() -> Result[Void]
  H.using(H.Setup(replies: ["302>/stolen"], logins: ["paid"])) do |h|
    moved = try login(h, "paid", "sk-right")
    try Test.eq(
      [moved.status.to_s, (try Protocol.decode_failure(moved.text)).kind],
      ["400", Protocol.KIND_LOGIN_REJECTED],
    )

    try Test.eq((try H.next_request(h)).path, "/paid/models")
    try Test.error?(h.fake.seen.recv(200))
    try Test.eq(File.stat(H.auth_file(h.base)).ok?, false)
    try Test.eq((try H.call(h, "PUT", Protocol.AUTH_PATH, "", H.auth(h))).status, 200)
    Test.eq(File.read_text(H.auth_file(h.base)), ok("{\"keys\":{}}"))
  end
end

# The real setup of `Config.from_env_with`: on a server of the Anthropic API whose token comes from `ant`, a
# login and a logout build the providers without `ant` (which fails or hangs after the start here); each change
# reads the key file again, so a key another process stored stays; a file opened to others since the start takes
# no key; Anthropic takes a key too, and its token variable wins over a stored key. A config entry that replaces
# the `openrouter` preset keeps its check path. The create of a skip never writes over a file that is there.
def test_a_login_on_the_real_setup_never_runs_ant_and_keeps_other_keys() -> Result[Void]
  fake = try Fake.start([
    try Fake.json(200, "openai_chat/models_small.json"),
    try Fake.json(200, "anthropic/models.json"),
  ])

  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/core-logins-#{Random.int(0, 999999999)}"
  try Dir.mkdir("#{dir}/finn")
  box = "{\"name\": \"openrouter\", \"base_url\": \"#{fake.url}\", \"key_env\": \"BOX_KEY\"}"
  try File.write_text("#{dir}/finn/config.json", "{\"providers\": [#{box}]}")
  env = {"FINN_API": "anthropic", "ANTHROPIC_BASE_URL": fake.url, "XDG_CONFIG_HOME": dir}
  result = on_real_setup(fake, dir, env)
  try Fake.stop(fake)
  _ = Path.remove(dir)
  result
end

def on_real_setup(fake: Fake.Fake, dir: String, env: Map[String, String]) -> Result[Void]
  calls: Channel[Int] = Channel.new(1)
  try calls.send(0, 0)
  gate: Channel[Bool] = Channel.new(1)
  ant = -> {
    count = calls.recv(1000).unwrap_or(0) + 1
    _ = calls.send(count, 0)
    return ok("tok") if count == 1

    # A later call would hang, then fail: none comes.
    _ = gate.recv(6000)
    error("ant failed")
  }

  options = try Config.from_env_with(->(n) { from(env, n) }, ant)
  holder = Logins.start(options.providers, options.login)
  file = "#{dir}/finn/#{Auth.FILE}"
  try Logins.login(holder, "openrouter", "sk-box")
  try Test.eq((try Logins.providers(holder)).has_key?("openrouter"), true)
  try File.write_text(file, "{\"keys\": {\"openrouter\": \"sk-box\", \"else\": \"sk-else\"}}")
  try Logins.login(holder, "anthropic", "sk-claude")
  try Test.eq((try File.read_text(file)).include?("sk-else"), true)
  try Logins.logout(holder, some("openrouter"))
  try Test.eq((try Logins.providers(holder)).has_key?("openrouter"), false)
  try chmod("644", file)
  try Test.eq(error_kind(Logins.logout(holder, some("anthropic"))), Protocol.KIND_LOGIN_STORAGE)
  try Test.eq((try File.read_text(file)).include?("sk-claude"), true)
  try Test.eq(error_kind(Auth.create(file, {})), "io.exists")
  try Test.eq((try File.read_text(file)).include?("sk-claude"), true)
  seen = [try Fake.next_request(fake), try Fake.next_request(fake)]
  try Test.eq(seen.map { |s| s.path }, ["/v1/key", "/v1/models"])
  Logins.stop(holder)
  try Test.eq(calls.recv(1000), ok(1))
  try calls.send(1, 0)
  token = try Config.from_env_with(->(n) { from(env.put("ANTHROPIC_AUTH_TOKEN", "t"), n) }, ant)
  other = Logins.start(token.providers, token.login)
  listed = Logins.list(other)
  Logins.stop(other)
  Test.eq((try listed).providers.select { |p| p.name == "anthropic" }.map { |p| p.from }, ["env"])
end

def from(env: Map[String, String], name: String) -> Result[String]
  return ok("/tmp/core-logins-state") if name == "FINN_STATE_DIR"
  return ok("/tmp/core-logins-data") if name == "FINN_DATA_DIR"

  env.get(name).to_result("not set")
end

def error_kind(result: Result[Void]) -> String
  case result
    ok(_) -> "ok"
    error(e) -> e.kind
  end
end

def login(h: H.Harness, name: String, key: String) -> Result[H.Answer]
  H.post(h, Protocol.auth_path(name), Protocol.encode_login(Protocol.Login(key: key)))
end

def login_url(h: H.Harness, name: String, url: String) -> Result[H.Answer]
  H.post(h, Protocol.auth_path(name), Protocol.encode_login_url(Protocol.LoginUrl(base_url: url)))
end

def error_kind_of(answer: H.Answer) -> String
  return "ok" if answer.status < 400

  case Protocol.decode_failure(answer.text)
    ok(failure) -> failure.kind
    error(_) -> ""
  end
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
