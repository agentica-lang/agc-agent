---
title: CLI and TUI
description: The finn commands, the slash commands of a session, the keys of finn tui, and the ! and @ shortcuts.
weight: 40
---

# CLI and TUI

Finn has two clients for a session: `finn`, a line-mode client, and
`finn tui`, a full-screen one. Both start the server when none runs and leave
it running when they quit.

## Commands

| Command | What it does |
|---|---|
| `finn` (or `finn chat`) | chat in this folder, line by line |
| `finn tui` | chat in this folder on the full screen |
| `finn -p TASK` | run one task and exit; `-p -` reads it from stdin |
| `finn serve` | run the server in the foreground |
| `finn login [PROVIDER]` | set up a provider with its key ([Providers](providers.md)) |
| `finn logout [PROVIDER]` | remove a stored key, or all of them |
| `finn server ACTION` | `status`, `start`, `stop`, `restart` or `logs` of the server |
| `finn --version` | the versions of the server and the client |

`finn --help`, `finn chat --help`, `finn tui --help`, `finn serve --help` and
`finn server --help` list every option.

### Options of a session

These work for `finn` and `finn tui`:

| Option | What it does |
|---|---|
| `--session ID` | resume that session (default: a new one) |
| `--cwd DIR` | the folder of a new session (default: the current folder) |
| `--provider NAME` | the provider of a new session |
| `--model NAME` | the model of a new session |
| `--api NAME` | the model API of a new session: `openai` or `openai_responses` |
| `--thinking` | show the model's thinking |
| `--yolo` | with the approvals on, allow the tool calls of the turns this client starts |
| `--state-dir DIR` | the folder of `server.json` (default: `FINN_STATE_DIR`) |

`finn` also takes `--delete ID` (delete a session and its file) and
`--server-command` (the program that starts a server).

### One task

`finn -p TASK` sends one task and exits when the turn ends. The answer goes to
stdout and the rest to stderr. With the approvals on, a call that would ask is
denied unless you add `--yolo`. The exit status:

- `0`: the turn ended normally, also after a denied call;
- `130`: the turn was cancelled;
- `1`: anything else, such as a failed send, a busy session or an empty task.

### The server

`finn server stop` waits for the running turns to end (`FINN_DRAIN_MS`, a
minute by default), and `--now` cancels them. `finn server logs` prints the end
of the server's log, and `-f` follows it.

## Slash commands

Type them in either client:

| Command | What it does |
|---|---|
| `/new` | a new session in this folder |
| `/resume [N\|ID]` | list the sessions; with a number or an id, switch to it |
| `/tree [N\|N+]` | the session's messages; `N` goes back before message N, `N+` after its answer |
| `/fork [N\|N+]` | a new session from before message N (or after its answer) |
| `/clone` | a new session with this one's history |
| `/model [PROVIDER/]NAME` | change the model (and provider) from the next turn on; alone, pick or show it |
| `/thinking [low\|medium\|high\|default]` | show or change the thinking level |
| `/compact` | fold the history into a summary now |
| `/login [PROVIDER]` | set up a provider (`finn tui`) |
| `/logout [PROVIDER]` | remove a stored key; alone, every one |
| `/stop` | stop the running turn |
| `/help` | the list |
| `/quit` | leave |

Any other `/name` goes to the agent as a message, so `/name` of a
[skill](skills.md) loads that skill.

## Shell commands

- `!CMD` runs `CMD` in the session folder; the model gets its output with your
  next message.
- `!!CMD` runs it without giving the output to the model.

The command runs as the `bash` tool would. A deny rule still refuses it, but it
never asks: you typed it.

## Keys of finn tui

| Key | What it does |
|---|---|
| Enter | send |
| Alt+Enter | send after the running turn ends (a follow-up) |
| Ctrl+J | a new line |
| Esc | stop the running turn |
| Ctrl+C | quit |
| Shift+Tab | the next thinking level |
| Ctrl+T | show or hide the thinking |
| Ctrl+O | show or hide the tool output |
| `@` | complete a file path of the session folder |
| `/` | complete a command; Esc then Enter sends the text as typed |
| Up | the earlier messages you sent |
| PgUp, PgDn | scroll |

The mouse answers the keys of a panel, opens a tool call or the thinking, and
moves the cursor in the prompt.

A message you send while a turn runs joins that turn: the model reads it
before its next call.

## Keys of finn

Ctrl+C stops the running turn; a second Ctrl+C leaves. With no turn running,
Ctrl+C leaves.
