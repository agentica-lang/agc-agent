## What a tool is, and what it needs to run.

MAX_OUTPUT_CHARS = 30000

struct Context
  root: String
  env: Fn[String, Result[String]]
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

def args[T](input: JSON.Value, codec: Codec[T]) -> Result[T]
  case codec.decode(input)
    ok(value) -> ok(value)
    error(e) -> error("invalid input: #{e.message}")
  end
end

def output(result: Result[String]) -> Output
  case result
    ok(text) -> Output(text: cap(text), is_error: false)
    error(e) -> Output(text: cap(e.message), is_error: true)
  end
end

private

def cap(text: String) -> String
  return text if text.length <= MAX_OUTPUT_CHARS

  shown = text.slice(0, MAX_OUTPUT_CHARS)
  "#{shown}\n[output cut: #{text.length} characters, the first #{MAX_OUTPUT_CHARS} are shown]"
end
