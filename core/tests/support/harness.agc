## A core server on port 0 in a fresh folder, against a fake LLM API, and an HTTP client for it: the requests of the
## protocol and the event stream read with the `sse` parser.

import HTTP from "std/http"
import LLM from "pkg/llm/llm"
import Monty from "pkg/monty/monty"
import Protocol from "pkg/protocol/protocol"
import SSE from "pkg/sse/sse"
import Approval from "../../src/approval/approval"
import Permissions from "../../src/approval/permissions"
import Catalog from "../../src/providers/catalog"
import Chatgpt from "../../src/providers/chatgpt"
import CodeMode from "../../src/tools/code_mode"
import Auth from "../../src/providers/auth"
import Config from "../../src/config/config"
import Offered from "../../src/providers/offered"
import Extensions from "../../src/config/registry"
import Logins from "../../src/providers/logins"
import Providers from "../../src/providers/providers"
import Server from "../../src/http/server"
import Builtins from "../../src/session/builtins"
import Tools from "../../src/tools/tools"
import Fake from "fake_llm"

WAIT_MS = 10000

struct Harness
  server: Server.Server
  fake: Fake.Fake
  base: String
  work: String
  state_dir: String
  data_dir: String
  url: String
  token: String
  providers: Map[String, Config.Provider]
  provider: String
end

struct Answer
  status: Int
  text: String
end

## An event as a client saw it.
struct Seen
  id: String
  event: Protocol.Event
end

struct Sub
  stream: HTTP.Stream
  parser: SSE.Parser
  seen: List[Seen]
end

## The model answers with the fixtures `replies` in order (names under the folder of `api`; a `.json` one is a 200 JSON
## answer, `STATUS:name.json` one of that status).
struct Setup
  replies: List[String]
  keep_events: Int = 1000
  approval_timeout_ms: Int = 90000
  drain_ms: Int = 60000
  ## 0 asks the fake (`GET /models`), which takes a reply.
  context_window: Int = 1_000_000
  compact_model: String = ""
  ## The server asks the fake's `/props` for the window first.
  props: Bool = false
  before_load: Optional[Fn[String, Void]] = none
  after_load: Optional[Fn[String, Void]] = none
  ## The model API of the server, as `FINN_API` names it; the fixtures come from the folder of its format.
  api: String = "openai"
  ## The tools of MCP servers, and those that come after the start.
  tools: List[Tools.Tool] = []
  late_tools: Optional[Fn[String, List[Tools.Tool]]] = none
  ## Makes the diff of each tool call in place of the real one.
  diff: Optional[Fn[String, JSON.Value, String]] = none
  ## Code mode on a fake Monty worker that replays this fixture of `tests/fixtures/monty`.
  monty: String = ""
  ## Providers of the config file, each at `/NAME` of the fake with the OpenAI chat API (`NAME:openai_responses` for
  ## the Responses API), the server's provider (empty for that of `api`) and the key variables of providers.
  providers: List[String] = []
  ## Presets of the server (`Providers.presets`) at `/NAME` of the fake, each with a stored key `sk-NAME`.
  presets: List[String] = []
  provider: String = ""
  ## `FINN_MODEL` is set: it wins over the model last picked.
  model_pinned: Bool = false
  key_envs: Map[String, String] = {}
  ## Providers a login sets up, each at `/NAME` of the fake with the key variable `NAME_KEY` (`NAME=VAR` for another),
  ## and their keys in `config/finn/auth.json` of the test's folder.
  logins: List[String] = []
  ## A login sets the base URL of `local` (the fake at the start).
  local_login: Bool = false
  ## The ChatGPT login: its OAuth server at `/auth` of the fake and Codex at `/codex`, its tokens in the state folder.
  chatgpt: Bool = false
  chatgpt_poll_ms: Int = 10
  chatgpt_device_ms: Int = 5000
  ## The approvals on (calls that no rule allows ask); the deny rules of the config, as `bash(rm *)`, count either way.
  approvals: Bool = true
  deny: List[String] = []
  allow: List[String] = []
  ## When given, the rules and the mode come from this environment as the server reads them (`Config.from_env`), in
  ## place of `approvals` and `deny`.
  approvals_env: Optional[Fn[String, Result[String]]] = none
  ## The settings of the config file that `FINN_CONFIG` of `env` names are live: a reload reads them again.
  live: Bool = false
  ## What else a reload does (the MCP servers of `Builtins.mcp`).
  reloads: List[Fn[Result[String]]] = []
  mcp: Optional[Config.McpControl] = none
  ## How long a reload waits for another one that runs.
  reload_wait_ms: Int = 150_000
  ## The command that lists the files for `@` (`files.command` of the user's config).
  files_command: List[String] = []
  ## The file tools reach only the session folder.
  confine: Bool = false
  ## What extensions add (`Core.serve`): its tools join those of the server.
  registry: Optional[Extensions.Registry] = none
  ## The server ends as `Core.serve` ends it (`Server.shutdown`), not at once.
  shutdown: Bool = false
  model: String = "qwen2.5-0.5b-instruct"
  catalog: Optional[Catalog.Catalog] = none
  ## `FINN_MAX_TOKENS`.
  max_tokens: Optional[Int] = none
  ## The token that Anthropic fetches again after a 401; none when empty.
  fresh_token: String = ""
  ## How long a turn waits for its queued messages.
  take_ms: Int = 5000
  ## `max_rounds` of a turn.
  max_rounds: Int = 500
  ## Variables of the server's environment, over the fake one.
  env: Map[String, String] = {}
  ## How long a turn waits for a catalog that still loads.
  catalog_wait_ms: Int = 1500
  ## Skills: the home folder is `home` under the test's folder, and the folders of `trust` (under the test's folder;
  ## the test's folder itself when none) are trusted.
  skills: Bool = false
  trust: Optional[List[String]] = none
  ## Finn's own documentation pages are the folder `docs` of the test's folder (the built-in skill `finn`).
  docs: Bool = false
  ## The user's config folder is `config/finn` of the test's folder (`XDG_CONFIG_HOME`), with its profiles and commands.
  profiles: Bool = false
end

## Lets a held reply of the fake go on (`name@hold` in `replies`).
def release(h: Harness) -> Void
  Fake.release(h.fake)
end

def fake_env(name: String) -> Result[String]
  case name
    "PATH" -> System.env("PATH")
    "OPENAI_API_KEY" -> ok("sk-secret-key")
    _ -> error("not set")
  end
end

## Runs `body` against a server of `setup`, and stops the server and the fake and removes the folder however it ends.
def using(setup: Setup, body: Fn[Harness, Result[Void]]) -> Result[Void]
  tmp = System.env("TMPDIR").unwrap_or("/tmp")
  base = "#{tmp}/agc-core-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(base)
  result = with_fake(setup, base, body)
  _ = Path.remove(base)
  result
end

# A fixture's `@BASE@` is the test's folder.
def with_fake(setup: Setup, base: String, body: Fn[Harness, Result[Void]]) -> Result[Void]
  real = try Path.real(base)
  replies = (try fixtures(setup.replies, fixture_dir(setup.api))).map { |reply| placed(reply, real) }
  fake = try Fake.start(replies)
  started = start(setup, real, fake)
  result = case started
    ok(h) -> body.call(h)
    error(e) -> error(e)
  end

  case started
    ok(h) if setup.shutdown -> Server.shutdown(h.server, true)
    ok(h) -> Server.stop(h.server)
    error(_) -> nil
  end

  _ = Fake.stop(fake)
  result
end

# With `fresh_token`, Anthropic gets that token after a 401.
def apis(setup: Setup, fake: Fake.Fake, url: String) -> Map[String, Config.ModelApi]
  options = LLM.Options(timeout_ms: 5000, retry_base_ms: 1)
  all = Offered.apis(url, "test-key", options)
  return all if setup.fresh_token.empty?

  token = setup.fresh_token
  refresh = -> { ok(LLM.anthropic(url, "", options, token)) }
  all.put("anthropic", all["anthropic"].with(refresh: some(refresh)))
end

def providers(
  setup: Setup,
  fake: Fake.Fake,
  keys: Map[String, String] = {},
  urls: Map[String, String] = {},
  chatgpt: Optional[Chatgpt.Login] = none,
) -> Map[String, Config.Provider]
  all = Offered.builtin(apis(setup, fake, urls.get("local").unwrap_or(fake.url)), setup.api)
  root = fake_root(fake)
  customs = setup.providers.map do |given|
    parts = given.split(":").push("openai")
    Providers.Custom(name: parts[0], api: parts[1], base_url: "#{root}/#{parts[0]}", models: ["m1"])
  end

  keyed = keys
  for preset in Providers.presets().select { |p| setup.presets.include?(p.name) }
    customs = customs.push(preset.with(base_url: "#{root}/#{preset.name}"))
    keyed = keyed.put(preset.name, "sk-#{preset.name}")
  end

  customs = customs + login_customs(setup, fake)
  options = LLM.Options(timeout_ms: 5000, retry_base_ms: 1)
  more = Providers.offered(customs, &fake_env, options, keyed)
  for name in more.keys
    all = all.put(name, more[name])
  end

  for login in option_list(chatgpt)
    all = Chatgpt.added(ok(all), login, options).unwrap_or(all)
  end

  all
end

## The ChatGPT login of a test's folder, against the fake: a poll every `poll_ms`, a wait for the user of `device_ms`,
## calls of `call_ms` at most and a lock held that and `lock_margin_ms` at most.
def chatgpt_login(
  fake: Fake.Fake,
  base: String,
  poll_ms: Int = 10,
  device_ms: Int = 5000,
  call_ms: Int = 2000,
  lock_margin_ms: Int = 200,
) -> Chatgpt.Login
  root = fake_root(fake)
  endpoints = Chatgpt.Endpoints(
    issuer: "#{root}/auth",
    base_url: "#{root}/codex",
    min_poll_ms: poll_ms,
    poll_margin_ms: 0,
    device_ms: device_ms,
    call_ms: call_ms,
    lock_margin_ms: lock_margin_ms,
  )

  Chatgpt.Login(path: "#{base}/state/#{Chatgpt.FILE}", endpoints: endpoints, lock: ATS.new(), usage_cache: ATS.new())
end

def fake_root(fake: Fake.Fake) -> String = fake.url.slice(0, fake.url.length - "/v1".length)

def login_customs(setup: Setup, fake: Fake.Fake) -> List[Providers.Custom]
  setup.logins.map do |given|
    parts = given.split("=").push("#{given.upcase}_KEY")
    Providers.Custom(name: parts[0], base_url: "#{fake_root(fake)}/#{parts[0]}", key_env: parts[1])
  end
end

def local_url_of(setup: Setup, fake: Fake.Fake) -> String
  return "" if not setup.local_login

  fake.url
end

def auth_file(base: String) -> String = "#{base}/config/finn/#{Auth.FILE}"

def login_setup(setup: Setup, fake: Fake.Fake, base: String) -> Optional[Logins.Setup]
  return none if setup.logins.empty? and not setup.local_login and not setup.chatgpt

  path = auth_file(base)
  chatgpt: Optional[Chatgpt.Login] = none
  if setup.chatgpt
    chatgpt = some(chatgpt_login(fake, base, setup.chatgpt_poll_ms, setup.chatgpt_device_ms))
  end

  some(
    Logins.Setup(
      path: some(path),
      stored: Auth.load(path, none),
      entries: login_customs(setup, fake),
      read: &fake_env,
      rebuild: ->(keys: Map[String, String], urls: Map[String, String]) {
        ok(providers(setup, fake, keys, urls, chatgpt))
      },
      local_url: local_url_of(setup, fake),
      local_key: "test-key",
      chatgpt: chatgpt,
      choice: Logins.load_choice(choice_file(base)),
      choice_file: some(choice_file(base)),
    ),
  )
end

def choice_file(base: String) -> String = "#{base}/state/#{Config.CHOICE_FILE}"

def placed(reply: Fake.Reply, base: String) -> Fake.Reply
  case String.from_bytes(reply.body)
    ok(text) if text.include?("@BASE@") -> reply.with(body: text.replace("@BASE@", base).bytes)
    _ -> reply
  end
end

def start(setup: Setup, base: String, fake: Fake.Fake) -> Result[Harness]
  work = "#{base}/work"
  try Dir.mkdir(work)
  user = Permissions.User(
    rules: try Approval.parse_rules(setup.allow.map { |r| "allow #{r}" } + setup.deny.map { |r| "deny #{r}" }),
    asking: setup.approvals,
  )

  for read in option_list(setup.approvals_env)
    user = try Permissions.user_rules(read, try Config.approvals_switch(read))
  end

  live: Optional[Config.Live] = none
  if setup.live
    read = env_of(setup, base)
    user = try Permissions.user_rules(read, try Config.approvals_switch(read))
    stub = ->(_more: List[Providers.Custom]) { Logins.Replacement(entries: [], rebuild: ->(_k, _u) { ok({}) }) }
    live = some(try Config.live_from(read, stub))
  end

  login = login_setup(setup, fake, base)
  options = Config.Options(
    state_dir: "#{base}/state",
    data_dir: "#{base}/data",
    providers: providers(
      setup,
      fake,
      login.map { |l| l.stored.keys }.unwrap_or({}),
      login.map { |l| l.stored.urls }.unwrap_or({}),
      login.map { |l| l.chatgpt }.unwrap_or(none),
    ),
    provider: server_provider(setup),
    provider_pinned: not setup.provider.empty?,
    model_pinned: setup.model_pinned,
    login: login,
    key_envs: setup.key_envs,
    model: setup.model,
    env: env_of(setup, base),
    approvals: some(user.rules),
    asking: user.asking,
    registry: some(served_of(setup, user, env_of(setup, base), live, login)),
    live: live,
    reloads: setup.reloads,
    mcp: setup.mcp,
    reload_wait_ms: setup.reload_wait_ms,
    keep_events: setup.keep_events,
    approval_timeout_ms: setup.approval_timeout_ms,
    drain_ms: setup.drain_ms,
    context_window: window(setup.context_window),
    compact_model: setup.compact_model,
    props_url: props_url(setup, fake),
    before_load: setup.before_load,
    after_load: setup.after_load,
    tools: setup.tools + setup.registry.map { |r| Extensions.spec_tools(r) }.unwrap_or([]),
    diff: setup.diff,
    code_mode: code_mode(setup.monty),
    catalog: setup.catalog,
    max_tokens: setup.max_tokens,
    take_ms: setup.take_ms,
    max_rounds: setup.max_rounds,
    catalog_wait_ms: setup.catalog_wait_ms,
    home: skills_home(setup, base),
    skill_user: [".agents/skills", ".claude/skills"],
    skill_project: [".agents/skills", ".claude/skills"],
    docs: docs_folder(setup, base),
    trusted: skills_trusted(setup, base),
    files_command: setup.files_command,
    confine_files: setup.confine,
  )

  server = try Server.start(options)
  ok(
    Harness(
      server: server,
      fake: fake,
      base: base,
      work: work,
      state_dir: options.state_dir,
      data_dir: options.data_dir,
      url: "http://127.0.0.1:#{server.port}",
      token: server.token,
      providers: options.providers,
      provider: options.provider,
    ),
  )
end

## Stops the server and starts a new one on the same folders and fake; `body` gets it, and it stops after. `cut` is
## added to the end of every session file in between, as a write that a crash cut.
def restarted(h: Harness, setup: Setup, cut: String, body: Fn[Harness, Result[Void]]) -> Result[Void]
  Server.stop(h.server)
  if not cut.empty?
    for name in try Dir.list(sessions(h))
      next if not name.end_with?(".jsonl")

      try File.append_text("#{sessions(h)}/#{name}", cut)
    end
  end

  again = try start(setup, h.base, h.fake)
  result = body.call(again)
  Server.stop(again.server)
  result
end

def server_provider(setup: Setup) -> String
  return Offered.default_provider(setup.api) if setup.provider.empty?

  setup.provider
end

def sessions(h: Harness) -> String = "#{h.data_dir}/sessions"

def session_file(h: Harness, id: String) -> String = "#{sessions(h)}/#{id}.jsonl"

## Runs a program and gives its exit code.
def run(program: String, args: List[String]) -> Result[Int]
  process = try Process.spawn(program, args)
  code = Process.wait(process, 5000)
  Process.close(process)
  code
end

def props_url(setup: Setup, fake: Fake.Fake) -> String
  return "" if not setup.props

  "#{fake.url.slice(0, fake.url.length - 3)}/props"
end

# The fake worker of the monty package, which replays frames recorded from the real one.
def code_mode(fixture: String) -> Optional[CodeMode.Settings]
  return none if fixture == ""

  agentica = System.env("AGENTICA").unwrap_or("agentica")
  words = [agentica, "tests/support/fake_monty.agc", "tests/fixtures/monty/#{fixture}"]
  some(CodeMode.Settings(worker: -> { ok(words) }, limits: Monty.Limits()))
end

# The extensions of the setup with the core's own, as `Core.serve` adds them.
def served_of(
  setup: Setup,
  user: Permissions.User,
  env: Fn[String, Result[String]],
  live: Optional[Config.Live],
  login: Optional[Logins.Setup],
) -> Extensions.Served
  served = Extensions.Served(registry: setup.registry.unwrap_or(Extensions.Registry()))
  served = Builtins.approvals(Builtins.skills(Builtins.commands(served, env)), some(user.rules), user.asking, live)
  served = Builtins.chatgpt_quota(served, login)
  for late in option_list(setup.late_tools)
    served = Extensions.add_late_tools(served, late)
  end

  served
end

def env_of(setup: Setup, base: String) -> Fn[String, Result[String]]
  return &fake_env if not setup.profiles and setup.env.empty?

  ->(name: String) {
    return ok(setup.env[name]) if setup.env.has_key?(name)

    case name
      "XDG_CONFIG_HOME" if setup.profiles -> ok("#{base}/config")
      _ -> fake_env(name)
    end
  }
end

def skills_home(setup: Setup, base: String) -> String
  return "" if not setup.skills

  "#{base}/home"
end

def docs_folder(setup: Setup, base: String) -> String
  return "" if not setup.docs

  "#{base}/docs"
end

def skills_trusted(setup: Setup, base: String) -> List[String]
  return [] if not setup.skills

  setup.trust.unwrap_or(["."]).map { |dir| "#{base}/#{dir}" }
end

def window(tokens: Int) -> Optional[Int]
  return none if tokens == 0

  some(tokens)
end

## A name is a fixture under `dir`, `STATUS:name.json`, or a path; `name@MS` answers after MS milliseconds, and
## `name@hold` when the test calls `release`.
def fixtures(names: List[String], dir: String = "openai_chat") -> Result[List[Fake.Reply]]
  replies: List[Fake.Reply] = []
  for timed in names
    name = timed.split("@")[0]
    if timed.include?("@")
      later = try fixtures([name], dir)
      if timed.split("@")[1] == "hold"
        replies = replies.push(later[0].with(hold: true))
      else
        replies = replies.push(later[0].with(delay_ms: try timed.split("@")[1].to_i))
      end

      next
    end

    parts = name.split(":")
    if name.start_with?("302>")
      location = HTTP.Header(name: "Location", value: name.slice(4, name.length - 4))
      replies = replies.push(Fake.Reply(status: 302, body: "".bytes, headers: [location]))
    elsif name.include?("/")
      replies = replies.push(try Fake.sse(name))
    elsif parts.size == 2
      replies = replies.push(try Fake.json(try parts[0].to_i, "#{dir}/#{parts[1]}"))
    elsif name.end_with?(".json")
      replies = replies.push(try Fake.json(200, "#{dir}/#{name}"))
    else
      replies = replies.push(try Fake.sse("#{dir}/#{name}"))
    end
  end

  ok(replies)
end

def fixture_dir(api: String) -> String
  return "openai_chat" if api == "openai"

  api
end

def auth(h: Harness) -> List[HTTP.Header] = [HTTP.Header(name: "Authorization", value: "Bearer #{h.token}")]

def call(h: Harness, method: String, path: String, body: String, headers: List[HTTP.Header]) -> Result[Answer]
  client = try HTTP.client(HTTP.ClientOptions(timeout_ms: WAIT_MS))
  response = HTTP.request(client, method, "#{h.url}#{path}", body.bytes, headers)
  HTTP.close_client(client)
  got = try response
  ok(Answer(status: got.status, text: try String.from_bytes(got.body)))
end

def get(h: Harness, path: String) -> Result[Answer] = call(h, "GET", path, "", auth(h))

def post(h: Harness, path: String, body: String) -> Result[Answer] = call(h, "POST", path, body, auth(h))

def new_session(h: Harness) -> Result[String] = new_session_in(h, h.work)

def new_session_in(
  h: Harness,
  cwd: String,
  api: Optional[String] = none,
  provider: Optional[String] = none,
  profile: Optional[String] = none,
  model: Optional[String] = none,
  remember: Bool = false,
) -> Result[String]
  asked = Protocol.NewSession(
    cwd: cwd,
    model: model,
    api: api,
    provider: provider,
    profile: profile,
    remember: some(remember),
  )

  answer = try post(h, Protocol.SESSIONS_PATH, Protocol.encode_new_session(asked))

  return error("POST /v1/sessions: #{answer.status} #{answer.text}") if answer.status != 201

  ok((try Protocol.decode_session_created(answer.text)).id)
end

def session(h: Harness, id: String) -> Result[Protocol.Session]
  Protocol.decode_session((try get(h, Protocol.session_path(id))).text)
end

def send(h: Harness, id: String, text: String) -> Result[Answer]
  post(h, Protocol.messages_path(id), Protocol.encode_send_message(Protocol.SendMessage(text: text)))
end

def approve(h: Harness, id: String, approval_id: String, decision: Protocol.Decision) -> Result[Answer]
  post(h, Protocol.approval_path(id, approval_id), Protocol.encode_approve(Protocol.Approve(decision: decision)))
end

def subscribe(h: Harness, id: String, last_event_id: Optional[Int] = none) -> Result[Sub]
  headers = auth(h)
  for last in option_list(last_event_id)
    headers = headers.push(HTTP.Header(name: Protocol.LAST_EVENT_ID_HEADER, value: Protocol.format_event_id(last)))
  end

  options = HTTP.ClientOptions(timeout_ms: WAIT_MS)
  stream = try HTTP.open("GET", "#{h.url}#{Protocol.events_path(id)}", "".bytes, headers, options)
  return error("events: #{stream.status}") if stream.status != 200

  ok(Sub(stream: stream, parser: SSE.parser(), seen: []))
end

## Reads the stream until an event of `kind`, and gives all it read so far.
def until(sub: Sub, kind: Protocol.EventKind) -> Result[Sub]
  at = sub.seen.size
  current = sub
  while true
    for seen in current.seen.drop(at)
      return ok(current) if Protocol.event_kind(seen.event) == kind
    end

    at = current.seen.size
    piece = try current.stream.body.recv(WAIT_MS)
    fed = try SSE.feed(current.parser, piece)
    events: List[Seen] = []
    for event in fed.events
      events = events.push(Seen(id: event.id, event: try Protocol.decode_event(event.name, event.data)))
    end

    current = current.with(parser: fed.parser, seen: current.seen + events)
  end

  ok(current)
end

def close(sub: Sub) -> Void
  sub.stream.body.close
  Task.cancel(sub.stream.done)
end

## Waits until no turn runs.
def idle(h: Harness, id: String) -> Result[Protocol.Session]
  for _i in 1..100
    snapshot = try session(h, id)
    return ok(snapshot) if snapshot.turn_id.none?

    Task.sleep(50)
  end

  error("the turn did not end")
end

def kinds(seen: List[Seen]) -> List[String] = seen.map { |s| Protocol.event_name(s.event) }

## The user messages and answers of a history, without the thinking, tool calls and stops of the turns.
def said(history: List[Protocol.Message]) -> List[Protocol.Message]
  history.select { |m| not m.thinking and m.tool.none? and m.stop.none? }
end

## An event with no time of output, which changes from run to run.
def untimed(event: Protocol.Event) -> Protocol.Event
  case event
    Protocol.Event.Usage(usage) -> Protocol.Event.Usage(usage.with(output_ms: none))
    _ -> event
  end
end

## The last approval request a client saw.
def approval(sub: Sub) -> Result[Protocol.ApprovalRequested]
  for seen in sub.seen.reverse
    case seen.event
      Protocol.Event.ApprovalRequested(request) -> return ok(request)
      _ -> nil
    end
  end

  error("no approval_requested")
end

def resolved_by(sub: Sub) -> List[String]
  sources: List[String] = []
  for seen in sub.seen
    case seen.event
      Protocol.Event.ApprovalResolved(r) ->
        sources = sources.push("#{Protocol.decision_name(r.decision)} #{Protocol.source_name(r.source)}")
      _ -> nil
    end
  end

  sources
end

## The output limit that the last `turn_finished` says its turn sent.
def turn_max_tokens(sub: Sub) -> Optional[Int]
  for seen in sub.seen.reverse
    case seen.event
      Protocol.Event.TurnFinished(finished) -> return finished.max_tokens
      _ -> nil
    end
  end

  none
end

def stop_reason(sub: Sub) -> String
  for seen in sub.seen.reverse
    case seen.event
      Protocol.Event.TurnFinished(finished) -> return Protocol.stop_reason_name(finished.stop_reason)
      _ -> nil
    end
  end

  ""
end

## The next request the fake got.
def next_request(h: Harness) -> Result[Fake.Seen] = Fake.next_request(h.fake)

## The messages of the `n`-th request the fake got (from 1).
def request_messages(h: Harness, n: Int) -> Result[List[JSON.Value]]
  seen = Fake.Seen(method: "", path: "", headers: [], body: "")
  for _i in 1..n
    seen = try Fake.next_request(h.fake)
  end

  JSON.list(try JSON.get(try JSON.parse(seen.body), "messages"))
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
