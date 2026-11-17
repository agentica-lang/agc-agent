## What the extensions of a server add (`Core.serve`): tools, wrappers of every tool, text after the system prompt of a
## new session, handlers of events, and services that run as long as the server.

import LLM from "pkg/llm/llm"
import Spec from "../tools/spec"

## A handler of an event of a session. `Message` changes the text of a user message before the model gets it (the
## session file keeps both). `Fold` gives text to add after the summary when the history folds, from the messages
## that stay.
enum Event
  Message(Fn[String, String])
  Fold(Fn[List[LLM.Message], String])
end

## Something that runs with the server: `start` before it listens (an error stops the start), `stop` after it ends.
struct Service
  name: String
  start: Fn[Result[Void]]
  stop: Fn[Void]
end

struct Registry
  tools: List[Spec.Tool] = []
  wrappers: List[Fn[Spec.Tool, Spec.Tool]] = []
  prompts: List[String] = []
  events: List[Event] = []
  services: List[Service] = []
end

## Every wrapper on `tool`, the first added outermost.
def wrapped(registry: Registry, tool: Spec.Tool) -> Spec.Tool
  out = tool
  for wrap in registry.wrappers.reverse
    out = wrap.call(out)
  end

  out
end

## `text` after the `Message` handlers, in the order they were added.
def message(registry: Registry, text: String) -> String
  out = text
  for event in registry.events
    case event
      Event.Message(handle) -> out = handle.call(out)
      _ -> nil
    end
  end

  out
end

## The text the `Fold` handlers add after a summary, each on its own lines.
def fold(registry: Registry, staying: List[LLM.Message]) -> String
  out = ""
  for event in registry.events
    case event
      Event.Fold(handle) ->
        extra = handle.call(staying)
        if not extra.empty?
          out = "#{out}\n\n#{extra}"
        end

      _ -> nil
    end
  end

  out
end

## `system` with the prompts of the extensions after it.
def prompt(registry: Registry, system: String) -> String = ([system] + registry.prompts).join("\n\n")
