## Code mode: the tool `run_script` runs a short Python script in Monty's sandbox, where every base tool is a plain
## function (`read_file(path="a.txt")`). A call suspends the script and goes through the same checks and approvals
## as a direct call; a denial raises PermissionError, another failure RuntimeError. Only what the script prints and
## its last value come back to the model.

import Monty from "pkg/monty/monty"
import Spec from "spec"

NAME = "run_script"

struct Settings
  ## The words that start a worker, found (and fetched on first use) when a script runs.
  worker: Fn[Result[List[String]]]
  limits: Monty.Limits
end

## What a call of a tool from a script came to.
enum Reply
  Done(String)
  Denied(String)
  Failed(String)
end

struct ScriptArgs
  code: String
end

## The tool the model sees, with the signatures of the functions a script can call.
def spec(tools: List[Spec.Tool]) -> Spec.Tool
  Spec.Tool(
    name: NAME,
    description: description(tools),
    input_schema: JSON.schema(ScriptArgs),
    asks: false,
    run: ->(_ctx: Spec.Context, _input: JSON.Value) { error("run_script runs in the agent") },
    target: &target,
  )
end

## The first line of the script, for the notices.
def target(_ctx: Spec.Context, input: JSON.Value) -> Result[String]
  args = try Spec.args(input, ScriptArgs.codec)
  ok(args.code.strip.split("\n").first)
end

## Runs the script of `input`; `call` runs one tool call by name and input, approvals included.
def run(settings: Settings, input: JSON.Value, names: List[String], call: Fn[String, JSON.Value, Reply]) -> Spec.Output
  case Spec.args(input, ScriptArgs.codec)
    ok(args) -> Spec.output(script(settings, args.code, names, call))
    error(e) -> Spec.Output(text: e.message, is_error: true)
  end
end

private

def script(
  settings: Settings,
  code: String,
  names: List[String],
  call: Fn[String, JSON.Value, Reply],
) -> Result[String]
  words = try settings.worker.call()
  host = ->(c: Monty.Call) { answer(c, call) }
  outcome = try Monty.run(words, code, names, host, settings.limits)
  text = outcome.output
  case JSON.string(outcome.value)
    ok(value) -> text = joined(text, value)
    error(_) if not JSON.null?(outcome.value) -> text = joined(text, JSON.encode(outcome.value))
    error(_) -> nil
  end

  for raised in option_list(outcome.error)
    return error(joined(text, raised))
  end

  ok(text)
end

def answer(c: Monty.Call, call: Fn[String, JSON.Value, Reply]) -> Monty.Answer
  if not c.args.empty?
    return Monty.Answer.Raise("TypeError", "#{c.name}() takes keyword arguments only, as #{c.name}(path='a.txt')")
  end

  case call.call(c.name, JSON.object(c.kwargs))
    Reply.Done(text) -> Monty.Answer.Value(text)
    Reply.Denied(text) -> Monty.Answer.Raise("PermissionError", text)
    Reply.Failed(text) -> Monty.Answer.Raise("RuntimeError", text)
  end
end

def joined(text: String, more: String) -> String
  return more if text == ""
  return "#{text}#{more}" if text.end_with?("\n")

  "#{text}\n#{more}"
end

def description(tools: List[Spec.Tool]) -> String
  signatures = tools.map { |tool| "- #{signature(tool)}: #{tool.description}" }.join("\n")
  (
    "Run a short Python script (a sandbox: no files, network or imports beyond json, re, math and the like) that " +
    "calls the tools below as functions with keyword arguments, and returns only what you print and the value of " +
    "its last line. Use it to chain calls and cut their results down. Each call asks for approval as a direct call " +
    "does; a denied call raises PermissionError, a failed one RuntimeError. Every result is a string.\n" +
    signatures
  )
end

# `read_file(path: str, offset: int = None, limit: int = None)`, from the input schema.
def signature(tool: Spec.Tool) -> String
  properties = JSON.get(tool.input_schema, "properties").unwrap_or(JSON.object({}))
  none_given: List[JSON.Value] = []
  required = JSON.list(JSON.get(tool.input_schema, "required").unwrap_or(JSON.array(none_given))).unwrap_or(none_given)
  names = required.map { |name| JSON.string(name).unwrap_or("") }
  needed: List[String] = []
  optional: List[String] = []
  case JSON.node(properties)
    JSON.Node.Object(fields) ->
      for key in fields.keys
        kind = python_type(fields[key])
        if names.include?(key)
          needed = needed.push("#{key}: #{kind}")
        else
          optional = optional.push("#{key}: #{kind} = None")
        end
      end

    _ -> nil
  end

  "#{tool.name}(#{(needed + optional).join(", ")})"
end

# The type of a property; an optional one is `anyOf` the type and null.
def python_type(schema: JSON.Value) -> String
  none_given: List[JSON.Value] = []
  for choice in JSON.list(JSON.get(schema, "anyOf").unwrap_or(JSON.null())).unwrap_or(none_given)
    kind = python_type(choice)
    return kind if kind != "None"
  end

  kind = JSON.string(JSON.get(schema, "type").unwrap_or(JSON.null())).unwrap_or("")
  case kind
    "null" -> "None"
    "string" -> "str"
    "integer" -> "int"
    "number" -> "float"
    "boolean" -> "bool"
    _ -> "object"
  end
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
