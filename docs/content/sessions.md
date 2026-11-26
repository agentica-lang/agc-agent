---
title: Sessions
description: How Finn keeps a session, resumes it, goes back in its history, forks it, and folds a long history into a summary.
weight: 50
---

# Sessions

A session is one conversation in one folder: its messages, the model's answers and tool calls, and its settings (provider, model, thinking level). The server keeps it; a client attaches to it and draws it.

## Resume

A client starts a new session in the current folder, unless you name one:

```sh
finn --session ID
finn chat --session ID
```

In a session, `/resume` lists the other sessions, the last changed first, without those that hold no message yet (their files stay), and `/resume N` or `/resume ID` switches to one; it shows the session's turns as they were drawn: the thinking, the tool calls and how a turn ended. A session goes on when every client closes: the server keeps running its turn, and a client that attaches later sees what it missed.

`finn --delete ID` deletes a session and its file.

## Where it is kept

Each session is one file under `~/.local/share/finn/sessions/` ([Configuration](config.md#folders)), in JSON Lines, written as the session goes. It keeps every event but the text as it streams, in plain text, tool output and file contents included, until you delete it. The folder is readable by you alone. The server reads a session's file the first time a client asks for it.

## Go back: the tree

A session is a tree. `/tree` shows your messages, with a branch one step in.

- `/tree N` goes back to before message N: your next message starts a branch from there.
- `/tree N+` goes back to after the answer to message N.

Nothing is lost: the other branches stay in the file, and `/tree` shows them.

## Fork and clone

- `/fork N` (or `/fork N+`) starts a new session with the history up to message N (or after its answer).
- `/clone` starts a new session with the whole history.

The new session keeps the folder, the system prompt, the provider, the model and the thinking level.

## Export

`/export [PATH]` in either client, or `finn export SESSION [PATH]`, writes the branch the session is on to a Markdown file: the title and date, your messages and the answers in order, each tool call on one line (its name, what it was called on, and ok or error, without its output), and the todo list. The other branches of the tree are left out.

The file is `ID.md` in the folder the client runs in unless you give a path. With `/export` the path is the rest of the line, spaces kept; a relative path is from the client's folder, and `~` is your home folder. A file that exists is refused; `--force`, given first, replaces it in one step, so a failure keeps the old file. A link or a folder is never replaced. The file is made readable by you alone, and it holds what the session holds, with nothing hidden: the tool summaries are copied as they are, bash commands and MCP arguments included, so check the file before you share it. Each message is in a code fence, so its text cannot pass for a heading, and a control or bidi character is written as its code (`\u001b`), so the file shows nothing a terminal would act on. A line marks where the history was compacted.

## Send while a turn runs

A message you send while the model works waits in the turn's queue: the turn reads it before its next model call, so you can steer it. The queue holds 20 messages at most.

In `finn`, Alt+Enter sends a message after the turn ends instead.

A turn stops after 500 tool rounds (`max_rounds`), and the loop guard (`loop_guard`) stops it sooner when the same one to three tool rounds, with the same calls and results, come three times in a row.

## Compaction

Past 80 % of the model's context window, the history after the first task becomes one summary. The last round of the running turn stays whole, with its tool call and result. `/compact` folds the history now.

- The window is `FINN_CONTEXT_WINDOW` when set. Else, for a local server: llama-server's `/props`, then the provider's `GET /models`, then the models.dev catalog. For the other providers: the catalog, then `GET /models`.
- `FINN_COMPACT_MODEL` names the model that writes the summary, for the sessions on the server's own provider and API. Else, and for the other sessions, it is the session's model. Its tokens are not in the session's usage or cost.
- On Anthropic, the history folds only between turns. Past the limit inside a turn, the rest of the turn sends no thinking blocks.
- A [skill](skills.md) that the folded part had loaded comes back after the summary.

To stop a turn, see [CLI and TUI](cli.md#stop).
