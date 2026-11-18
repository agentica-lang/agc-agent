---
title: CLI and TUI
description: The finn commands, the slash commands of a session, the keys of the full screen, and the ! and @ shortcuts.
weight: 40
---

# CLI and TUI

Finn has two clients for a session: `finn`, a full-screen one, and `finn chat`, a line-mode one. Both start the server when none runs and leave it running when they quit.

## Commands

| Command | What it does |
|---|---|
| `finn` (or `finn tui`) | chat in this folder on the full screen; it needs a terminal |
| `finn chat` | chat in this folder, line by line |
| `finn -p TASK` | run one task and exit; `-p -` reads it from stdin |
| `finn serve` | run the server in the foreground |
| `finn login [PROVIDER]` | set up a provider with its key ([Providers](providers.md)); prints the result on the console when it ends, and Esc cancels with status 0 |
| `finn logout [PROVIDER]` | remove a stored key, or all of them |
| `finn server ACTION` | `status`, `start`, `stop`, `restart` or `logs` of the server |
| `finn export SESSION [PATH]` | write a session to a Markdown file ([Sessions](sessions.md#export)) |
| `finn docs [PAGE]` | list the pages of Finn's own documentation, or print one as Markdown, without its front matter; they are the files of `docs/content` in the install that runs, so they match its version. A name that is no page exits 1 with the list. [The skill `finn`](skills.md#the-finn-skill) gives the model the same pages |
| `finn --version` | the versions of the server and the client |

`finn --help`, `finn chat --help`, `finn tui --help`, `finn serve --help`, `finn server --help`, `finn export --help` and `finn docs --help` list every option.

### Options of a session

These work for `finn` and `finn chat`:

| Option | What it does |
|---|---|
| `--session ID` | resume that session ([Sessions](sessions.md#resume)); default: a new one |
| `--cwd DIR` | the folder of a new session (default: the current folder) |
| `--provider NAME` | the provider of a new session |
| `--model NAME` | the model of a new session |
| `--api NAME` | the model API of a new session: `openai` or `openai_responses` |
| `--profile NAME` | the [profile](tools.md#profiles) of a new session: the tools its model sees (default: `build`) |
| `--thinking` | show the model's thinking |
| `--yolo` | with the approvals on, allow the tool calls of the turns this client starts |
| `--state-dir DIR` | the folder of `server.json` (default: `FINN_STATE_DIR`) |

`finn chat` also takes `--delete ID` ([Sessions](sessions.md#resume)) and `--server-command` (the program that starts a server); `finn` with one of them runs `finn chat`.

### One task

`finn -p TASK` sends one task and exits when the turn ends. The answer goes to stdout and the rest to stderr. With the approvals on, a call that would ask is denied unless you add `--yolo`. The exit status:

- `0`: the turn ended normally, also after a denied call;
- `130`: the turn was cancelled;
- `1`: anything else, such as a failed send, a busy session or an empty task.

### The server

`finn server stop` waits for the running turns to end (`FINN_DRAIN_MS`, a minute by default), and `--now` cancels them. A server that does not take the request (one of another version, or one that does not answer) is stopped by the pid of its `server.json`, which stops its running turns, and with `--now` it is forced; when it is still there after 30 s, the error names `finn server stop --now`. The pid is used only when that process proves to be the folder's server: a server holds the folder's lock, and the process is Agentica, started before `server.json` was written, with that state folder. The sessions are kept. `finn server logs` prints the end of the server's log, and `-f` follows it.

### Versions

The version of Finn is the UTC time of the commit it runs, `YYYYMMDDhhmmss`, and each one on `main` has the tag `finn-YYYYMMDDhhmmss`. `bin/finn` reads it from git (or, in an archive without `.git`, from `bin/commit-time`) and passes it to the server and the clients in `FINN_VERSION`; a program started without it says `unknown`. It is the time of the last commit, so edits that are not committed show the same version, and a rebased or amended checkout may show as older.

A server keeps running the code it started with, so after a `git pull` it can be older than the client. The client then says which side is older. A server of the same protocol still serves it, with one line such as `the server runs an older Finn (20261101093000) than this client (20261118123456)`, and `finn server restart` starts the new one; a server of another protocol is not used, and the client says the same. `finn server status` shows the comparison next to the server's version.

## Slash commands

Type them in either client:

| Command | What it does |
|---|---|
| `/new` | a new session in this folder |
| `/resume [N\|ID]` | list the other sessions that hold something; with a number or an id, switch to one |
| `/tree [N\|N+]` | the session's messages; `N` goes back before message N, `N+` after its answer |
| `/fork [N\|N+]` | a new session from before message N (or after its answer) |
| `/clone` | a new session with this one's history |
| `/export [--force] [PATH]` | write the session to a Markdown file ([Sessions](sessions.md#export)) |
| `/model [PROVIDER/]NAME` | change the model (and provider) from the next turn on; alone, pick or show it |
| `/thinking [low\|medium\|high\|default]` | show or change the thinking level |
| `/confine [on\|off]` | keep the file tools in the session folder, or let them reach any path; alone: show it |
| `/profile [NAME]` | change the [profile](tools.md#profiles) between turns (Tab completes it in `finn`); alone, list them |
| `/compact` | fold the history into a summary now |
| `/login [PROVIDER]` | set up a provider (`finn`) |
| `/logout [PROVIDER]` | remove a stored key; alone, every one |
| `/logs [N]` | the last N lines (default 50) of the server log, read through the server |
| `/stop` | stop the running turn |
| `/help` | the list |
| `/quit` | leave; a session with something in it prints how to come back to it (`finn --session ID`, `finn chat --session ID`) |

Any other `/name` goes to the agent as a message, so `/name` of a [skill](skills.md) loads that skill, and a [slash command](#slash-commands) puts its prompt there. What `/tree`, `/fork` and `/compact` do is on [Sessions](sessions.md).

## Slash commands

A slash command is a prompt you keep in a file and send with `/NAME`. It is a file `NAME.md` in `~/.config/finn/commands/` (`$XDG_CONFIG_HOME/finn/commands/`), or in `.finn/commands/` of a [trusted](config.md#trusted-folders) project, which wins over yours with a warning.

```markdown
---
description: Review a change
---
Review $ARGUMENTS: look for bugs first, then for missing tests.
```

- `/review src/a.agc` sends the prompt with `$ARGUMENTS` replaced by `src/a.agc`. Without `$ARGUMENTS`, the text after the name goes after the prompt, after a blank line.
- The model gets the prompt; your history shows what you typed. The file is read again at each use. A `/name` of a [skill](skills.md) in the prompt loads that skill, as in a message you type.
- NAME is lowercase letters, digits, `-` and `_`; the front matter (only `description`) is optional, and the file holds at most 64 KiB. Another file there is skipped with a warning (a link counts only when it leads to a file inside the folder), and a broken one fails only its own name. With the approvals on, a change of the model under `.finn/` always asks ([why](security.md)).
- The clients' own commands keep their names: a `model.md` is skipped. A command wins over a [skill](skills.md) of the same name, with a warning.
- `/help` lists the session's commands, and `finn` suggests them after `/` (read when a session of another folder opens, and again on `/help`).

## Shell commands

- `!CMD` runs `CMD` in the session folder; the model gets its output with your next message.
- `!!CMD` runs it without giving the output to the model.

The command runs as the `bash` tool would, with a timeout of 10 minutes. It never asks: you typed it. The deny rules refuse it as they refuse a call of `bash` ([how](security.md#how-rules-check-bash)).

## Stop

`/stop`, Esc (`finn`) or Ctrl+C (`finn chat`) stops the running turn or shell command. In `finn chat`, a second Ctrl+C leaves, and so does Ctrl+C when nothing runs.

## Keys of the full screen

| Key | What it does |
|---|---|
| Enter | send; during a turn, the turn reads it before its next model call ([Sessions](sessions.md#send-while-a-turn-runs)) |
| Alt+Enter | send after the running turn ends (a follow-up) |
| Ctrl+J | a new line |
| Ctrl+G | edit the prompt in `$VISUAL`, else `$EDITOR` (it may hold arguments, as `code -w`); what the editor saves becomes the prompt, with a large paste as its text. The text goes through a file only you can read in the state folder, removed afterwards. In the editor, Ctrl+C is a key for it and never quits `finn` |
| Esc | stop the running turn |
| Ctrl+C; Ctrl+D on an empty prompt while nothing runs and no approval waits | quit |
| Shift+Tab | the next thinking level |
| Ctrl+T | show or hide the thinking |
| Ctrl+O | show or hide the tool output |
| `@` | complete a file path of the session folder; the paths come from the server, which walks the folder or runs the command of your config ([The files command](config.md#the-files-command)) |
| `/` | complete a command; Esc then Enter sends the text as typed. After `/model `, `/resume `, `/tree `, `/fork ` or `/thinking ` the list holds the models, sessions, messages or levels the server gives, starting on the session's model or level: Tab puts the selected one in. Enter runs the command with the row you moved to; otherwise the line is sent as typed, and the command alone opens its picker |
| Up, Down | move between the rows of the prompt, keeping the column; Up on an empty prompt shows the earlier messages you sent, and while one is shown, Up from its first row and Down from its last row go through them |
| Ctrl+A, Ctrl+E | the start or the end of the line |
| Ctrl+Left, Ctrl+Right, Alt+Left, Alt+Right, Alt+B, Alt+F | the word before or after; a word move stops at the end of a line |
| Ctrl+W, Alt+Backspace | delete the word before the cursor; at the start of a line, the line end before it |
| Ctrl+U, Ctrl+K | delete to the start or the end of the line |
| Delete, Ctrl+D | delete the character after the cursor |
| PgUp, PgDn | scroll |
| Ctrl+Y, Ctrl+N | allow or deny the call that waits for an approval |
| Tab | move to the approval panel: `y` allow, `n` deny, `a` allow the same call for the session; Tab or Esc goes back |

The mouse answers the keys of a panel, opens a tool call or the thinking, and moves the cursor in the prompt.

## Footer of the full screen

The two rows under the prompt:

- the session folder (`~` for your home), its git branch and the first line of the session's first message;
- the status (`ready`, `YOLO`, `approval waiting`), the counts and the key hints that fit, then the profile (unless it is `build`), the model and the thinking level on the right.

On a short screen the first row goes first, so an approval keeps its rows.

The counts read `↑4.8k ↓40 R3.6k 75% cached $0.013 15.0%/32k`. All but `$` are about the last model call: `↑` its whole prompt (the cached part too), `↓` its output, `R` the prompt read from the cache and the part of the prompt it was, and the prompt as a part of the model's window (its size in tokens while the window is not known). `$` is the session's cost, when the [catalog](providers.md) has prices.

After the counts, `42 tok/s` is how fast the model wrote its last reply: the output tokens of the call, reasoning included, over the time from its first output to its end. While a reply streams, `~42 tok/s` is an estimate from its text (about 4 characters a token). The rate stays until the next one, and a narrow row drops it first.

In `finn chat`, answer an approval with `y`, `n` or `a` and Enter. The answers are on [Approvals and security](security.md#answer).
