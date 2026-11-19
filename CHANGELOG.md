# Changelog

## [Unreleased]

### Added

- `/confine [on|off]` keeps the file tools in the session folder (or lets them reach any path) for one session; `confine_files` in the config file and `FINN_CONFINE_FILES=1` do it for every session.
- `/reload` in `finn` and `finn chat` (`POST /v1/reload`) makes the server read the config file (rules, `approvals`, `files.command`, `mouse`, providers), the MCP servers, the skills and the `AGENTS.md` again without a restart: sessions that run use them from their next turn, a turn that runs is not stopped, and a config file that does not read is kept back with the reason. Only MCP servers reload, all of them when the list changed.
- In `finn`, a drag over the transcript selects text and letting go copies it (OSC 52) with a note; a double click selects a word and Esc clears the selection. `/mouse` turns the mouse reporting off and on, and `"mouse": false` in the config file starts with it off; Shift+drag (Option+drag in iTerm2) is the terminal's own selection.
- Every line of the server log starts with its UTC time and level (`2026-11-18T17:30:02.345Z WARNING ...`); `GET /v1/logs` gives its end and the warnings since the server started.
- `finn` and `finn chat` show the last 3 warnings of the server as notes when a session starts, `/logs [N]` shows the end of the server log, and leaving prints the warnings and `finn server logs` after the screen closes.
- A new session uses the provider and model last picked (`/model`, `finn --provider` and `--model`, or a login), kept in `choice.json` of the state folder; the order is the request, `FINN_PROVIDER`/`FINN_API`/`FINN_BASE_URL` and `FINN_MODEL`, the last choice, then `local`; `finn -p` never changes it. A login with no choice yet makes its provider the choice, and a first-start session on `local` moves there too.
- `finn login` prints one line after the screen closes: the provider, and `run finn to start` or `use finn --provider X, or /model, to use it`; Esc ends it with `finn: login cancelled` and status 0.

### Changed

- In `finn`, the warnings of the server show in a yellow banner at the top of the screen when it opens (a click or Esc with an empty prompt closes it), not as notes in the transcript. The server counts a warning with the same text once and shows it with `(×N)`, so a skill that is shadowed in three sessions is one warning.
- In `finn`, Enter on a row of the list under `/model `, `/resume `, `/tree ` or `/fork ` runs the command with that row (the first or the one you moved to) in one step, with no second picker; Tab still only completes.
- With approvals on, a file tool that reaches outside the session folder asks like `bash` does, unlike before when it was refused: `external_directory(FOLDER/*)` rules now cover file tools too (an allow rule lets a folder run, a deny rule refuses it). The accept-edits mode runs only writes inside the folder. Finn's own `auth.json`, `server.json`, `config.json` and `chatgpt.json` (in the config, state and data folders, and the file of `FINN_CONFIG`) are denied to the file tools by default, whatever the session folder; an `allow read_file(...)` rule of your config lifts it.
- **Breaking:** the file tools (`read_file`, `write_file`, `edit_file`, `apply_patch`, `glob`, `grep`) reach any path by default, not only the session folder, so the model can read `~/.bashrc` when asked; deny and ask rules still apply everywhere. Set `"confine_files": true` (config) or `FINN_CONFINE_FILES=1` to keep them in the folder.

### Fixed

- `finn` no longer exits with `tui: set_cell failed: Out of bounds (-9)` when the terminal is resized while it draws (tmux or a phone terminal changing size at the start); cells off the screen are dropped, and a draw that a resize cuts short is redrawn by the `Resize` that comes with it.
- A new session on a provider with no model of its own waits for the model catalog (up to 1.5 s) before taking the first model it lists, instead of starting on `default`; a model you picked that is not in the provider's `models` list is kept, with a warning.
- A refusal or a connection failure of the `local` provider says `pick a provider with /model, or log in with /login` (and is a warning in `/logs`); a successful `finn login chatgpt` followed by `finn` no longer opens a session on `local` that fails with HTTP 401.
- `finn login chatgpt` works again: OpenAI answers the device code with its `interval` as text, which the login did not read.
- A `finn` that ends with an error prints why after the screen closes, also a failed `finn login`; it ended with code 1 and said nothing.
- A session file with no `created_ms` in its header (one of an early version) is listed, as the oldest, with no warning at each start.

## [finn-20261118140503] - 2026-11-18

### Fixed

- Skills folders that are links to one folder (such as `~/.agents/skills` and `~/.claude/skills`) are read once, with no "shadowed by a skill of the same name" warning for each skill.

## [finn-20261118122340] - 2026-11-18

### Changed

- The `bash` package, and so `core`, no longer holds a file over 1 MiB and downloads a prebuilt native library (release `bash-native-d63bc6fb66ee45a8`) for linux x86_64 and arm64, macos x86_64 and arm64, and windows x86_64, so a fetched package needs no C compiler; a tag `bash-native-<key>` builds and releases them.
- tree-sitter-bash's parser comes from a git submodule: after updating a clone, run `make install` once to fetch it.
- The packages of the repository have no tags of their own any more, only `finn-<ts>`; using `core` from outside the repository waits for agentica#1850.
- The version of Finn is the UTC time of its commit (`20261118123456`), with a `finn-` tag per merge to main; a client says when its server is older or newer and names `finn server restart`, never a `kill`. `finn server stop` ends a server that does not take the request by its pid (`--now` forces it).
- **Breaking:** Finn needs Agentica 0.34.0. A model stream that is silent for 2 minutes now fails, rather than hanging; the event stream of a session has no read limit.
- A resumed session shows the thinking, tool calls and stop notes of its turns, not only the messages; the session line comes first.
- Leaving `finn` or `finn chat` prints how to come back to the session (`finn --session ID`), unless it is empty.
- The footer shows no exact tok/s for a reply that came in one burst.
- The full screen's footer shows the model's output speed (`42 tok/s`; `~42 tok/s` while a reply streams); `usage` events carry `output_ms`.
- `/resume` leaves out the session itself and the sessions with no message yet; `GET /v1/sessions` marks those `empty`.
- **Breaking:** `finn` opens the full screen, as `finn tui` does; `finn chat` is the line chat.
- **Breaking:** tools run without asking by default; turn approvals on with `finn serve --approvals`.
- **Breaking:** `finn --yolo` allows only the tool calls of the turns it starts.
- **Breaking:** the command is `finn` and variables are `FINN_*`; most `AGC_AGENT_*` names still work.
- **Breaking:** an old `agc-agent` `config.json`, `AGC_AGENT_CONFIG` or `AGC_AGENT_MCP_CONFIG` stops `finn serve` and says where to move it; an old `auth.json` warns.
- **Breaking:** with approvals on, a `bash` command that only reads asks too; only an allow rule or an answer runs it.
- **Breaking:** rules are OpenCode's: one `permission` list (`"allow bash(git *)"`, `"ask read_file(*.env)"`), the last match wins; `allow` and `deny` keys stop the start.
- `bash` rules check each command of the line (tree-sitter-bash); a line it cannot read clearly asks.
- "Always" (`allow_prefix`) allows `NAME *` for a short list of plain programs (`ls *`), and the exact command for any other program, a redirection or a substitution.
- **Breaking:** the state and data folders cannot be links; give the folder the link points to.
- `external_directory` rules check the paths outside the session folder that `cd`, `rm`, `cp` and the like name.
- **Breaking:** with approvals on, reads of `.env` files ask by default.
- `read_file` rules also check, best effort, the files `cat`, `head`, `tail`, `grep`, `wc`, `diff` and `cp` name in `bash` (`cat .env` asks); "always" on these programs allows the same command only.
- The first start builds the bash parser; clients wait up to a minute and say so.
- `finn chat` and `finn tui` refuse a server of another version and say how to stop it.
- **Breaking:** code mode (`run_script`) is on by default; `--no-codemode` or `FINN_CODE_MODE=0` turns it off, and a client says when the running server's differs.

### Added

- Finn reads its own documentation: a built-in skill `finn` (lowest precedence) lists the pages of `docs/content` of the install for the model to read in place, and `finn docs [PAGE]` prints them.
- Provider `opencode-go` (OpenCode Go): `finn login opencode-go` or `OPENCODE_API_KEY`, then `--provider opencode-go`; its default model is `deepseek-v4.1-flash`.
- A model that models.dev gives its own API (Anthropic, Responses, Google) on an OpenAI-compatible provider is not listed by `/model`.
- An extension tool's `Core.Call` names its session (`session`).
- Extensions can change or stop a tool call before its approval: `Core.Event.ToolBefore(fn)` gives `Core.Check.Go`, `Input(json)` or `Stop(reason)`.
- Extensions can observe the sessions: `Core.Event.Seen(names, fn)` gets the events it names, with `session_started` and `session_ended`, and never slows a turn.
- `finn login chatgpt` (`/login chatgpt`) signs in with a ChatGPT Plus or Pro plan: Finn shows a URL and a code, then runs the Codex models of the plan.
- Code mode checks its cached Monty worker before each use, runs it once after the fetch, does not fetch again for 10 minutes after a failure, and starts it with an empty environment; `finn server status` shows code mode.
- A reply may be as long as the model allows (its output limit from models.dev, else the provider's), not 4096 tokens; `FINN_MAX_TOKENS` sets a limit, and a cut reply says which.
- `files.command` in the user's config names the program that lists the files for `@`, such as `rg --files`.
- Slash commands: `/NAME` sends the prompt of `NAME.md` in `~/.config/finn/commands/` or a trusted `.finn/commands/`, with `$ARGUMENTS`.
- With approvals on, a file change under `.finn/` always asks, as one under `.git/` does.
- Profiles: `--profile NAME` or `/profile NAME` picks the tools the model sees, and may set its model and thinking level; `build` (every tool) and `plan` (reads only) are built in, `NAME.md` files add more, and the footer names the profile.
- `finn`: Ctrl+G edits the prompt in `$VISUAL` or `$EDITOR`.
- `/export [PATH]` and `finn export SESSION [PATH]` write the branch a session is on to a Markdown file (0600).
- Finn Agent, a coding agent: `finn` (full screen) and `finn chat` (lines) talk to a local server.
- Tools: read, write and edit files, `glob`, `grep`, `bash`, and `apply_patch` for models that use it.
- `todo_write`: the model keeps a todo list that `finn` and `finn chat` show and the session keeps.
- **Breaking:** an extension tool named `todo_write` stops the start, as the name is now taken.
- `finn -p TASK` runs one task and prints the answer.
- Sessions are kept on disk and resume after a restart; `finn --delete ID` removes one.
- Long histories are compacted into a summary before the context window fills.
- Session commands: `/new`, `/resume`, `/model`, `/thinking`, `/compact`, `/stop`, `/help` and `/quit`; `/tree`, `/fork` and `/clone` go back in a session, branch it into a new one, or copy it. `finn` completes their arguments with Tab.
- A message sent while a turn runs is queued and read before the next model call.
- `!CMD` runs a shell command in the session folder; `!!CMD` keeps its output from the model.
- `finn` keys: `@` completes files, `/` lists commands, Alt+Enter queues a follow-up, Up recalls prompts, and pi's editing keys (Ctrl+A/E, Ctrl+W, Ctrl+U/K, word moves, Ctrl+D on an empty prompt).
- `finn` shows a footer: the folder, git branch and first message, the last call's tokens and context, the session's cost, and the model.
- `finn` shows tool output and diffs, takes the mouse, and keeps a large paste as one token.
- Providers: local, anthropic, openai, fireworks, openrouter, groq, deepseek and custom; `/model provider/model` switches.
- `finn login` and `finn logout` store and remove a provider key; `finn login local` stores the base URL of a local server.
- The `openai_responses` and `anthropic` APIs, with thinking and prompt cache.
- Cost in USD from the models.dev catalog.
- Approval rules in config files; allow a `bash` prefix, a tool or edits for the session.
- MCP servers on stdio and streamable HTTP.
- Agent Skills from `.finn/skills`, `.agents/skills` and `.claude/skills`.
- Code mode (`FINN_CODE_MODE=1`): the model calls tools from a sandboxed Python script.
- Extensions: your own program serves Finn's core with its tools, wrappers and prompts.
- `finn server status|start|stop|restart|logs` manages the server.

### Fixed

- `finn`: Enter on the list after `/model `, `/resume `, `/tree `, `/fork `, `/profile ` or `/thinking ` runs the command with the row moved to, instead of opening a second list whose pick won; the list starts on the session's model or level.
- A login offers a session on `local` the models of the provider it set up, so a first start no longer stays on a local server that does not answer; Esc keeps `local`.
- `/model NAME` with a name only another provider lists names that provider's models instead of keeping the session on its provider with a wrong name.
- A `!` command that a server restart cut ends as failed instead of running forever.
- Esc stops the turn it was pressed for, never the next one.
- `finn` stays fast with long pasted lines and long transcripts.
