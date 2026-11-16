import HTTP from "std/http"
import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import Agent from "../src/agent"
import Catalog from "../src/catalog"
import Fake from "support/fake_llm"
import H from "support/harness"

# Prices of `gpt-5.1` in the pinned copy, in USD per million tokens: input 1.25, output 10, cache read 0.125.
TEXT_COST = (22.0 * 1.25 + 11.0 * 10.0) / 1_000_000.0
CACHED_COST = (30.0 * 1.25 + 7.0 * 10.0 + 120.0 * 0.125) / 1_000_000.0

# Each call's usage carries its cost and the turn's and session's so far; the snapshot has the session's, which a
# restart keeps; the window comes from the catalog, so no `GET /models` is made. The first turn waits for a catalog
# that takes a second to load.
def test_a_session_counts_what_its_calls_cost() -> Result[Void]
  within_models do |served, dir|
    slow = served.url.replace("/api.json", "/slow.json")
    catalog = Catalog.start(Catalog.Options(url: slow, cache: "#{dir}/models.json"))
    setup = H.Setup(
      replies: ["text.sse", "text_cached.sse"],
      context_window: 0,
      model: "gpt-5.1",
      catalog: some(catalog),
    )

    result = H.using(setup) do |h|
      id = try H.new_session(h)
      a = try H.subscribe(h, id)
      _ = try H.send(h, id, "Hi.")
      a = try H.until(a, Protocol.EventKind.TurnFinished)
      _ = try H.send(h, id, "Again.")
      a = try H.until(a, Protocol.EventKind.TurnFinished)
      H.close(a)
      costs = usages(a).map { |u| [u.cost, u.turn_cost, u.session_cost] }
      try near(costs, [[TEXT_COST, TEXT_COST, TEXT_COST], [CACHED_COST, CACHED_COST, TEXT_COST + CACHED_COST]])
      try near([[(try H.session(h, id)).cost]], [[TEXT_COST + CACHED_COST]])
      try Test.eq((try H.next_request(h)).path, "/v1/chat/completions")
      H.restarted(h, setup, "") do |again| near([[(try H.session(again, id)).cost]], [[TEXT_COST + CACHED_COST]]) end
    end

    Catalog.stop(catalog)
    try result
    Test.eq(hits(dir), ["/slow.json"])
  end
end

# A first turn that the catalog is too slow for has no window from the API (-1); once the catalog has loaded, the next
# turn asks again: a local server's `/props` first.
def test_a_window_the_api_did_not_give_is_asked_again() -> Result[Void]
  within_models do |served, dir|
    slower = served.url.replace("/api.json", "/slower.json")
    catalog = Catalog.start(Catalog.Options(url: slower, cache: "#{dir}/models.json"))
    setup = H.Setup(
      replies: ["models_none.json", "models_none.json", "text.sse", "props_small.json", "text.sse"],
      context_window: 0,
      props: true,
      model: "gpt-5.1",
      catalog: some(catalog),
    )

    result = H.using(setup) do |h|
      id = try H.new_session(h)
      a = try H.subscribe(h, id)
      _ = try H.send(h, id, "Hi.")
      a = try H.until(a, Protocol.EventKind.TurnFinished)
      try Test.assert(Catalog.wait(catalog, 10_000), "the catalog did not load")
      _ = try H.send(h, id, "Again.")
      a = try H.until(a, Protocol.EventKind.TurnFinished)
      H.close(a)
      try Test.eq(usages(a).map { |u| u.cost.some? }, [false, true])
      paths: List[String] = []
      for _ in 1..5
        paths = paths.push((try H.next_request(h)).path)
      end

      Test.eq(paths, ["/props", "/v1/models", "/v1/chat/completions", "/props", "/v1/chat/completions"])
    end

    Catalog.stop(catalog)
    result
  end
end

# The addresses of this machine ask a llama-server's `/props` first; another address does not.
def test_the_local_addresses() -> Result[Void]
  urls = [
    "http://127.0.0.1:8080/props", "http://localhost:8080/props", "http://[::1]:8080/props",
    "http://0.0.0.0:8080/props", "http://10.0.0.1:8080/props", "https://api.openai.com/props", "",
  ]

  Test.eq(urls.map { |url| Agent.local?(url) }, [true, true, true, true, false, false, false])
end

# A local llama-server says the window it runs with: `/props` goes before the catalog.
def test_a_local_server_gives_the_window_before_the_catalog() -> Result[Void]
  within_models do |served, dir|
    catalog = Catalog.start(Catalog.Options(url: served.url, cache: "#{dir}/models.json"))
    try Test.assert(Catalog.wait(catalog, 10_000), "the catalog did not load")
    setup = H.Setup(
      replies: ["props_small.json", "text.sse"],
      context_window: 0,
      props: true,
      model: "gpt-5.1",
      catalog: some(catalog),
    )

    result = H.using(setup) do |h|
      id = try H.new_session(h)
      a = try H.subscribe(h, id)
      _ = try H.send(h, id, "Hi.")
      a = try H.until(a, Protocol.EventKind.TurnFinished)
      H.close(a)
      props = try H.next_request(h)
      Test.eq([props.method, props.path], ["GET", "/props"])
    end

    Catalog.stop(catalog)
    result
  end
end

# The catalog is fetched once and kept (only the user's): a later start reads the file while it is fresh and from the
# same URL, and while offline when it is not; `off` reads nothing, not even the file. A model of another provider is
# not found.
def test_the_catalog_is_kept_and_read_offline() -> Result[Void]
  within_models do |served, dir|
    cache = "#{dir}/models.json"
    opus = found(Catalog.Options(url: served.url, cache: cache), "anthropic", "claude-opus-5-5")
    elsewhere = found(Catalog.Options(url: served.url, cache: cache), "openai", "claude-opus-5-5")
    fresh = found(Catalog.Options(url: served.url, cache: cache), "openai", "gpt-5.1")
    try File.write_text("#{dir}/down", "")
    offline = found(Catalog.Options(url: served.url, cache: cache, ttl_ms: 0), "openai", "gpt-5.1")
    _ = Path.remove("#{dir}/down")
    other = served.url.replace("/api.json", "/other.json")
    try Test.eq(
      found(Catalog.Options(url: other, cache: cache), "openai", "gpt-5.1").map { |m| m.id },
      some("gpt-5.1"),
    )

    off = found(Catalog.Options(url: "off", cache: cache), "openai", "gpt-5.1")
    try Test.eq(opus.map { |m| [m.reasoning, m.tools] }, some([true, true]))
    try Test.eq(opus.map { |m| m.window }, some(some(1_000_000)))
    try Test.eq(elsewhere, none)
    try Test.eq(fresh.map { |m| m.window }, some(some(272_000)))
    try Test.eq(offline.map { |m| m.id }, some("gpt-5.1"))
    try Test.eq(off, none)
    try Test.eq((try File.stat(cache)).mode % 512, 384)
    Test.eq(hits(dir), ["/api.json", "/other.json"])
  end
end

# A fetch that hangs holds up no one: `find` answers at once, with nothing while the catalog loads.
def test_a_slow_fetch_does_not_hold_up_find() -> Result[Void]
  within_models do |served, dir|
    slow = served.url.replace("/api.json", "/slow.json")
    catalog = Catalog.start(Catalog.Options(url: slow, cache: "#{dir}/models.json"))
    began = Time.monotonic_ms()
    model = Catalog.find(catalog, "openai", "gpt-5.1")
    took = Time.monotonic_ms() - began
    try Test.assert(Catalog.wait(catalog, 10_000), "the catalog did not load")
    Catalog.stop(catalog)
    try Test.eq(model, none)
    Test.assert(took < 1000, "find took #{took} ms")
  end
end

# A prompt over a context tier is priced at the tier's prices; one of exactly its size is not. An entry with `tiers`
# and the older `context_over_200k` has only the tiers.
def test_a_long_prompt_costs_its_tier() -> Result[Void]
  models = try Catalog.parse(String.from_bytes(try Fake.fixture("models_dev/api.json")).unwrap!)
  haiku = try models.find { |m| m.id == "claude-haiku-5-5" }
  short = Catalog.cost(haiku, LLM.Usage(input: 1000, output: 100))
  at = Catalog.cost(haiku, LLM.Usage(input: 100_000))
  over = Catalog.cost(haiku, LLM.Usage(input: 100_001))
  try near(
    [[short, at, over]],
    [[(1000.0 * 0.1 + 100.0 * 0.5) / 1_000_000.0, (100_000.0 * 0.1) / 1_000_000.0, (100_001.0 * 0.5) / 1_000_000.0]],
  )

  terra = try models.find { |m| m.id == "gpt-6.1-terra" }
  try Test.eq(terra.tiers.map { |t| t.above }, [272_000])
  near([[Catalog.cost(terra, LLM.Usage(input: 250_000))]], [[(250_000.0 * 1.0) / 1_000_000.0]])
end

# A price that is not a number from 0 to 10000 drops the model's prices (a cost of `1e308` tokens would not encode);
# a missing cache read costs as input; a tier changes only the prices it gives.
def test_prices_out_of_range_are_dropped() -> Result[Void]
  text = <<~JSON
    {"p": {"models": {
      "huge": {"cost": {"input": 1e308, "output": 1}},
      "negative": {"cost": {"input": 1, "output": -2}},
      "tier": {"cost": {"input": 1, "output": 2, "tiers": [{"input": -1, "tier": {"type": "context", "size": 9}}]}},
      "plain": {"cost": {"input": 3, "output": 4, "cache_write": 5,
        "tiers": [{"output": 8, "tier": {"type": "context", "size": 1000}}]}}
    }}}
  JSON

  models = try Catalog.parse(text)
  try Test.eq(
    models.map { |m| [m.id, m.prices.some?.to_s, m.tiers.size.to_s] },
    [["huge", "false", "0"], ["negative", "false", "0"], ["plain", "true", "1"], ["tier", "false", "0"]],
  )

  plain = try models.find { |m| m.id == "plain" }
  try Test.eq(plain.prices, some(Catalog.Prices(input: 3.0, output: 4.0, cache_read: 3.0, cache_write: 5.0)))
  Test.eq(plain.tiers[0].prices, Catalog.Prices(input: 3.0, output: 8.0, cache_read: 3.0, cache_write: 5.0))
end

# The cache file goes through the same checks, and one fetched in the future is stale.
def test_a_cache_out_of_range_is_checked() -> Result[Void]
  within_models do |served, dir|
    cache = "#{dir}/models.json"
    now = Time.now_ms()
    bad = <<~JSON
      {"url": "#{served.url}", "fetched_ms": #{now},
        "models": [{"provider": "openai", "id": "gpt-5.1", "prices": {"input": -5.0, "output": 1.0, "cache_read": 0.0, "cache_write": 0.0}, "tiers": [],
          "window": 99000000, "reasoning": false, "tools": false}]}
    JSON

    try File.write_text(cache, bad)
    checked = found(Catalog.Options(url: served.url, cache: cache), "openai", "gpt-5.1")
    try Test.eq(checked.map { |m| [m.prices.some?, m.window.some?] }, some([false, false]))
    try Test.eq(hits(dir), [])
    try File.write_text(cache, bad.replace("\"fetched_ms\": #{now}", "\"fetched_ms\": 99999999999999"))
    future = found(Catalog.Options(url: served.url, cache: cache), "openai", "gpt-5.1")
    try Test.eq(future.map { |m| m.prices.some? }, some(true))
    Test.eq(hits(dir), ["/api.json"])
  end
end

# A window out of 1000 to 2000000 tokens is a mistake of the data: none.
def test_an_odd_window_is_left_out() -> Result[Void]
  text = "{\"p\": {\"models\": {\"a\": {\"limit\": {\"context\": 10}}, \"b\": {\"limit\": {\"context\": 9000000}}}}}"
  Test.eq((try Catalog.parse(text)).map { |m| m.window }, [none, none])
end

private

struct Served
  http: HTTP.Server
  url: String
end

def within_models(body: Fn[Served, String, Result[Void]]) -> Result[Void]
  tmp = System.env("TMPDIR").unwrap_or("/tmp")
  dir = "#{tmp}/core-models-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  json = try Fake.fixture("models_dev/api.json")
  handler = ->(request: HTTP.Request) { answer(dir, json, request) }
  http = try HTTP.serve("127.0.0.1", 0, HTTP.app(handler))
  result = body.call(Served(http: http, url: "http://127.0.0.1:#{HTTP.local_port(http)}/api.json"), dir)
  HTTP.close_server(http)
  settled()
  _ = Path.remove(dir)
  result
end

# `/slow.json` answers after 1 s and `/slower.json` after 3 s; every path fails while the file `down` is there.
# Waits up to a second for the tasks of the run to end: the server's connections close a moment after the server.
def settled() -> Void
  deadline = Time.monotonic_ms() + 1000
  while Task.pending_count() > 0 and Time.monotonic_ms() < deadline
    Task.sleep(10)
  end
end

def answer(dir: String, json: Bytes, request: HTTP.Request) -> Result[HTTP.Response]
  return ok(HTTP.Response(status: 503, headers: [], body: "".bytes)) if File.stat("#{dir}/down").ok?

  try File.append_text("#{dir}/hits", "#{request.path}\n")
  if request.path == "/slow.json"
    Task.sleep(1000)
  elsif request.path == "/slower.json"
    Task.sleep(3000)
  end

  ok(HTTP.Response(status: 200, headers: [HTTP.Header(name: "Content-Type", value: "application/json")], body: json))
end

def hits(dir: String) -> List[String]
  File.read_text("#{dir}/hits").unwrap_or("").split("\n").select { |l| not l.empty? }
end

def found(options: Catalog.Options, provider: String, id: String) -> Optional[Catalog.Model]
  catalog = Catalog.start(options)
  _ = Catalog.wait(catalog, 10_000)
  model = Catalog.find(catalog, provider, id)
  Catalog.stop(catalog)
  model
end

def usages(sub: H.Sub) -> List[Protocol.Usage]
  out: List[Protocol.Usage] = []
  for seen in sub.seen
    case seen.event
      Protocol.Event.Usage(usage) -> out = out.push(usage)
      _ -> nil
    end
  end

  out
end

# Costs are sums of floats: equal to a billionth of a dollar.
def near(actual: List[List[Optional[Float]]], expected: List[List[Float]]) -> Result[Void]
  message = "#{actual.inspect} is not #{expected.inspect}"
  try Test.eq(actual.map { |row| row.size }, expected.map { |row| row.size })
  for i in 0...actual.size
    for j in 0...actual[i].size
      value = try actual[i][j].to_result(message)
      try Test.assert((value - expected[i][j]).abs < 0.000000001, message)
    end
  end

  ok()
end
