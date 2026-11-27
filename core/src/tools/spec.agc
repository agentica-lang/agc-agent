## What a tool is, and what it needs to run.

MAX_OUTPUT_CHARS = 30000
## The kind of the error of a call that an extension stopped (`Before`).
BLOCKED = "tool.blocked"

## Whether a call runs, waits for an answer or is refused: the answer of the approval extension.
enum Verdict
  Allow
  Ask
  Deny
end

struct Context
  root: String
  env: Fn[String, Result[String]]
  ## The paths (relative to `root`) that `glob` and `grep` leave out: those an approval rule hides.
  hidden: Optional[Fn[String, Bool]] = none
  ## The tools after the base ones (MCP), and those that come later (MCP servers still listing at the start), given
  ## the session folder: the project servers belong to it.
  tools: List[Tool] = []
  late: Optional[Fn[String, List[Tool]]] = none
  ## Folders outside `root` that `read_file` reads too: those of the session's skills.
  read_roots: List[String] = []
  ## A test seam: makes the diff a client shows for a call (the tool and its input) in place of the real one.
  diff: Optional[Fn[String, JSON.Value, String]] = none
  ## What the extensions put around the run of a tool (`Core.wrap_tools`), by the tool's name: never its target or
  ## `asks`, which the approval decides on.
  wrap: Optional[Fn[String, Run, Run]] = none
  ## What the extensions make of the input of a call before anything else sees it (`Core.Event.ToolBefore`).
  before: Optional[Before] = none
  ## The id of the session, none outside one.
  session: Optional[String] = none
  ## The file tools reach only the session folder; off, any path (the rules of approval still apply).
  confine: Bool = false
end

type Run = Fn[Context, JSON.Value, Result[String]]

## Gets the context, the tool's name and the input of a call, and gives the input it runs on; an error of the kind
## `BLOCKED` when an extension stops it.
type Before = Fn[Context, String, JSON.Value, Result[JSON.Value]]

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

def output(result: Result[String], capped: Bool = true) -> Output
  made = case result
    ok(text) -> Output(text: text, is_error: false)
    error(e) -> Output(text: e.message, is_error: true)
  end

  return bounded(made) if capped

  made
end

def bounded(output: Output) -> Output = output.with(text: cap(output.text))

## `ctx` with the tools there are now, so they stay the same for a whole turn.
def snapshot(ctx: Context) -> Context = ctx.with(tools: more_tools(ctx), late: none)

def more_tools(ctx: Context) -> List[Tool]
  case ctx.late
    some(late) -> ctx.tools + late.call(ctx.root)
    none -> ctx.tools
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
