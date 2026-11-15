## The request body helpers the OpenAI-format wires share. Pure.

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
