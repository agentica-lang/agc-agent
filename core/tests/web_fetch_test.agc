# `web_fetch` end to end through `Tools.run`, against a peer on 127.0.0.1 that records the paths it is asked for.
# The real tool reaches public addresses only, so a listener on 127.0.0.1 never gets a connection. The tests that fetch
# from the peer change the
# tool's `Settings` in the code of the test (`public_only: false`); no config or input does.

import HTTP from "std/http"
import Approval from "../src/approval/approval"
import Permissions from "../src/approval/permissions"
import Tools from "../src/tools/tools"
import WebFetch from "../src/tools/web_fetch"

struct Peer
  server: HTTP.Server
  port: Int
  ## The path of each request that came.
  seen: Channel[String]
  ## `/slow` waits for it to close.
  gate: Channel[Bool]
end

## What a good call gives, as a client reads it.
struct Page
  status: Int
  headers: Map[String, String]
  body: String
  content_type: String
  truncated: Bool
  truncated_chars: Bool
  processor_used: String
end

struct Failure
  ok: Bool
  error_code: String
  error: String
  url: String
end

def text_reply(type: String, body: String) -> HTTP.Response
  HTTP.Response(status: 200, headers: [HTTP.Header(name: "content-type", value: type)], body: body.bytes)
end

def route(request: HTTP.Request, gate: Channel[Bool]) -> HTTP.Response
  case request.path
    "/html" ->
      text_reply(
        "text/html; charset=utf-8",
        "<html><head><style>p{}</style></head><body class=\"x\"><p>hello   world</p><a href=\"/next\">Next</a></body></html>",
      )
    "/text" -> text_reply("text/plain", "  one   two\n\n three  ")
    "/json" -> text_reply("application/json", "{\"a\":   1}")
    "/big" -> text_reply("text/plain", "x" * 40000)
    "/echo" ->
      type = HTTP.header_values(request.headers, "content-type").join(",")
      text_reply(
        "text/plain",
        "#{request.method}|#{type}|#{HTTP.header_values(request.headers, "x-test").join(",")}|#{request.body.scrub}",
      )
    "/headers" ->
      HTTP.Response(
        status: 200,
        headers: (1..12).to_a.map { |n| HTTP.Header(name: "x-h#{n}", value: "v#{n}") },
        body: "ok".bytes,
      )
    "/redirect" -> HTTP.Response(status: 302, headers: [HTTP.Header(name: "location", value: "/text")], body: "".bytes)
    "/loop" -> HTTP.Response(status: 302, headers: [HTTP.Header(name: "location", value: "/loop")], body: "".bytes)
    "/slow" ->
      _ = gate.recv(5000)
      text_reply("text/plain", "late")
    _ -> HTTP.Response(status: 404, headers: [], body: "".bytes)
  end
end

def start_peer() -> Result[Peer]
  seen: Channel[String] = Channel.new(100)
  gate: Channel[Bool] = Channel.new(1)
  handler = ->(request: HTTP.Request) {
    _ = seen.send(request.path, 0)
    ok(route(request, gate))
  }

  server = try HTTP.serve("127.0.0.1", 0, HTTP.app(handler))
  ok(Peer(server: server, port: HTTP.local_port(server), seen: seen, gate: gate))
end

def stop_peer(peer: Peer) -> Result[Void]
  peer.gate.close
  HTTP.close_server(peer.server)
  HTTP.wait(peer.server)
end

def untouched(peer: Peer) -> Result[Void]
  case peer.seen.recv(0)
    ok(path) -> error("the peer was contacted: #{path}")
    error(_) -> ok()
  end
end

## A listener that nobody serves: a connection to it, even one that sends nothing, waits in its queue to be accepted.
def silent() -> Result[TCP.Listener] = TCP.listen("127.0.0.1", 0)

def connected(listener: TCP.Listener) -> Result[Void]
  # A connect that has completed is in the queue at once; the wait only lets the loopback finish a late one.
  case TCP.accept(listener, 100)
    ok(socket) ->
      TCP.close(socket)
      error("something connected")
    error(_) -> ok()
  end
end

def fake_env(_name: String) -> Result[String] = error("not set")

def context(settings: Optional[WebFetch.Settings]) -> Result[Tools.Context]
  tmp = System.env("TMPDIR").unwrap_or("/tmp")
  more = case settings
    some(s) -> [WebFetch.tool_with(s)]
    none -> []
  end

  Tools.context(tmp, &fake_env, false, more)
end

def fetch(ctx: Tools.Context, fields: Map[String, JSON.Value]) -> Tools.Output
  Tools.run(ctx, "web_fetch", JSON.object(fields))
end

def get(ctx: Tools.Context, url: String) -> Tools.Output = fetch(ctx, {"url": JSON.from(url)})

def page(out: Tools.Output) -> Result[Page]
  try Test.assert(not out.is_error, out.text)
  Page.codec.decode(try JSON.parse(out.text))
end

def failure(out: Tools.Output) -> Result[Failure]
  try Test.assert(out.is_error, "expected a failure, got: #{out.text}")
  Failure.codec.decode(try JSON.parse(out.text))
end

def local() -> WebFetch.Settings = WebFetch.Settings(public_only: false, timeout_ms: 2000)

# The tool as a session has it: the peer on 127.0.0.1 is refused however the URL spells it, user info is a bad URL, and
# the peer never hears of any of it.
def test_the_tool_never_reaches_a_local_peer() -> Result[Void]
  listener = try silent()
  ctx = try context(none)
  port = TCP.local_port(listener)
  private = "web_fetch_private_address"
  table = [
    ["http://127.0.0.1:#{port}/text", private],
    ["http://localhost:#{port}/text", private],
    ["http://127.1:#{port}/text", private],
    ["http://2130706433:#{port}/text", private],
    ["http://0x7f.0.0.1:#{port}/text", private],
    ["http://[::1]:#{port}/text", private],
    ["http://[::ffff:7f00:1]:#{port}/text", private],
    ["http://x.localhost:#{port}/text", private],
    ["http://user:pw@127.0.0.1:#{port}/text", "web_fetch_invalid_url"],
    ["ftp://127.0.0.1:#{port}/text", "web_fetch_invalid_url"],
  ]

  for row in table
    failed = try failure(get(ctx, row[0]))
    try Test.eq("#{row[0]} #{failed.error_code}", "#{row[0]} #{row[1]}")
    try Test.assert(not failed.error.empty?, "an empty reason for #{row[0]}")
  end

  for method in ["HEAD", "POST", "OPTIONS"]
    sent = fetch(
      ctx,
      {"url": JSON.from("http://127.0.0.1:#{port}/x"), "method": JSON.from(method), "body": JSON.from("b")},
    )

    refused = try failure(sent)
    try Test.eq(refused.error_code, "web_fetch_private_address")
  end

  try connected(listener)
  TCP.close_listener(listener)
  ok()
end

# The instrument of the tests above: a bare connect is seen.
def test_a_bare_connect_is_seen_by_the_listener() -> Result[Void]
  listener = try silent()
  try connected(listener)
  socket = try TCP.connect("127.0.0.1", TCP.local_port(listener), 1000)
  try Test.assert(not connected(listener).ok?, "a connect was not seen")
  TCP.close(socket)
  TCP.close_listener(listener)
  ok()
end

# A name whose answer holds a private address never gets a connection, whatever the address (the peer listens on
# 127.0.0.1 and would be reached if the answer were taken as it is).
def test_a_host_that_resolves_to_a_private_address_is_refused() -> Result[Void]
  listener = try silent()
  answers = [
    ["10.0.0.1"],
    ["169.254.169.254"],
    ["127.0.0.1"],
    ["::1"],
    ["fe80::1"],
    ["::ffff:7f00:1"],
    ["::ffff:10.0.0.1"],
    ["127.0.0.1", "::1"],
  ]

  for answer in answers
    settings = WebFetch.Settings(resolver: some(->(_host: String) { ok(answer) }), timeout_ms: 2000)
    ctx = try context(some(settings))
    failed = try failure(get(ctx, "http://pinned.example:#{TCP.local_port(listener)}/text"))
    try Test.eq("#{answer} #{failed.error_code}", "#{answer} web_fetch_private_address")
  end

  try connected(listener)
  TCP.close_listener(listener)
  ok()
end

# With the address rule off in the test only: HTML and text and JSON, the headers (the first ten) and the content type.
def test_a_response_is_shaped_for_the_model() -> Result[Void]
  peer = try start_peer()
  ctx = try context(some(local()))
  base = "http://127.0.0.1:#{peer.port}"
  html = try page(get(ctx, "#{base}/html"))
  try Test.eq(html.status, 200)
  try Test.eq([html.content_type, "#{html.truncated}"], ["text/html", "false"])
  try Test.eq([html.body, html.processor_used], ["p \"hello world\"\na \"Next\" /next", "html_compact"])
  plain = try page(get(ctx, "#{base}/text"))
  try Test.eq([plain.body, plain.processor_used, plain.content_type], ["one two three", "plain", "text/plain"])
  json = try page(get(ctx, "#{base}/json"))
  try Test.eq([json.body, json.processor_used], ["{\"a\":   1}", "none"])
  headers = try page(get(ctx, "#{base}/headers"))
  try Test.eq(headers.headers.size, 10)
  missing = try page(get(ctx, "#{base}/missing"))
  try Test.eq(missing.status, 404)
  stop_peer(peer)
end

def hanging(_html: String) -> String
  Task.sleep(60_000)
  "late"
end

def crashing(html: String) -> String = html.slice(0, html.length + 1)

# When the compaction fails, takes too long, finds nothing or is given too large a page, the page is its plain text.
def test_a_page_is_plain_text_when_the_compaction_cannot_be_used() -> Result[Void]
  peer = try start_peer()
  url = "http://127.0.0.1:#{peer.port}/html"
  hang = &hanging
  crash = &crashing
  empty = ->(_html: String) { "" }
  settings = local().with(compact_timeout_ms: 200)
  cases = [
    settings.with(compactor: some(hang)),
    settings.with(compactor: some(crash)),
    settings.with(compactor: some(empty)),
    settings.with(compact_chars: 20),
  ]

  for variant in cases
    started = Time.monotonic_ms()
    plain = try page(get(try context(some(variant)), url))
    try Test.assert(Time.monotonic_ms() - started < 3000, "the compaction held the call")
    try Test.eq(plain.processor_used, "plain")
    try Test.assert(plain.body.include?("hello world"), plain.body)
  end

  good = try page(get(try context(some(settings)), url))
  try Test.eq(good.processor_used, "html_compact")
  stop_peer(peer)
end

# A body over `max_bytes` is cut and says so; with no place to keep it, nothing else is done. `max_chars` cuts
# the text.
def test_a_large_body_is_cut_and_says_so() -> Result[Void]
  peer = try start_peer()
  settings = local()
  big = try page(get(try context(some(settings)), "http://127.0.0.1:#{peer.port}/big"))
  try Test.eq(big.body.length, 16384)
  try Test.eq([big.truncated, big.truncated_chars], [true, false])
  short = try context(some(settings.with(max_chars: some(100))))
  cut = try page(get(short, "http://127.0.0.1:#{peer.port}/big"))
  try Test.eq(cut.body.length, 100)
  try Test.eq([cut.truncated, cut.truncated_chars], [true, true])
  stop_peer(peer)
end

# The methods, the headers, and `body` or `json` as the peer got them.
def test_the_request_is_sent_as_asked() -> Result[Void]
  peer = try start_peer()
  ctx = try context(some(local()))
  url = JSON.from("http://127.0.0.1:#{peer.port}/echo")
  header = JSON.object({"x-test": JSON.from("yes")})
  posted = try page(
    fetch(ctx, {"url": url, "method": JSON.from("post"), "body": JSON.from("hi there"), "headers": header}),
  )

  try Test.eq(posted.body, "POST||yes|hi there")
  sent = try page(fetch(ctx, {"url": url, "method": JSON.from("PUT"), "json": JSON.from("{\"a\": 1}")}))
  try Test.eq(sent.body, "PUT|application/json||{\"a\":1}")
  head = try page(fetch(ctx, {"url": url, "method": JSON.from("HEAD")}))
  try Test.eq(head.status, 200)
  try Test.eq(head.body, "")
  stop_peer(peer)
end

# A redirect comes back as it is unless the settings follow it, and a loop of redirects ends in a failure.
def test_redirects_are_followed_only_when_asked() -> Result[Void]
  peer = try start_peer()
  base = "http://127.0.0.1:#{peer.port}"
  plain = try page(get(try context(some(local())), "#{base}/redirect"))
  try Test.eq(plain.status, 302)
  try Test.eq(plain.headers["location"], "/text")
  following = try context(some(local().with(follow_redirects: true, max_redirects: 3)))
  followed = try page(get(following, "#{base}/redirect"))
  try Test.eq(followed.status, 200)
  try Test.eq(followed.body, "one two three")
  looped = try failure(get(following, "#{base}/loop"))
  try Test.eq(looped.error_code, "web_fetch_failed")
  try Test.assert(not looped.error.empty?, "an empty reason")
  stop_peer(peer)
end

# A peer that does not answer in time is a failure that says timeout, not an empty one.
def test_a_slow_reply_times_out() -> Result[Void]
  peer = try start_peer()
  ctx = try context(some(local().with(timeout_ms: 300)))
  failed = try failure(get(ctx, "http://127.0.0.1:#{peer.port}/slow"))
  try Test.eq(failed.error_code, "web_fetch_timeout")
  try Test.assert(failed.error.include?("timeout"), failed.error)
  stop_peer(peer)
end

# A call that is wrong never gets to the network.
def test_a_bad_call_is_refused_before_any_request() -> Result[Void]
  listener = try silent()
  ctx = try context(some(local()))
  base = "http://127.0.0.1:#{TCP.local_port(listener)}"
  url = JSON.from("#{base}/text")
  bad = [
    {"method": JSON.from("GET")},
    {"url": url, "method": JSON.from("TRACE")},
    {"url": url, "body": JSON.from("a"), "json": JSON.from("{}")},
    {"url": url, "json": JSON.from("{not json")},
    {"url": url, "headers": JSON.object({"bad name": JSON.from("x")})},
    {"url": url, "headers": JSON.object({"x-a": JSON.from("v\r\nInjected: 1")})},
    {"url": url, "headers": JSON.object({"Host": JSON.from("other.example")})},
    {"url": JSON.from("#{base}/a\r\nHost: other")},
    {"url": JSON.from("#{base}/a#{String.from_code(0)}b")},
    {"url": url, "extra": JSON.from(1)},
  ]

  for fields in bad
    try Test.assert(fetch(ctx, fields).is_error, "#{fields} was not refused")
    case connected(listener)
      ok(_) -> nil
      error(_) -> try Test.assert(false, "connected for #{fields}")
    end
  end

  try connected(listener)
  TCP.close_listener(listener)
  ok()
end

# `web_fetch` is one of the base tools and asks, as every tool that reaches out; a rule decides on its URL.
def test_web_fetch_asks_and_the_rules_decide_on_its_url() -> Result[Void]
  try Test.assert(Tools.all().any? { |tool| tool.name == "web_fetch" and tool.asks }, "not an asking base tool")
  ctx = try context(none)
  rules = try Approval.parse_rules(["allow web_fetch(https://docs.example.com/*)", "deny web_fetch(*private*)"])
  verdict = ->(url: String) { Approval.verdict(rules, ctx, "web_fetch", JSON.object({"url": JSON.from(url)})) }
  try Test.eq(verdict.call("https://docs.example.com/a"), Tools.Verdict.Allow)
  try Test.eq(verdict.call("https://other.example.com/a"), Tools.Verdict.Ask)
  try Test.eq(verdict.call("https://docs.example.com/private"), Tools.Verdict.Deny)
  ok()
end

def call_input(fields: Map[String, JSON.Value]) -> JSON.Value = JSON.object(fields)

# The prompt shows what would be sent, and an answer for one call is never an answer for another: allowing a GET
# for the
# session does not allow a POST to the same URL, nor the same POST with another body.
def test_the_prompt_shows_the_request_and_a_session_allow_covers_that_call_only() -> Result[Void]
  ctx = try context(none)
  url = JSON.from("https://api.example.com/items")
  get_call = call_input({"url": url})
  post = call_input({
    "url": url,
    "method": JSON.from("post"),
    "body": JSON.from("hello"),
    "headers": JSON.object({"x-key": JSON.from("v")}),
  })

  other = call_input({
    "url": url,
    "method": JSON.from("post"),
    "body": JSON.from("bye"),
    "headers": JSON.object({"x-key": JSON.from("v")}),
  })

  try Test.eq(Tools.detail("web_fetch", post), "POST https://api.example.com/items\nx-key: v\n\nhello")
  try Test.eq(Tools.detail("web_fetch", get_call), "GET https://api.example.com/items")
  try Test.eq(try Tools.target(ctx, "web_fetch", get_call), "https://api.example.com/items")
  posted = try Tools.target(ctx, "web_fetch", post)
  try Test.assert(posted.start_with?("https://api.example.com/items\tPOST "), posted)
  try Test.eq(posted.length, "https://api.example.com/items\tPOST ".length + 64)
  try Test.assert(posted != try Tools.target(ctx, "web_fetch", other), "two bodies, one target")

  rules = try Approval.parse_rules([])
  allows = Permissions.answered(
    Permissions.Allows(),
    "allow_session",
    "/w",
    "web_fetch",
    try Tools.target(ctx, "web_fetch", get_call),
  )

  allowed = ->(input: JSON.Value) {
    Permissions.allows?(allows, rules, "/w", "web_fetch", Tools.target(ctx, "web_fetch", input).unwrap_or(""))
  }

  try Test.eq(allowed.call(get_call), true)
  try Test.eq(allowed.call(post), false)
  try Test.eq(allowed.call(call_input({"url": url, "method": JSON.from("HEAD")})), true)
  try Test.eq(
    allowed.call(call_input({"url": url, "headers": JSON.object({"authorization": JSON.from("Bearer x")})})),
    false,
  )

  ok()
end

# A rule matches the URL however it is spelled and whatever the call does: a deny rule of a host also denies its POST.
def test_a_rule_matches_the_canonical_url_of_every_kind_of_call() -> Result[Void]
  ctx = try context(none)
  rules = try Approval.parse_rules([
    "allow web_fetch(https://docs.example.com/*)", "deny web_fetch(https://evil.example/*)",
  ])

  verdict = ->(fields: Map[String, JSON.Value]) { Approval.verdict(rules, ctx, "web_fetch", call_input(fields)) }
  for spelled in ["https://evil.example/x", "HTTPS://Evil.Example.:443/x", "https://EVIL.example"]
    try Test.eq(verdict.call({"url": JSON.from(spelled)}), Tools.Verdict.Deny)
    posted = verdict.call({"url": JSON.from(spelled), "method": JSON.from("POST"), "body": JSON.from("x")})
    try Test.eq(posted, Tools.Verdict.Deny)
  end

  try Test.eq(verdict.call({"url": JSON.from("HTTPS://Docs.Example.com:443/a")}), Tools.Verdict.Allow)
  ok()
end

# A cancelled call closes its connection: the turn that is stopped does not leave a client open on the peer.
def test_a_cancelled_call_closes_its_connection() -> Result[Void]
  listener = try silent()
  ctx = try context(some(local().with(timeout_ms: 5000)))
  url = "http://127.0.0.1:#{TCP.local_port(listener)}/slow"
  call = Task.spawn do get(ctx, url) end
  socket = try TCP.accept(listener, 5000)
  try Test.assert((try TCP.read_line(socket, 5000)).start_with?("GET /slow"), "no request")
  Task.cancel(call)
  # The rest of the request, then the end of the input: the client closed, it did not just stop talking.
  ended = "open"
  while ended == "open"
    case TCP.read_line(socket, 3000)
      ok(_) -> nil
      error(e) -> ended = e.kind
    end
  end

  try Test.eq(ended, "net.eof")
  TCP.close(socket)
  TCP.close_listener(listener)
  ok()
end
