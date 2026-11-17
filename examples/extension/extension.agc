## An example extension of Finn: a `word_count` tool, and a wrapper that adds the time a call took to the output of
## every tool. A program serves it with `Core.serve(Extension.register(Core.registry()))` (`main.agc`).

import Core from "pkg/core/core"

def register(registry: Core.Registry) -> Core.Registry
  (
    registry
    |> Core.add_tool(word_count())
    |> Core.wrap_tools(&timed)
  )
end

## A tool that counts the words of a text; it reads nothing, so it never asks.
def word_count() -> Core.Tool
  Core.Tool(
    name: "word_count",
    description: "Counts the words of a text.",
    input_schema: JSON.object({
      "type": JSON.from("object"),
      "properties": JSON.object({"text": JSON.object({"type": JSON.from("string")})}),
      "required": JSON.from(["text"]),
    }),
    asks: false,
    run: ->(_ctx: Core.Context, input: JSON.Value) { count(input) },
    target: ->(_ctx: Core.Context, _input: JSON.Value) { ok("") },
  )
end

## `tool` with the time its call took after its output.
def timed(tool: Core.Tool) -> Core.Tool
  run = tool.run
  tool.with(
    run: ->(ctx: Core.Context, input: JSON.Value) {
      started = Time.monotonic_ms()
      output = try run.call(ctx, input)
      ok("#{output}\n(#{tool.name} took #{Time.monotonic_ms() - started} ms)")
    },
  )
end

private

def count(input: JSON.Value) -> Result[String]
  text = try JSON.string(try JSON.get(input, "text"))
  ok("#{text.split(" ").select { |word| not word.empty? }.size} words")
end
