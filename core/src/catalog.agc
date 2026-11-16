## The models.dev catalog: the prices, window and flags of a model. Fetched from `FINN_MODELS_URL` (models.dev by
## default, `off` for none) on first use, kept in `STATE_DIR/models.json` for a day, and read from there while offline;
## no catalog at all only means no cost and no window from it.
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
CALL_MS = 60_000

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

def start(options: Options) -> Catalog
  init = -> { State(options: options) }
  Catalog(actor: Actor.start(Actor.Behaviour(init: init, handle: &handle)))
end

def stop(catalog: Catalog) -> Void
  _ = Actor.stop(catalog.actor, 5000)
end

## The model `id` of `provider` (a models.dev id: `anthropic`, `openai`, `fireworks-ai`); none when the catalog has no
## such model or none could be read.
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
    usage.input.to_f * prices.input +
    usage.output.to_f * prices.output +
    usage.cache_read.to_f * prices.cache_read +
    usage.cache_write.to_f * prices.cache_write
  )

  some(total / 1_000_000.0)
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
end

struct State
  options: Options
  models: List[Model] = []
  loaded: Bool = false
  ## When a load found nothing: the next try waits `RETRY_MS`.
  failed_ms: Int = 0
end

struct Cached
  fetched_ms: Int
  models: List[Model]
end

def handle(state: State, msg: Msg) -> Actor.Step[State]
  case msg
    Msg.Find(query) ->
      ready = loaded(state)
      _ = Actor.reply(query.reply, lookup(ready.models, query.provider, query.id))
      Actor.continue(ready)
  end
end

def lookup(models: List[Model], provider: String, id: String) -> Optional[Model]
  case (models.find { |m| m.provider == provider and m.id == id })
    ok(found) -> some(found)
    error(_) -> none
  end
end

def loaded(state: State) -> State
  return state if state.loaded
  return state if state.failed_ms > 0 and Time.monotonic_ms() - state.failed_ms < RETRY_MS

  cached = read_cache(state.options.cache)
  fresh = cached.select { |c| Time.now_ms() - c.fetched_ms < state.options.ttl_ms }
  return state.with(models: fresh[0].models, loaded: true) if not fresh.empty?

  case fetch(state.options)
    ok(models) ->
      _ = write_cache(state.options.cache, Cached(fetched_ms: Time.now_ms(), models: models))
      state.with(models: models, loaded: true)
    error(_) if not cached.empty? -> state.with(models: cached[0].models, loaded: true)
    error(_) -> state.with(failed_ms: Time.monotonic_ms())
  end
end

def fetch(options: Options) -> Result[List[Model]]
  return error("the catalog is off") if options.url == "off" or options.url.empty?

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
    while true
      piece = try File.read_bytes(file, 1_048_576)
      break if piece.size == 0

      pieces = pieces.push(piece)
    end

    ok(Bytes.concat(pieces))
  end

  String.from_bytes(bytes)
end

# `File.replace` swaps the whole file at once, but only a file that is there.
def write_cache(path: String, cached: Cached) -> Result[Void]
  if not File.stat(path).ok?
    try File.write_text(path, "")
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
    prices = some(prices_of(cost))
  end

  Model(
    provider: provider,
    id: id,
    prices: prices,
    tiers: tiers(cost),
    window: window,
    reasoning: flag(json, "reasoning"),
    tools: flag(json, "tool_call"),
  )
end

def prices_of(cost: JSON.Value) -> Prices
  Prices(
    input: number(cost, "input"),
    output: number(cost, "output"),
    cache_read: number(cost, "cache_read"),
    cache_write: number(cost, "cache_write"),
  )
end

# The context tiers, by size; the older `context_over_200k` is a tier above 200000 tokens.
def tiers(cost: JSON.Value) -> List[Tier]
  out: List[Tier] = []
  listed: List[JSON.Value] = JSON.list(JSON.get(cost, "tiers").unwrap_or(JSON.array([]))).unwrap_or([])
  for tier in listed
    shape = JSON.get(tier, "tier").unwrap_or(JSON.object({}))
    if JSON.string(JSON.get(shape, "type").unwrap_or(JSON.from(""))) == ok("context")
      case int(shape, "size")
        some(size) -> out = out.push(Tier(above: size, prices: prices_of(tier)))
        none -> nil
      end
    end
  end

  case JSON.get(cost, "context_over_200k")
    ok(over) if JSON.kind(over) == "object" -> out = out.push(Tier(above: 200_000, prices: prices_of(over)))
    _ -> nil
  end

  out.sort_by { |t| t.above }
end

def number(json: JSON.Value, key: String) -> Float
  case JSON.get(json, key)
    ok(value) -> JSON.float(value).unwrap_or(0.0)
    error(_) -> 0.0
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
