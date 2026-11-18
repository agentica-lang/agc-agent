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
    try Test.eq(listed.providers.map { |p| "#{p.name} #{p.from} #{p.coming}" }, ["paid  false", "claude  true"])

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

# New sessions start on the provider and model last picked: a login makes its provider the choice (with the provider's
# own model), `/model` (an update) replaces it, `FINN_PROVIDER` wins over it, and it stays after a restart; a
# choice that
# is not offered any more is skipped with a note.
def test_a_new_session_uses_the_provider_logged_in_and_the_last_model_picked() -> Result[Void]
  setup = H.Setup(replies: ["models_small.json"], logins: ["paid"], providers: ["other"])
  H.using(setup) do |h|
    before = try H.new_session(h)
    try Test.eq((try H.session(h, before)).provider, "local")
    try Test.eq((try login(h, "paid", "sk-right")).status, 200)
    first = try H.new_session(h)
    try Test.eq((try H.session(h, first)).provider, "paid")
    try Test.eq(File.stat(H.choice_file(h.base)).ok?, true)
    update = Protocol.encode_update_session(Protocol.UpdateSession(provider: some("other"), model: some("m1")))
    try Test.eq((try H.call(h, "PATCH", Protocol.session_path(first), update, H.auth(h))).status, 200)
    picked = try H.session(h, try H.new_session(h))
    try Test.eq([picked.provider, picked.model], ["other", "m1"])
    H.restarted(h, setup, "") do |r|
      again = try H.session(r, try H.new_session(r))
      Test.eq([again.provider, again.model], ["other", "m1"])
    end
  end
end

def test_a_provider_set_by_the_environment_wins_over_the_last_choice() -> Result[Void]
  setup = H.Setup(replies: ["models_small.json"], logins: ["paid"], providers: ["other"])
  H.using(setup) do |h|
    try Test.eq((try login(h, "paid", "sk-right")).status, 200)
    try Test.eq((try H.session(h, try H.new_session(h))).provider, "paid")
    pinned = setup.with(provider: "other")
    H.restarted(h, pinned, "") do |r| Test.eq((try H.session(r, try H.new_session(r))).provider, "other") end
  end
end

# A login of a provider that is not the server's default says so, and a login of the first one made it the default.
def test_a_login_says_whether_it_made_the_provider_the_default() -> Result[Void]
  setup = H.Setup(replies: ["models_small.json", "models_small.json"], logins: ["paid", "second"])
  H.using(setup) do |h|
    one = try Protocol.decode_login_status((try login(h, "paid", "sk-1")).text)
    two = try Protocol.decode_login_status((try login(h, "second", "sk-2")).text)
    try Test.eq([one.made_default, two.made_default], [true, false])
    Test.eq((try H.session(h, try H.new_session(h))).provider, "paid")
  end
end

# The choice file is read at the start; a choice whose provider is not offered any more is dropped with one note.
def test_a_last_choice_of_a_provider_that_is_not_offered_is_dropped_with_a_note() -> Result[Void]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/core-choice-#{Random.int(0, 999999999)}"
  try Dir.mkdir(dir)
  try File.write_text("#{dir}/#{Config.CHOICE_FILE}", "{\"provider\":\"ghost\",\"model\":\"m\"}")
  env = {"FINN_STATE_DIR": dir, "FINN_DATA_DIR": dir, "HOME": dir}
  never = -> { ok("tok") }
  options = try Config.from_env_with(->(n) { env.get(n).to_result("not set") }, never)
  _ = Path.remove(dir)
  try Test.eq(options.login.map { |l| l.choice.none? }, some(true))
  Test.eq(options.warnings.select { |w| w.include?("ghost") }.size, 1)
end

# A refusal on `local`, which a session gets when no provider was picked, says what to do; another provider's does not.
def test_a_refusal_of_the_local_provider_says_to_pick_a_provider() -> Result[Void]
  setup = H.Setup(replies: ["401:bad_request.json", "401:bad_request.json"], providers: ["other"])
  H.using(setup) do |h|
    texts: List[String] = []
    providers: List[Optional[String]] = [none, some("other")]
    for provider in providers
      id = try H.new_session_in(h, h.work, none, provider)
      a = try H.subscribe(h, id)
      _ = try H.send(h, id, "Hi.")
      a = try H.until(a, Protocol.EventKind.Error)
      H.close(a)
      texts = texts.push("#{a.seen.map { |s| s.event }}")
    end

    try Test.eq(
      texts[0].include?("the local provider refused the request (HTTP 401): pick a provider with /model"),
      true,
    )

    Test.eq(texts[1].include?("the local provider"), false)
  end
end

# A local server's login gives its base URL, no key: a URL with a user, a query, a fragment, a space or no host is
# refused and never said back; the URL is checked with `GET /models` there (with `FINN_API_KEY`), stored next to the
# keys, and `local` (its turns and its `/props`) goes there from then on, also after a restart; a logout takes it back.
def test_a_local_login_stores_the_base_url_and_moves_local_there() -> Result[Void]
  replies = ["404:bad_request.json", "models_small.json", "models_small.json", "props_small.json", "text.sse"]
  setup = H.Setup(replies: replies, logins: ["paid"], local_login: true, context_window: 0)
  H.using(setup) do |h|
    root = H.fake_root(h.fake)
    listed = try Protocol.decode_login_list((try H.get(h, Protocol.AUTH_PATH)).text)
    local = listed.providers[0]
    try Test.eq([local.name, local.asks, local.base_url, local.from], ["local", Protocol.ASKS_URL, h.fake.url, ""])
    bad = [
      "ftp://box/v1",
      "http://user:pw-9@box/v1",
      "http://box/v1?pw-9",
      "http://box/v1#pw-9",
      "http://box/pw 9",
      "http://box/v1\npw-9",
      "http:///v1",
      "http://:80/v1",
      "box/v1",
      "http://box/v1#{String.from_code(0x85)}pw-9",
      "http://box/#{String.from_code(0x202E)}pw-9",
      "http://box/#{String.from_code(0x2067)}pw-9",
    ]

    for url in bad
      answer = try login_url(h, "local", url)
      try Test.eq([url, error_kind_of(answer)], [url, Protocol.KIND_INVALID])
      try Test.eq([url, answer.text.include?("pw").to_s], [url, "false"])
    end

    try Test.eq(error_kind_of(try login(h, "local", "sk-1")), Protocol.KIND_INVALID)
    try Test.eq(error_kind_of(try login_url(h, "local", "#{root}/none/v1")), Protocol.KIND_LOGIN_REJECTED)
    try Test.eq(File.stat(H.auth_file(h.base)).ok?, false)
    right = try login_url(h, "local", "#{root}/llama/v1/")
    try Test.eq(right.status, 200)
    status = try Protocol.decode_login_status(right.text)
    try Test.eq([status.from, status.base_url], ["stored", "#{root}/llama/v1"])
    try Test.eq((try login(h, "paid", "sk-paid")).status, 200)
    stored = Auth.load(H.auth_file(h.base), none)
    try Test.eq([stored.keys, stored.urls], [{"paid": "sk-paid"}, {"local": "#{root}/llama/v1"}])
    id = try H.new_session_in(h, h.work, none, some("local"))
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Hi.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    seen: List[String] = []
    for _ in 1..5
      request = try H.next_request(h)
      seen = seen.push("#{request.method} #{request.path} #{bearer(request)}")
    end

    try Test.eq(
      seen,
      [
        "GET /none/v1/models test-key", "GET /llama/v1/models test-key", "GET /paid/models sk-paid",
        "GET /llama/props ", "POST /llama/v1/chat/completions test-key",
      ],
    )

    H.restarted(h, setup, "") do |r|
      again = try Protocol.decode_login_list((try H.get(r, Protocol.AUTH_PATH)).text)
      try Test.eq([again.providers[0].from, again.providers[0].base_url], ["stored", "#{root}/llama/v1"])
      try Test.eq((try H.call(r, "DELETE", Protocol.auth_path("local"), "", H.auth(r))).status, 200)
      after = try Protocol.decode_login_list((try H.get(r, Protocol.AUTH_PATH)).text)
      try Test.eq([after.providers[0].from, after.providers[0].base_url], ["", r.fake.url])
      Test.eq(File.read_text(H.auth_file(r.base)), ok("{\"keys\":{\"paid\":\"sk-paid\"}}"))
    end
  end
end

# On the real setup a stored base URL serves `local` after a start, and FINN_BASE_URL (or its old name) wins over it.
# The key file keeps the keys and the URLs as they were saved.
def test_finn_base_url_wins_over_a_stored_base_url() -> Result[Void]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/core-local-#{Random.int(0, 999999999)}"
  result = stored_url(dir)
  _ = Path.remove(dir)
  result
end

def stored_url(dir: String) -> Result[Void]
  try Dir.mkdir(dir)
  file = "#{dir}/finn/#{Auth.FILE}"
  try Auth.create(file, {}, {"local": "http://127.0.0.1:9/v1"})
  try Test.eq(Auth.load(file, none), Auth.Stored(urls: {"local": "http://127.0.0.1:9/v1"}, found: true))
  both = Auth.Stored(keys: {"groq": "sk-1"}, urls: {"local": "http://127.0.0.1:9/v1"}, found: true)
  try Auth.save(file, both.keys, both.urls, none)
  try Test.eq(Auth.load(file, none), both)
  no_ant = -> {
    failed: Result[String] = error("no ant")
    failed
  }

  env = {"XDG_CONFIG_HOME": dir}
  options = try Config.from_env_with(->(n) { from(env, n) }, no_ant)
  try Test.eq(options.props_url, "http://127.0.0.1:9/props")
  try Test.eq(local_of(options), ["stored", "http://127.0.0.1:9/v1", "FINN_BASE_URL"])
  set = env.put("FINN_BASE_URL", "http://127.0.0.1:7/v1")
  chosen = try Config.from_env_with(->(n) { from(set, n) }, no_ant)
  try Test.eq(chosen.props_url, "http://127.0.0.1:7/props")
  try Test.eq(local_of(chosen), ["env", "http://127.0.0.1:7/v1", "FINN_BASE_URL"])
  old = env.put("AGC_AGENT_BASE_URL", "http://127.0.0.1:6/v1")
  Test.eq(
    local_of(try Config.from_env_with(->(n) { from(old, n) }, no_ant)),
    ["env", "http://127.0.0.1:6/v1", "AGC_AGENT_BASE_URL"],
  )
end

def local_of(options: Config.Options) -> List[String]
  holder = Logins.start(options.providers, options.login)
  listed = Logins.list(holder)
  Logins.stop(holder)
  found = listed.unwrap_or(Logins.Listing(providers: [], first: false)).providers.select { |p| p.name == "local" }
  found.flat_map { |p| [p.from, p.base_url, p.key_env] }
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
  try Test.eq((try Logins.current(holder)).providers.has_key?("openrouter"), true)
  try File.write_text(file, "{\"keys\": {\"openrouter\": \"sk-box\", \"else\": \"sk-else\"}}")
  try Logins.login(holder, "anthropic", "sk-claude")
  try Test.eq((try File.read_text(file)).include?("sk-else"), true)
  try Logins.logout(holder, some("openrouter"))
  try Test.eq((try Logins.current(holder)).providers.has_key?("openrouter"), false)
  try chmod("644", file)
  try Test.eq(error_kind(Logins.logout(holder, some("anthropic"))), Protocol.KIND_LOGIN_STORAGE)
  try Test.eq((try File.read_text(file)).include?("sk-claude"), true)
  try Test.eq(error_kind(Auth.create(file, {}, {})), "io.exists")
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
