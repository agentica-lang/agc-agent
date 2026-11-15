## What a tool is, and what it needs to run.

import Approval from "approval"

MAX_OUTPUT_CHARS = 30000

struct Context
  root: String
  env: Fn[String, Result[String]]
  rules: Approval.Rules
end

struct Output
  text: String
  is_error: Bool
end

struct Tool
  name: String
  description: String
  input_schema: JSON.Value
  asks: Bool
  run: Fn[Context, JSON.Value, Result[String]]
  target: Fn[Context, JSON.Value, Result[String]]
end

## The input of a call as the record `codec` reads. It is strict: a key the record has not and a `null` are errors, so
## a `null` path is no "default path" and a misspelled key is not dropped.
def args[T](input: JSON.Value, codec: Codec[T]) -> Result[T]
  case JSON.node(input)
    JSON.Node.Object(fields) ->
      known = codec.members.map { |member| member.name }
      for key in fields.keys
        return error("invalid input: unknown field #{key}") if not known.include?(key)
        return error("invalid input: #{key} is null") if JSON.null?(fields[key])
      end

      decoded(input, codec)
    _ -> error("invalid input: expected a JSON object")
  end
end

def output(result: Result[String]) -> Output
  case result
    ok(text) -> Output(text: cap(text), is_error: false)
    error(e) -> Output(text: cap(e.message), is_error: true)
  end
end

private

def decoded[T](input: JSON.Value, codec: Codec[T]) -> Result[T]
  case codec.decode(input)
    ok(value) -> ok(value)
    error(e) -> error("invalid input: #{e.message}")
  end
end

def cap(text: String) -> String
  return text if text.length <= MAX_OUTPUT_CHARS

  shown = text.slice(0, MAX_OUTPUT_CHARS)
  "#{shown}\n[output cut: #{text.length} characters, the first #{MAX_OUTPUT_CHARS} are shown]"
end
