---
title: Sessions
description: How Finn keeps a session, resumes it, goes back in its history, forks it, and folds a long history into a summary.
weight: 50
---

# Sessions

A session is one conversation in one folder: its messages, the model's
answers and tool calls, and its settings (provider, model, thinking level).
The server keeps it; a client attaches to it and draws it.

## Resume

A client starts a new session in the current folder, unless you name one:

```sh
finn --session ID
finn tui --session ID
```

In a session, `/resume` lists the sessions, the last changed first, and
`/resume N` or `/resume ID` switches to one. A session goes on when every
client closes: the server keeps running its turn, and a client that attaches
later sees what it missed.

`finn --delete ID` deletes a session and its file.

## Where it is kept

Each session is one file under `~/.local/share/finn/sessions/`
([Configuration](config.md#folders)), in JSON Lines, written as the session
goes. It keeps every event but the text as it streams, in plain text, tool
output and file contents included, until you delete it. The server reads a
session's file the first time a client asks for it.

## Go back: the tree

A session is a tree. `/tree` shows your messages, with a branch one step in.

- `/tree N` goes back to before message N: your next message starts a branch
  from there.
- `/tree N+` goes back to after the answer to message N.

Nothing is lost: the other branches stay in the file, and `/tree` shows them.

## Fork and clone

- `/fork N` (or `/fork N+`) starts a new session with the history up to
  message N (or after its answer).
- `/clone` starts a new session with the whole history.

The new session keeps the folder, the system prompt, the provider, the model
and the thinking level.

## Send while a turn runs

A message you send while the model works waits in the turn's queue: the turn
reads it before its next model call, so you can steer it. The queue holds 20
messages at most.

In `finn tui`, Alt+Enter sends a message after the turn ends instead.

## Compaction

Past 80 % of the model's context window, the history after the first task
becomes one summary. The last round of the running turn stays whole, with its
tool call and result. `/compact` folds the history now.

- The window comes from `FINN_CONTEXT_WINDOW`, else llama-server's `/props`
  for a local server, else the models.dev catalog, else the provider's
  `GET /models`.
- `FINN_COMPACT_MODEL` names the model that writes the summary (a model of
  the server's API); else it is the session's model. Its tokens are not in the
  session's usage or cost.
- On Anthropic, the history folds only between turns. Past the limit inside a
  turn, the rest of the turn sends no thinking blocks.
- A [skill](skills.md) that the folded part had loaded comes back after the
  summary.

## Stop

`/stop`, Esc (`finn tui`) or Ctrl+C (`finn`) stops the running turn.
