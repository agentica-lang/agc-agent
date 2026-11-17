# Changelog

## [Unreleased]

- **Breaking:** a config of before the rename (`config.json` in `$XDG_CONFIG_HOME/agc-agent/` or `~/.config/agc-agent/` without the `finn` one, `AGC_AGENT_CONFIG`, `AGC_AGENT_MCP_CONFIG`) stops `finn serve` with an error that says where to move it, instead of being ignored with its deny rules; an old `auth.json` is a warning.
- Approvals: the deny rules are checked statically on each `bash` command and win over every allow rule and session answer, with the approvals off or on. A `bash` rule matches a program the command runs, also by its path (`/bin/rm`), after a launcher (`sudo`, `env`, `xargs`, `find -exec`, `then`) or in `sh -c` and `eval`; a `read_file` rule matches a word that names the file as written, after `=` or `@` or a joined one-letter option, or resolved against the session folder, and the folder of a `dir/**` rule. Such a command is refused. A command they cannot clear (a glob or quote, a shell reading a script or its input, an interpreter, a match that is not a program as in `echo rm`, over 16 KB or nested over 8 deep) asks with the approvals on and is refused with them off; a `!` command runs only when clear. With the approvals on, a match at a program no longer asks, and an exact answer no longer runs a command the rules cannot clear. What they cannot see is listed on the security page.
- **Breaking:** `finn` alone (or with options) opens the full screen, as `finn tui` does; `finn chat` is the line chat. Without a terminal, plain `finn` refuses and points to `finn chat` and `finn -p`.
- MCP servers on streamable HTTP: an entry of `FINN_MCP_CONFIG` with `url` and `headers` (`"Authorization": "Bearer ${TOKEN}"` takes the token from the environment, and no error or log shows it). Answers come as JSON or SSE; the client keeps the session id, resumes a cut stream with `Last-Event-ID`, starts a session the server ended again for the same call, and ends the session with a DELETE. Its tools follow the approvals and deny rules as the stdio ones do.
- Approvals: an approval request for `bash` offers no prefix while a `read_file` deny rule exists, since only the same call can be allowed then.
- Approvals: `stdbuf`, `chrt`, `ionice`, `setsid`, `doas`, `flock`, `watch`, `script`, `dash`, `ksh` and `fish` run other programs, so an answer for one allows only the same call, not its first word.
- Extensions: a program of your own can serve Finn's core with its tools, wrappers of the runs of every tool but `activate_skill` and `run_script` (the approval decides first), prompts, `message` and `fold` handlers and services (`Core.serve`; see `examples/extension`); a crash or a hang of their code fails only that call, and `Core.call` builds a call for their tests.
- A read-only `bash` command that runs without asking finds its programs in `/usr/local/bin`, `/usr/bin` and `/bin` when only root can change them; a program found only elsewhere (`~/.cargo/bin`) makes the command ask, and `which` checks its operands as paths.
- **Breaking:** tools run without asking by default; `finn serve --approvals`, `FINN_APPROVALS=1` or `"approvals": true` in the config file turns the approvals on. Deny rules still apply; allow rules and `accept_edits` need the approvals on. With the approvals off, a `read_file` deny rule hides the file from the tools and refuses `bash` commands that name it, but cannot confine `bash`: use a sandbox.
- `!` commands: a command whose task ends without its output ends as failed instead of running forever, and `finn tui` shows no duration for one a restart cut.
- `finn tui`: `@` lists the session folder through the server (`GET /v1/sessions/ID/files`: read again each time `@` is typed, without what a `read_file` deny rule hides, cut at 5000 files or about 2 s, which the TUI then says); Esc stops the running turn by its id, so it never stops the turn after it (`POST /v1/sessions/ID/stop` takes an optional `turn_id` and answers whether it stopped one; the TUI says when the turn or command had already ended); and a paste that holds the token of another paste keeps it as text.
- `finn tui` lists the commands while `/` and part of a name are typed, each with what it does: Tab or Enter completes the selected one, Enter on a whole name runs it, Up/Down select, and Esc closes the list so that Enter sends the text as typed. `/help` reads the same table and shows `/resume [N|ID]`.
- `finn login` and `/login` in `finn tui` check a provider key and store it in `~/.config/finn/auth.json` (0600); `finn logout` and `/logout` remove it.
- `!` commands: `finn tui` marks an output the model does not get, the session snapshot names a running command (`shell_id`), and a command that a server restart cut ends as failed, so the clients stop waiting for it.
- `finn chat` and `finn tui` run `!CMD` in the session folder and give its output to the model with the next message, and `!!CMD` without giving it: `POST /v1/sessions/ID/shell` runs the command as the `bash` tool does, for up to 10 minutes (a deny rule refuses it, `shell.denied`), not while a turn runs, and sends `shell_started` and `shell_finished`; up to 20 outputs (1 MiB) wait for the next message.
- `finn tui` shows a tool call as a shell line (`$ ls`, `read x`, `edit x`) tinted by how it went, with its output, a numbered diff of an edit and "Took 1.2s"; Ctrl+O shows or folds every tool output and Ctrl+T every thinking block, with a note. `tool_finished` has `output` and `diff`.
- `finn tui`: Alt+Enter keeps a message for the end of the turn (listed above the prompt; Esc puts it back), Up on an empty prompt recalls earlier prompts, `@` lists the files of the session's folder (Tab completes one), and a large paste stays one `[paste #1 +31 lines]` token.
- `finn tui` says a send that timed out "may not have been sent", stops another client's turn when Esc came before the reply, and keeps the thinking level it is setting across a new read of the session.
- `message_queued` events without `message_id` load again.
- `finn server logs` shows a byte that is not UTF-8 as U+FFFD and goes on; `finn server stop` and `restart` wait as long as the server says it is stopping (`FINN_DRAIN_MS`), a second SIGTERM or SIGINT cancels the turns of a stop that waits, and a failed `restart` says whether an old server was stopped.
- `finn server status|start|stop|restart|logs` manages the server of the state folder: `status` shows the pid, version, uptime, sessions, running turns and whether a stop waits (exit 1 when none runs); `stop` makes the server stop starting work (new sessions, messages and shell commands get `503`, `server.stopping`) and waits until it has gone: it waits for the running turns and shell commands (`--now`, also as a second `stop` while the first waits, cancels them; a turn that only waits for an approval does not make it wait: it is cancelled; `FINN_DRAIN_MS`, 60000, is the longest wait), flushes the sessions, which ends the event streams after `turn_finished`, and removes `server.json`; `restart` stops and starts one the way a client does; `logs [-f]` shows the last 100 lines of `server.log` (it follows by byte offset and ends when the server goes away); a start keeps one `server.log.1` of a log over 10 MiB. The server has `GET /v1/server` and `POST /v1/server/stop` (`{}` is `now: false`) for it, and SIGTERM or SIGINT stops it as `stop --now` does.
- `finn tui` reads Alt+Enter as one key (it was Escape, which stopped the turn, then Enter).
- Providers by name: `local` (FINN_BASE_URL) and `anthropic`, the presets openai, fireworks, openrouter, groq and deepseek once their key variable is set, and custom ones under `providers` in the config file; `FINN_PROVIDER` or `finn serve --provider` picks the default, `finn --provider` and `finn tui --provider` a new session's, and a session keeps its provider (`GET /v1/providers`, `provider` in `POST` and `PATCH /v1/sessions`); one whose provider is no longer offered still opens and names the key to set.
- `/model provider/model` moves the session to another provider; in `finn tui`, `/model` alone opens a picker of every provider's models, and the status line shows `(provider) model`.
- `finn chat` and `finn tui` have `/tree` (go back before an earlier message, or on after an answer, in the same session), `/fork` (a new session from a message) and `/clone` (a copy of the session); `finn tui` picks from a list, and the message gone back before waits in the prompt.
- `finn chat` and `finn tui` have `/tree` (go back before an earlier message, or on after an answer, in the same session), `/fork` (a new session from a message) and `/clone` (a copy of the session); `/tree N` and `/fork N` name a message of the last list; `finn tui` picks from a list, and the message gone back before waits in the prompt, selected, so typing replaces it.
- A session file is a tree: `GET /v1/sessions/ID/tree` lists the user messages of every branch, `POST /v1/sessions/ID/branch` goes on from an earlier message in the same session, and `POST /v1/sessions/ID/fork` starts a new session from one (or copies the session); older session files still load.
- `finn tui` looks like pi: the prompt sits between two rules whose color shows the thinking level (Shift+Tab sets the next one), a spinner and "Working" sit in the top rule during a turn, the transcript has no `>` or `·` marks, the `/resume` picker takes the prompt's place and an approval shows under it.
- The core server runs on Bond 0.13.1 (a router with filters and `Bond.sse`) and no longer on `std/http` directly: the paths, status codes, JSON and event stream are the same. `agentica install` in `core/` fetches Bond, as `make install` does.
- `finn tui` keeps reading keys while a message or a stop is sent, and an answer that only called tools draws no empty row.
- `finn tui` keeps the wrapped rows of each transcript entry, so a key costs about the same on a long transcript as on a short one.
- Approval rules come from a config file (`FINN_CONFIG`, else `~/.config/finn/config.json`) and the project's `.finn/config.json` (its allow rules only under `FINN_TRUSTED_DIRS`); an approval may allow a `bash` prefix (`allow_prefix`) or a whole tool (`allow_tool`) for the session, and `PATCH /v1/sessions/ID` with `accept_edits` runs file edits without asking (until the server restarts; the deny rules are checked first, as far as the parser sees a command, and nothing reaches into `.git/`).
- `finn tui` draws a view tree and writes only the cells that change; the prompt cursor is a reversed cell, and a long pasted line no longer slows each key.
- `finn tui --yolo` allows the tool calls of the turns it starts; the status line shows YOLO all the time, and a turn another client started is still asked.
- `finn tui` takes pasted text whole (bracketed paste) into the prompt or the `/resume` filter.
- **Breaking:** `finn --yolo` allows only the tool calls of the turns it starts, as `finn tui --yolo` does; both ask the rest of a turn another client queued a message into (`message_id` in the `202` and in `message_queued`), or whose events a resync did not replay.
- `finn chat` and `finn tui` refuse a running server of another version (its wire records differ) and say how to stop it, instead of failing on its replies.
- Turn ids have a random part, so a server that lost the last records of a session never gives a new turn an old id.
- `finn chat` and `finn tui` check the server's version again before they read its event stream again; the version also covers the error kinds and the paths.
- A long pasted text in the `finn tui` prompt no longer slows down each key.
### Changed

- **Breaking:** `finn` opens the full screen, as `finn tui` does; `finn chat` is the line chat.
- **Breaking:** tools run without asking by default; turn approvals on with `finn serve --approvals`.
- **Breaking:** `finn --yolo` allows only the tool calls of the turns it starts.
- **Breaking:** the command is `finn` and variables are `FINN_*`; the `AGC_AGENT_*` names still work.
- `finn chat` and `finn tui` refuse a server of another version and say how to stop it.

### Added

- Finn Agent, a coding agent: `finn` (full screen) and `finn chat` (lines) talk to a local server.
- Tools: read, write and edit files, `glob`, `grep`, `bash`, and `apply_patch` for models that use it.
- `finn -p TASK` runs one task and prints the answer.
- Sessions are kept on disk and resume after a restart; `finn --delete ID` removes one.
- Long histories are compacted into a summary before the context window fills.
- Session commands: `/new`, `/resume`, `/model`, `/thinking`, `/compact`, `/stop`, `/help` and `/quit`.
- `/tree`, `/fork` and `/clone` go back in a session, branch it into a new one, or copy it.
- A message sent while a turn runs is queued and read before the next model call.
- `!CMD` runs a shell command in the session folder; `!!CMD` keeps its output from the model.
- `finn` keys: `@` completes files, `/` lists commands, Alt+Enter queues a follow-up, Up recalls prompts.
- `finn` shows tool output and diffs, takes the mouse, and keeps a large paste as one token.
- Providers: local, anthropic, openai, fireworks, openrouter, groq, deepseek and custom; `/model provider/model` switches.
- `finn login` and `finn logout` store and remove a provider key.
- The `openai_responses` and `anthropic` APIs, with thinking and prompt cache.
- Cost in USD from the models.dev catalog.
- Approval rules in config files; allow a `bash` prefix, a tool or edits for the session.
- Read-only `bash` commands in the session folder run without asking.
- MCP servers on stdio and streamable HTTP.
- Agent Skills from `.finn/skills`, `.agents/skills` and `.claude/skills`.
- Code mode (`FINN_CODE_MODE=1`): the model calls tools from a sandboxed Python script.
- Extensions: your own program serves Finn's core with its tools, wrappers and prompts.
- `finn server status|start|stop|restart|logs` manages the server.

### Fixed

- A `!` command that a server restart cut ends as failed instead of running forever.
- Esc stops the turn it was pressed for, never the next one.
- `finn` stays fast with long pasted lines and long transcripts.
