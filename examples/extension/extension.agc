## An example extension of Finn: a `word_count` tool, a wrapper that adds the time a call took to the output of every
## tool, and a service that says when it starts and stops. A program serves it with
## `Core.serve(Extension.register(Core.registry()))` (`main.agc`).

import Core from "pkg/core/core"
import Quota from "quota"

def register(registry: Core.Registry) -> Core.Registry
  (
    registry
    |> Quota.register()
    |> Core.set_statusline(["state", "usage", "example.provider", "chatgpt.quota"], ["model"])
    |> Core.add_status_segment(Core.StatusProvider(name: "example.provider", value: &status_provider))
    |> Core.add_tool(word_count())
    |> Core.wrap_tools(&timed)
    |> Core.add_service(Core.Service(name: "greeter", start: &greet, stop: &farewell))
  )
end

## The session's provider as a status component.
def status_provider(context: Core.StatusContext) -> Result[String] = ok("provider: #{context.provider}")

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
    run: &count,
    target: ->(_call: Core.Call) { ok("") },
  )
end

## The output of `next` with the time the call of the tool `name` took after it.
def timed(name: String, _call: Core.Call, next: Fn[Result[String]]) -> Result[String]
  started = Time.monotonic_ms()
  output = try next.call()
  ok("#{output}\n(#{name} took #{Time.monotonic_ms() - started} ms)")
end

private

def count(call: Core.Call) -> Result[String]
  text = try JSON.string(try JSON.get(call.input, "text"))
  ok("#{text.split(" ").select { |word| not word.empty? }.size} words")
end

def greet() -> Result[Void]
  puts("greeter started")
  ok()
end

def farewell() -> Void
  puts("greeter stopped")
end
