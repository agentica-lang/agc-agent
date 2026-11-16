## What a tool is, and what it needs to run.

import Approval from "approval"

MAX_OUTPUT_CHARS = 30000

struct Context
  root: String
  env: Fn[String, Result[String]]
  rules: Approval.Rules
  ## The tools after the base ones (MCP).
  tools: List[Tool] = []
  ## Folders outside `root` that `read_file` reads too: those of the session's skills.
  read_roots: List[String] = []
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

## A tool of an extension (skills now): the agent runs it with the session's marks, the names the extension noted so
## far, and keeps the mark it answers with.
struct TurnTool
  tool: Tool
  run: Fn[JSON.Value, List[String], TurnOutput]
end

struct TurnOutput
  output: Output
  mark: Optional[String] = none
end

## The input of a call as the record `codec` reads. It is strict: a key the record has not is an error, and so is a
## `null` for a required field or for `path`, so a `null` path is no "default path". A `null` for another optional
## field is the same as leaving it out.
def args[T](input: JSON.Value, codec: Codec[T]) -> Result[T]
  case JSON.node(input)
    JSON.Node.Object(fields) ->
      known = codec.members.map { |member| member.name }
      for key in fields.keys
        return error("invalid input: unknown field #{key}") if not known.include?(key)
        return error("invalid input: #{key} is null") if JSON.null?(fields[key]) and not nullable?(codec.members, key)
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

def nullable?(members: List[StructMember], key: String) -> Bool
  key != "path" and members.any? { |member| member.name == key and member.type.start_with?("Optional") }
end

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
