## The request body helpers the OpenAI-format wires share. Pure.

## A bigger magnitude than this is not a number a provider takes in a schema: 2^53, the largest integer a double holds.
MAX_SCHEMA_BOUND = 9007199254740992

## The schema of a tool's input as a provider takes it. An `Int` field's schema has the 64-bit bounds, which providers
## refuse as too large, so a `minimum` or `maximum` past MAX_SCHEMA_BOUND is left out; every other key stays.
def provider_schema(schema: JSON.Value) -> JSON.Value
  case JSON.node(schema)
    JSON.Node.Object(fields) ->
      out: Map[String, JSON.Value] = {}
      for key in fields.keys
        value = fields[key]
        if not huge_bound?(key, value)
          out = out.put(key, provider_schema(value))
        end
      end

      JSON.object(out)
    JSON.Node.Array(items) -> JSON.array(items.map { |item| provider_schema(item) })
    _ -> schema
  end
end

## `body` with the fields of `extra` put in last. An object in `extra` whose key holds an object in `body` is merged
## into it, one level deep (its own keys win), so `reasoning: {summary: "auto"}` keeps the `effort` of the request.
def merge_extra(body: Map[String, JSON.Value], extra: Map[String, JSON.Value]) -> Map[String, JSON.Value]
  merged = body
  for key in extra.keys
    value = extra[key]
    case merged.get(key)
      some(old) -> merged = merged.put(key, merge_objects(old, value))
      none -> merged = merged.put(key, value)
    end
  end

  merged
end

private

def huge_bound?(key: String, value: JSON.Value) -> Bool
  return false if key != "minimum" and key != "maximum"
  bound = JSON.int(value).unwrap_or(0)
  bound > MAX_SCHEMA_BOUND or bound < -MAX_SCHEMA_BOUND
end

def merge_objects(old: JSON.Value, value: JSON.Value) -> JSON.Value
  case JSON.node(old)
    JSON.Node.Object(fields) ->
      case JSON.node(value)
        JSON.Node.Object(more) ->
          out = fields
          for key in more.keys
            out = out.put(key, more[key])
          end

          JSON.object(out)
        _ -> value
      end

    _ -> value
  end
end
