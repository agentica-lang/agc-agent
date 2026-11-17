---
title: Extensions
description: Extend Finn with an Agentica program of your own that serves the core with your tools, wrappers, prompts, event handlers and services.
weight: 100
---

# Extensions

An extension is Agentica code that runs inside Finn's server. You write a small program that builds a registry of what you add, then serves the core with it, in place of `finn serve`.

What an extension can add:

- **tools** the model may call;
- **wrappers** around the run of every tool call;
- **prompts**: text after the system prompt of each new session;
- **event handlers** for a user message or a compaction;
- **services** that run as long as the server.

The code of an extension runs in a task of its own, with a time limit. A crash or a hang fails that one tool call, refuses that message, or adds nothing to that compaction, and does not stop a session or a running server. A service that fails to start is the exception: it stops the server's start.

## The smallest one

```agentica
import Core from "pkg/core/core"

def main() -> Void
  Core.serve(Core.registry() |> Core.add_prompt("Answer in English."))
end
```

`Core.serve` reads the same environment as `finn serve`, and runs until a signal or `finn server stop`.

## Run it

The program depends on the `core` package of the agc-agent repository by its tag (`core-0.0.1`), as `examples/extension/agentica.toml` does. To start one outside the repository:

1. Copy `examples/extension` to a folder of your own.
2. Remove its `agentica.lock`: it lists `core` as a member of the repository's workspace, so `agentica install` refuses it there.
3. Run `agentica update` in the folder. It fetches `core` and the packages it depends on, by their tags, and writes a new lock.

Then start the program in place of the server:

```sh
agentica my_finn/main.agc        # the server, in the foreground
finn tui                         # a client finds it
```

Or let a client start it when no server runs:

```sh
FINN_SERVER_COMMAND="agentica /path/to/my_finn/main.agc" finn tui
```

## A tool

```agentica
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

def count(call: Core.Call) -> Result[String]
  text = try JSON.string(try JSON.get(call.input, "text"))
  ok("#{text.split(" ").select { |word| not word.empty? }.size} words")
end
```

`Core.add_tool(registry, word_count())` adds it.

- `run` gets a `Core.Call`: the session folder (`root`) and the model's `input`. Its error goes back to the model as a failed call.
- `target` is what the approval shows and the rules match, such as a path or a command. It has 5 seconds.
- `asks: true` makes a call wait for an answer when the approvals are on and no rule allows it.
- `Core.resolve(call, path)` resolves a path inside the session folder, and fails outside it or for a file that a deny rule hides.
- The name must not be one of the built-in tools, `apply_patch`, `run_script`, `activate_skill` or another extension's, and must not start with `mcp__`: the server refuses to start.

## A wrapper

A wrapper gets the tool's name, the call, and the run it wraps, and gives the output:

```agentica
def timed(name: String, _call: Core.Call, next: Fn[Result[String]]) -> Result[String]
  started = Time.monotonic_ms()
  output = try next.call()
  ok("#{output}\n(#{name} took #{Time.monotonic_ms() - started} ms)")
end
```

`Core.wrap_tools(registry, &timed)` puts it around every tool but `activate_skill` and `run_script` (the calls a script makes are wrapped). The first wrapper added is the outermost. The approval decides first, and `next` runs on the input the approval saw. Keep a wrapper free of state of its own.

## Prompts and events

- `Core.add_prompt(registry, text)` adds text after the system prompt of each new session.
- `Core.on(registry, Core.Event.Message(fn))` gets the text of each user message and gives the text the model gets. The session file keeps what was typed too. A crash or a hang refuses the message.
- `Core.on(registry, Core.Event.Fold(fn))` gets the messages that stay when the history folds, and gives text to add after the summary.

The handlers of one event have 2 seconds together.

`Core.on(registry, Core.Event.Seen(["turn_started", "tool_finished", "turn_finished"], fn))` observes the sessions. `fn` gets a `Core.Seen` with the session id, its folder, the event's name and its `data`, the JSON that [`/events`](server.md#events) sends. Two names have no SSE event: `session_started` (`{"id", "new"}`) comes before any event of the session, with `new` true when the session was just created and false when it was loaded from its file (a fork is loaded from the file it was written to). `session_ended` (`{"id", "reason"}`, `deleted` or `stopping`) comes last; a session deleted before it was loaded again gets it alone. Ask only for the names you need: the text deltas are events too.

Nothing waits for an observer. It gets its events in order, one at a time, with 2 seconds each. One that falls 256 events behind loses the next ones, and the server log counts them. A crash or a hang is logged, and the next event comes.

`Core.on(registry, Core.Event.ToolBefore(fn))` gets each tool call before anything else sees it, as a `Core.Pending` with the session id, its folder, the tool's name and the input. `fn` gives a `Core.Check`:

- `Core.Check.Go` runs the call as it is.
- `Core.Check.Input(json)` runs it on another input. The approval, its rules and the tool all see the new input. The result starts with `an extension changed the input of this call to: JSON`, so the model and the session file keep what ran.
- `Core.Check.Stop(reason)` fails the call, and the model gets `blocked by an extension: REASON`, with the first 1000 characters of the reason as they are.

Each handler gets the input the one before gave, in the order they were added, and the first stop ends the chain. The handlers of one call have 10 seconds together, so a slow first handler leaves less for the next and can fail the call. A crash or a hang fails the call. The calls of several sessions run the handlers at the same time: keep a handler free of state of its own. The calls a `run_script` script makes pass the handlers too, and a stop counts as denied there.

## A service

```agentica
Core.add_service(registry, Core.Service(name: "greeter", start: &greet, stop: &farewell))
```

`start` runs once the server holds its lock, before it listens; `stop` runs after it stops listening. Both run in one task of the service's own, so what `start` opens stays open until `stop`. A start that fails, crashes or takes over 30 seconds stops the server's start.

## Test it

`Core.call(root, input)` builds a call in the folder `root`, with no deny rule, so a test can run a tool's `run` and `target` directly.

## The example

`examples/extension` in the repository adds the `word_count` tool, the `timed` wrapper and the `greeter` service. Its `main.agc`:

```agentica
import Core from "pkg/core/core"
import Extension from "extension"

def main() -> Void
  Core.serve(Extension.register(Core.registry()))
end
```

Other ways to add to Finn need no code: [skills](skills.md) and [MCP servers](mcp.md).
