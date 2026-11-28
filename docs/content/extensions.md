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
- **status line segments**: named texts that the user can place in the status row of the full-screen client.

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

The example is a member of the repository's workspace (`examples/extension/agentica.toml`), so it runs from a clone, where `core` is read in place. Outside the repository (Agentica 0.35 and later) one dependency on the repository, by the tag of a Finn version, gives `core` (`workspace = true`). Its `bash` package has no file over 1 MiB and downloads a prebuilt library for five targets:

```toml
finn = { git = "https://github.com/agentica-lang/agc-agent", tag = "finn-<ts>", workspace = true }
```

From a clone, start the program in place of the server:

```sh
agentica my_finn/main.agc        # the server, in the foreground
finn tui                         # a client finds it
```

Or let a client start it when no server runs:

```sh
FINN_SERVER_COMMAND="agentica /path/to/my_finn/main.agc" finn tui
```

## Status line segments

An extension can add a named text to the status row of the full-screen client with `Core.add_status_segment(registry, Core.StatusProvider(name: "example.provider", value: &status_provider))`. The callback takes a `Core.StatusContext` with `session`, `root`, `provider` and `model`, and returns `Result[String]`. The server accepts up to 16 segments with nonempty, unique names distinct from the built-in ones (`state`, `usage`, `rate`, `hints`, `model` and `chatgpt.quota`). It uses the first 200 characters of each value and removes control and bidirectional formatting characters. A failed, empty or timed-out callback shows nothing. The callbacks run at once, outside the session actor, and each may take 2.5 seconds, so a slow one delays no other (the request waits 50 seconds at most). The server answers at most four requests at once, with an empty list when they are all busy.

An extension does not place its segment: the user does, with `status_line` in [the config file](config.md#the-status-line). A segment that no layout names is not shown. `GET /v1/sessions/ID/status-segments` gives the current values, which the client asks for every five seconds while its row has a segment of this kind.

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

- `run` gets a `Core.Call`: the session folder (`root`), the session's id (`session`, none in `Core.call`) and the model's `input`. Its error goes back to the model as a failed call.
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

`Core.on(registry, Core.Event.Seen(["turn_started", "tool_finished", "turn_finished"], fn))` observes the sessions. `fn` gets a `Core.Seen` with the session id, its folder, its `parent` (the session that started it, a [child session](#child-sessions)'s), the event's name and its `data`, the JSON that [`/events`](server.md#events) sends. Two names have no SSE event: `session_started` (`{"id", "new", "parent"}`) comes before any event of the session, with `new` true when the session was just created and false when it was loaded from its file (a fork is loaded from the file it was written to). `session_ended` (`{"id", "reason"}`, `deleted`, `parent_ended` or `stopping`) comes last; a session deleted before it was loaded again gets it alone. Ask only for the names you need: the text deltas are events too.

Nothing waits for an observer. It gets its events in order, one at a time, with 2 seconds each. One that falls 256 events behind loses the next ones, and the server log counts them. A crash or a hang is logged, and the next event comes.

`Core.on(registry, Core.Event.ToolBefore(fn))` gets each tool call before anything else sees it, as a `Core.Pending` with the session id, the session that started it (`parent`, none for a session of its own), its folder, the tool's name and the input. `fn` gives a `Core.Check`:

- `Core.Check.Go` runs the call as it is.
- `Core.Check.Input(json)` runs it on another input. The approval, its rules and the tool all see the new input. The result starts with `an extension changed the input of this call to: JSON`, so the model and the session file keep what ran.
- `Core.Check.Stop(reason)` fails the call, and the model gets `blocked by an extension: REASON`, with the first 1000 characters of the reason as they are.

Each handler gets the input the one before gave, in the order they were added, and the first stop ends the chain. The handlers of one call have 10 seconds together, so a slow first handler leaves less for the next and can fail the call. A crash or a hang fails the call. The calls of several sessions run the handlers at the same time: keep a handler free of state of its own. The calls a `run_script` script makes pass the handlers too, and a stop counts as denied there.

## Child sessions

A tool's `Core.Call` carries its `session` and `host`, a `Core.Host` that reaches that session and the sessions it starts, its children:

- `host.create.call(Core.NewChild(provider: some("other"), model: some("m1"), profile: none))` starts a child in the same folder and gives its id. A child may use any configured provider; with none it takes the parent's provider and model. With no profile it takes the parent's, and its tools are those both profiles show, so a child is never wider than its parent.
- `host.send.call(id, text)` sends a message to a child: it starts a turn, or joins the running one, as a user's message does. Sent to the session itself, it wakes it, with `child:ID` when its host is a child's and `extension` otherwise; a child wakes its parent the same way, with its own id, and only that: any other read or control of the parent stays `session.not_found`.
- `host.watch.call(id, ["turn_finished"], fn)` gives `fn` the events of the session or a child, as an observer. Watching the same names again keeps the first handler.
- `host.snapshot.call(id)` reads the session or a child: its history, usage and settings.
- `host.stop.call(id)` stops only a child's turn, and `host.delete.call(id)` deletes only a child; both refuse the session itself with `session.not_found`.

So a tool can start a child, watch it, and send its answer back to its own session, which starts a turn:

```agentica
def answered(host: Core.Host, parent: String, seen: Core.Seen) -> Void
  case host.snapshot.call(seen.session)
    ok(child) -> _ = host.send.call(parent, "#{seen.session} said: #{child.history.last.text}")
    error(e) -> IO.warn(e.message)
  end
end
```

Other ids are refused with `session.not_found`, and a child cannot start sessions. A child's tool calls, approvals and cost reach the parent's stream too, stamped with the child's id (`session`), and are saved in the parent's file, so a replay shows them with their provenance; the child's text and thinking deltas never do. A child's approval is answered on the parent's route (`POST /v1/sessions/PARENT/approvals/AID`), which reaches only the parent's own approvals and its children's. The parent's session allows count for the child, but its accept-edits mode does not, and a child's asks wait while a client watches the parent. The child's cost adds to the parent's turn and session sums, while the parent keeps its own context. A child's ceiling is the parent's effective profile when the child starts (a `PATCH` before then counts); it is a snapshot, so a later change of the parent leaves the child's tools alone. A wake that finds a running turn queues into it like a user's message and does not count; an idle wake starts a turn with its `source` (`child:ID` or `extension`) on `turn_started` and `message_queued`. Only a wake that starts a turn counts toward `FINN_WAKES_MAX` (100 per user message, `0` for no cap): past the cap, or after a user stop, a wake parks for the next user message (a `message_queued` with an empty `turn_id`), which takes parked wakes before its own and resets the count, so no watcher restarts a stopped parent. A stop that stops nothing (an idle session, or a `turn_id` that is not running) leaves the window as it was, so the next wake still starts a turn; a real stop opens it and an idle stop keeps it open until the next user message. Parked wakes are durable: the file keeps them and the user message that takes them carries them, so they survive a restart and a branch and are taken exactly once, in order before the user's own text (after a shell's output, if any); a fork starts with none, and moving back never brings back a consumed wake; the wake count and the stop window are per-process and start over on a restart, while queued messages stay memory-only and are lost by one. A wake that finds a shell command or a compaction running is refused as `session.busy`, like a user's message. A child may wake itself with its own id. The children are kept in memory only, so no file of theirs stays, and `GET /v1/sessions` does not list them. A `/stop` that stops the parent's turn stops their turns too and leaves them open, and a delete of the parent deletes them first.

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
