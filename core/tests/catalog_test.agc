import HTTP from "std/http"
import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import Catalog from "../src/catalog"
import Fake from "support/fake_llm"
import H from "support/harness"

# Prices of `gpt-5.1` in the pinned copy, in USD per million tokens: input 1.25, output 10, cache read 0.125.
TEXT_COST = (22.0 * 1.25 + 11.0 * 10.0) / 1_000_000.0
CACHED_COST = (30.0 * 1.25 + 7.0 * 10.0 + 120.0 * 0.125) / 1_000_000.0

# Each call's usage carries its cost and the turn's and session's so far; the snapshot has the session's, which a
# restart keeps; the window comes from the catalog, so no `GET /models` is made.
def test_a_session_counts_what_its_calls_cost() -> Result[Void]
  within_models do |served, dir|
    catalog = Catalog.start(Catalog.Options(url: served.url, cache: "#{dir}/models.json"))
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
    Test.eq(hits(dir), 1)
  end
end

# The catalog is fetched once and kept: a later start reads the file while it is fresh, and while offline when it is
# not; with neither there is no model. A model of another provider is not found.
def test_the_catalog_is_kept_and_read_offline() -> Result[Void]
  within_models do |served, dir|
    cache = "#{dir}/models.json"
    first = Catalog.start(Catalog.Options(url: served.url, cache: cache))
    opus = Catalog.find(first, "anthropic", "claude-opus-5-5")
    elsewhere = Catalog.find(first, "openai", "claude-opus-5-5")
    Catalog.stop(first)
    fresh = found(Catalog.Options(url: served.url, cache: cache), "openai", "gpt-5.1")
    offline = found(Catalog.Options(url: "http://127.0.0.1:1/api.json", cache: cache, ttl_ms: 0), "openai", "gpt-5.1")
    none_left = found(Catalog.Options(url: "off", cache: "#{dir}/nothing.json"), "openai", "gpt-5.1")
    try Test.eq(opus.map { |m| [m.reasoning, m.tools] }, some([true, true]))
    try Test.eq(opus.map { |m| m.window }, some(some(1_000_000)))
    try Test.eq(elsewhere, none)
    try Test.eq(fresh.map { |m| m.window }, some(some(272_000)))
    try Test.eq(offline.map { |m| m.id }, some("gpt-5.1"))
    try Test.eq(none_left, none)
    Test.eq(hits(dir), 1)
  end
end

# A prompt over a context tier is priced at the tier's prices.
def test_a_long_prompt_costs_its_tier() -> Result[Void]
  models = try Catalog.parse(String.from_bytes(try Fake.fixture("models_dev/api.json")).unwrap!)
  haiku = try models.find { |m| m.id == "claude-haiku-5-5" }
  short = Catalog.cost(haiku, LLM.Usage(input: 1000, output: 100))
  long = Catalog.cost(haiku, LLM.Usage(input: 2000, output: 100, cache_read: 100_000))
  near(
    [[short, long]],
    [[(1000.0 * 0.1 + 100.0 * 0.5) / 1_000_000.0, (2000.0 * 0.5 + 100.0 * 2.5 + 100_000.0 * 0.05) / 1_000_000.0]],
  )
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
  _ = Path.remove(dir)
  result
end

def answer(dir: String, json: Bytes, request: HTTP.Request) -> Result[HTTP.Response]
  try File.append_text("#{dir}/hits", "#{request.path}\n")
  ok(HTTP.Response(status: 200, headers: [HTTP.Header(name: "Content-Type", value: "application/json")], body: json))
end

def hits(dir: String) -> Int = File.read_text("#{dir}/hits").unwrap_or("").split("\n").select { |l| not l.empty? }.size

def found(options: Catalog.Options, provider: String, id: String) -> Optional[Catalog.Model]
  catalog = Catalog.start(options)
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
