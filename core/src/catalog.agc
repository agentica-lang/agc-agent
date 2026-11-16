## The models.dev catalog: the prices, window and flags of a model. Loaded in the background from the start: from
## `STATE_DIR/models.json` while it is less than a day old and from the same URL, else fetched from `FINN_MODELS_URL`
## (models.dev by default; `off` for no catalog at all, cache included), else the older file while offline. Until it is
## loaded, and with no catalog at all, a model has no cost and no window from it.
##
## A model is looked up by its provider id in models.dev and its own id: a model served elsewhere (a local
## llama-server) has no prices.

import HTTP from "std/http"
import Actor from "std/actor"
import LLM from "pkg/llm/llm"

URL = "https://models.dev/api.json"
CACHE_FILE = "models.json"
TTL_MS = 86_400_000
RETRY_MS = 600_000
FETCH_MS = 20_000
MAX_BYTES = 33_554_432
## The cache holds less than the fetched JSON; a bigger file is not read.
MAX_CACHE_BYTES = 67_108_864
CALL_MS = 5000
## The windows taken from the catalog; another value is a mistake of the data.
MIN_WINDOW = 1000
MAX_WINDOW = 2_000_000
## The highest price taken, in USD per million tokens; a model with a price above it, below 0 or not finite has none.
MAX_PRICE = 10_000.0

## Prices in USD per million tokens.
struct Prices
  input: Float = 0.0
  output: Float = 0.0
  cache_read: Float = 0.0
  cache_write: Float = 0.0
end

## Prices that apply once the prompt is over `above` tokens.
struct Tier
  above: Int
  prices: Prices
end

struct Model
  provider: String
  id: String
  prices: Optional[Prices] = none
  tiers: List[Tier] = []
  ## The longest prompt: `limit.input`, else `limit.context`.
  window: Optional[Int] = none
  reasoning: Bool = false
  tools: Bool = false
end

struct Options
  url: String = URL
  ## Where the catalog is kept between runs.
  cache: String
  ttl_ms: Int = TTL_MS
end

struct Catalog
  actor: Actor.Ref[State, Msg]
end

## Starts the catalog and its first load.
def start(options: Options) -> Catalog
  init = -> { State(options: options) }
  catalog = Catalog(actor: Actor.start(Actor.Behaviour(init: init, handle: &handle)))
  _ = Actor.cast(catalog.actor.address, Msg.Load)
  catalog
end

## Waits up to `timeout_ms` for a load to end; whether the catalog has models.
def wait(catalog: Catalog, timeout_ms: Int) -> Bool
  deadline = Time.monotonic_ms() + timeout_ms
  while Time.monotonic_ms() < deadline
    answer: Result[String] = Actor.call(catalog.actor.address, CALL_MS) do |reply| Msg.Ready(reply) end
    return answer == ok("loaded") if answer != ok("loading")

    Task.sleep(20)
  end

  false
end

def stop(catalog: Catalog) -> Void
  _ = Actor.stop(catalog.actor, 5000)
end

## The model `id` of `provider` (a models.dev id: `anthropic`, `openai`, `fireworks-ai`) from what is loaded now; none
## when the catalog has no such model or is not loaded (a failed load is tried again after `RETRY_MS`).
def find(catalog: Catalog, provider: String, id: String) -> Optional[Model]
  answer: Result[Optional[Model]] = Actor.call(catalog.actor.address, CALL_MS) do |reply|
    Msg.Find(Query(provider: provider, id: id, reply: reply))
  end

  case answer
    ok(found) -> found
    error(_) -> none
  end
end

## What a call cost in USD; none without prices.
def cost(model: Model, usage: LLM.Usage) -> Optional[Float]
  return none if model.prices.none?

  base = model.prices.unwrap!
  prompt = usage.input + usage.cache_read + usage.cache_write
  prices = base
  for tier in model.tiers
    if prompt > tier.above
      prices = tier.prices
    end
  end

  total = (
    (
      usage.input.to_f * prices.input +
      usage.output.to_f * prices.output +
      usage.cache_read.to_f * prices.cache_read +
      usage.cache_write.to_f * prices.cache_write
    ) /
    1_000_000.0
  )

  return none if not (total >= 0.0 and total < 1.0e300)

  some(total)
end

## The models of a models.dev `api.json`.
def parse(text: String) -> Result[List[Model]]
  json = try JSON.parse(text)
  out: List[Model] = []
  for provider in fields(json).keys.sort
    models = fields(JSON.get(fields(json)[provider], "models").unwrap_or(JSON.object({})))
    for id in models.keys.sort
      out = out.push(model(provider, id, models[id]))
    end
  end

  ok(out)
end

private

struct Query
  provider: String
  id: String
  reply: Channel[Optional[Model]]
end

enum Msg
  Find(Query)
  Load
  Loaded(Result[List[Model]])
  ## `loading`, `loaded`, or `none` when a load failed or the catalog is off.
  Ready(Channel[String])
end

struct State
  options: Options
  models: List[Model] = []
  loaded: Bool = false
  loading: Bool = false
  ## When a load found nothing: the next try waits `RETRY_MS`.
  failed_ms: Int = 0
end

struct Cached
  url: String
  fetched_ms: Int
  models: List[Model]
end

def handle(state: State, msg: Msg) -> Actor.Step[State]
  case msg
    Msg.Find(query) ->
      _ = Actor.reply(query.reply, lookup(state.models, query.provider, query.id))
      Actor.continue(load(state))
    Msg.Load -> Actor.continue(load(state))
    Msg.Loaded(result) ->
      case result
        ok(models) -> Actor.continue(state.with(models: models, loaded: true, loading: false))
        error(_) -> Actor.continue(state.with(loading: false, failed_ms: Time.monotonic_ms()))
      end

    Msg.Ready(reply) ->
      phase = "loading"
      if state.loaded
        phase = "loaded"
      elsif off?(state.options) or (state.failed_ms > 0 and not state.loading)
        phase = "none"
      end

      _ = Actor.reply(reply, phase)
      Actor.continue(state)
  end
end

def lookup(models: List[Model], provider: String, id: String) -> Optional[Model]
  case (models.find { |m| m.provider == provider and m.id == id })
    ok(found) -> some(found)
    error(_) -> none
  end
end

def off?(options: Options) -> Bool = options.url == "off" or options.url.empty?

# Starts a load in a task of its own, so a slow fetch holds up no one: not while one runs, not once loaded, not with
# the catalog off, and not until `RETRY_MS` after one failed.
def load(state: State) -> State
  return state if state.loaded or state.loading or off?(state.options)
  return state if state.failed_ms > 0 and Time.monotonic_ms() - state.failed_ms < RETRY_MS

  inbox: Channel[Msg] = Actor.inbox
  address = inbox.address
  options = state.options
  _ = Task.spawn { Actor.cast(address, Msg.Loaded(loaded_models(options))) }
  state.with(loading: true)
end

def loaded_models(options: Options) -> Result[List[Model]]
  cached = read_cache(options.cache)
    .select { |c| c.url == options.url }
    .map { |c| c.with(models: c.models.map(&bounded)) }

  fresh = cached.select { |c| c.fetched_ms <= Time.now_ms() and Time.now_ms() - c.fetched_ms < options.ttl_ms }
  return ok(fresh[0].models) if not fresh.empty?

  case fetch(options)
    ok(models) ->
      _ = write_cache(options.cache, Cached(url: options.url, fetched_ms: Time.now_ms(), models: models))
      ok(models)
    error(_) if not cached.empty? -> ok(cached[0].models)
    error(e) -> error(e)
  end
end

def fetch(options: Options) -> Result[List[Model]]
  http = HTTP.ClientOptions(timeout_ms: FETCH_MS, idle_timeout_ms: FETCH_MS, max_body_bytes: MAX_BYTES)
  response = try HTTP.get_response(options.url, http)
  return error("models.dev answered #{response.status}") if response.status != 200

  parse(try String.from_bytes(response.body))
end

def read_cache(path: String) -> List[Cached]
  case JSON.decode(read_big(path).unwrap_or(""), Cached)
    ok(cached) -> [cached]
    error(_) -> []
  end
end

# The cache can be over the 1 MiB of `File.read_text`.
def read_big(path: String) -> Result[String]
  bytes = try File.open(path) do |file|
    pieces: List[Bytes] = []
    size = 0
    while true
      piece = try File.read_bytes(file, 1_048_576)
      break if piece.size == 0

      size = size + piece.size
      return error("the cache is over #{MAX_CACHE_BYTES} bytes") if size > MAX_CACHE_BYTES

      pieces = pieces.push(piece)
    end

    ok(Bytes.concat(pieces))
  end

  String.from_bytes(bytes)
end

# `File.replace` swaps the whole file at once, but only a file that is there: a new one is made only the user's.
def write_cache(path: String, cached: Cached) -> Result[Void]
  if not File.stat(path).ok?
    handle = try File.open(path, "create_private")
    try File.close(handle)
  end

  File.replace(path, JSON.encode(cached).bytes)
end

def fields(json: JSON.Value) -> Map[String, JSON.Value]
  case JSON.node(json)
    JSON.Node.Object(map) -> map
    _ -> {}
  end
end

def model(provider: String, id: String, json: JSON.Value) -> Model
  cost = JSON.get(json, "cost").unwrap_or(JSON.object({}))
  limit = JSON.get(json, "limit").unwrap_or(JSON.object({}))
  window = int(limit, "input")
  if window.none?
    window = int(limit, "context")
  end

  prices: Optional[Prices] = none
  if fields(cost).has_key?("input") and fields(cost).has_key?("output")
    prices = some(prices_of(cost, Prices()))
  end

  model = Model(
    provider: provider,
    id: id,
    prices: prices,
    tiers: tiers(cost, prices.unwrap_or(Prices())),
    window: window,
    reasoning: flag(json, "reasoning"),
    tools: flag(json, "tool_call"),
  )

  bounded(model)
end

# A model as the catalog may give it, from models.dev or the cache file: a window out of range is none, and a price out
# of range leaves the model with no prices at all.
def bounded(model: Model) -> Model
  window = model.window
  if window.unwrap_or(0) < MIN_WINDOW or window.unwrap_or(0) > MAX_WINDOW
    window = none
  end

  all = option_list(model.prices) + model.tiers.map { |t| t.prices }
  sane = all.all? { |p| [p.input, p.output, p.cache_read, p.cache_write].all? { |v| v >= 0.0 and v <= MAX_PRICE } }
  return model.with(window: window) if sane

  model.with(window: window, prices: none, tiers: [])
end

def option_list(value: Optional[Prices]) -> List[Prices]
  case value
    some(p) -> [p]
    none -> []
  end
end

# The prices `cost` gives, each missing one from `base`; a missing cache read costs as input.
def prices_of(cost: JSON.Value, base: Prices) -> Prices
  input = number(cost, "input").unwrap_or(base.input)
  cache_read = base.cache_read
  if fields(cost).has_key?("input")
    cache_read = input
  end

  Prices(
    input: input,
    output: number(cost, "output").unwrap_or(base.output),
    cache_read: number(cost, "cache_read").unwrap_or(cache_read),
    cache_write: number(cost, "cache_write").unwrap_or(base.cache_write),
  )
end

# The context tiers, by size, each from the base prices with the fields it gives; the older `context_over_200k` is a
# tier above 200000 tokens, when there is no context tier (an entry with both gives the same tier twice).
def tiers(cost: JSON.Value, base: Prices) -> List[Tier]
  out: List[Tier] = []
  listed: List[JSON.Value] = JSON.list(JSON.get(cost, "tiers").unwrap_or(JSON.array([]))).unwrap_or([])
  for tier in listed
    shape = JSON.get(tier, "tier").unwrap_or(JSON.object({}))
    if JSON.string(JSON.get(shape, "type").unwrap_or(JSON.from(""))) == ok("context")
      case int(shape, "size")
        some(size) -> out = out.push(Tier(above: size, prices: prices_of(tier, base)))
        none -> nil
      end
    end
  end

  case JSON.get(cost, "context_over_200k")
    ok(over) if JSON.kind(over) == "object" and out.empty? ->
      out = out.push(Tier(above: 200_000, prices: prices_of(over, base)))
    _ -> nil
  end

  out.sort_by { |t| t.above }
end

# A price; one out of range (not finite, below 0 or over `MAX_PRICE`) is -1, which `bounded` refuses.
def number(json: JSON.Value, key: String) -> Optional[Float]
  case JSON.get(json, key)
    ok(value) ->
      case JSON.float(value)
        ok(n) if n >= 0.0 and n <= MAX_PRICE -> some(n)
        ok(_) -> some(-1.0)
        error(_) -> none
      end

    error(_) -> none
  end
end

def int(json: JSON.Value, key: String) -> Optional[Int]
  case JSON.get(json, key)
    ok(value) ->
      case JSON.int(value)
        ok(n) if n > 0 -> some(n)
        _ -> none
      end

    error(_) -> none
  end
end

def flag(json: JSON.Value, key: String) -> Bool
  case JSON.get(json, key)
    ok(value) -> JSON.bool(value).unwrap_or(false)
    error(_) -> false
  end
end
