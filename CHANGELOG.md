# Changelog

## [Unreleased]

### Changed

- A merge to main that changes only `docs/`, Markdown files or `.github/` makes no `finn-<ts>` tag any more.

## [finn-20261119085524] - 2026-11-19

### Changed

- **Breaking:** the file tools (`read_file`, `write_file`, `edit_file`, `apply_patch`, `glob`, `grep`) reach any path by default, not only the session folder; deny and ask rules still apply everywhere. `/confine on`, `"confine_files": true` or `FINN_CONFINE_FILES=1` keeps them in the folder.
- With approvals on, a file tool outside the session folder asks like `bash` does, not refused; `external_directory(FOLDER/*)` rules cover it, and accept-edits mode runs only writes inside the folder. Finn's own `auth.json`, `server.json`, `config.json` and `chatgpt.json` are denied to the file tools unless an `allow read_file(...)` rule lifts it.
- `finn` shows the server's warnings in a yellow banner when it opens, a repeated warning counted once (`(×N)`), instead of notes in the transcript.
- In the `/model`, `/resume`, `/tree` and `/fork` lists, Enter runs the command with that row in one step; Tab still only completes.

### Added

- `finn` has a side panel for local output (`/logs`, followed live, `/help`, `/reload`, `/profile`), so the transcript holds only the conversation.
- `finn` selects text with the mouse (drag, double click for a word, Esc to clear) and copies it to the clipboard: a local tool, `tmux load-buffer` over SSH in tmux, else OSC 52; `clipboard` in the config file forces one way, `/mouse` turns the mouse off and on, and `"mouse": false` starts with it off.
- `/reload` (`POST /v1/reload`) reads the config file, the MCP servers, the skills and `AGENTS.md` again without a restart.
- `/confine [on|off]` keeps the file tools in the session folder for one session; `confine_files` in the config file does it for every session.
- A new session uses the provider and model last picked (`/model`, `--provider`, `--model` or a login), kept in `choice.json`.
- Every server log line starts with its UTC time and level; `GET /v1/logs` and `/logs [N]` show its end, and leaving `finn` prints the warnings.
- `finn login` ends with one line on how to use the provider; Esc ends it with `finn: login cancelled` and status 0.
- In `finn`, the warnings of the server show in a yellow banner at the top of the screen when it opens (a click or Esc with an empty prompt closes it), not as notes in the transcript. The server counts a warning with the same text once and shows it with `(×N)`, so a skill that is shadowed in three sessions is one warning.
- In `finn`, Enter on a row of the list under `/model `, `/resume `, `/tree ` or `/fork ` runs the command with that row (the first or the one you moved to) in one step, with no second picker; Tab still only completes.
- With approvals on, a file tool that reaches outside the session folder asks like `bash` does, unlike before when it was refused: `external_directory(FOLDER/*)` rules now cover file tools too (an allow rule lets a folder run, a deny rule refuses it). The accept-edits mode runs only writes inside the folder. Finn's own `auth.json`, `server.json`, `config.json` and `chatgpt.json` (in the config, state and data folders, and the file of `FINN_CONFIG`) are denied to the file tools by default, whatever the session folder; an `allow read_file(...)` rule of your config lifts it.
- **Breaking:** the file tools (`read_file`, `write_file`, `edit_file`, `apply_patch`, `glob`, `grep`) reach any path by default, not only the session folder, so the model can read `~/.bashrc` when asked; deny and ask rules still apply everywhere. Set `"confine_files": true` (config) or `FINN_CONFINE_FILES=1` to keep them in the folder.

### Fixed

- `finn` no longer exits with `tui: set_cell failed: Out of bounds (-9)` when a terminal resize lands while it draws.
- A copy that only went to the terminal (OSC 52) says `sent N characters to the terminal`, not `copied`, since tmux can drop it (#319).
- `finn login chatgpt` works again, and after it `finn` no longer opens a session on `local` that fails with HTTP 401; a `local` provider that is down says to use `/model` or `/login`.
- A new session waits up to 1.5 s for the model catalog before taking its first model, not `default`.
- A `finn` that ends with an error prints why after the screen closes.
- A session file with no `created_ms` is listed, as the oldest, with no warning at each start.

## [finn-20261118140503] - 2026-11-18

### Fixed

- Skills folders that are links to one folder (such as `~/.agents/skills` and `~/.claude/skills`) are read once, with no "shadowed by a skill of the same name" warning for each skill.

## [finn-20261118122340] - 2026-11-18

### Changed

- **Breaking:** the command is `finn` and variables are `FINN_*` (most `AGC_AGENT_*` names still work); an old `agc-agent` `config.json`, `AGC_AGENT_CONFIG` or `AGC_AGENT_MCP_CONFIG` stops `finn serve` and says where to move it, and an old `auth.json` warns.
- **Breaking:** Finn needs Agentica 0.34.0. A model stream that is silent for 2 minutes now fails, rather than hanging; the event stream of a session has no read limit.
- **Breaking:** `finn` opens the full screen, as `finn tui` does; `finn chat` is the line chat.
- **Breaking:** tools run without asking by default; turn approvals on with `finn serve --approvals`. `finn --yolo` allows only the tool calls of the turns it starts.
- **Breaking:** rules are OpenCode's: one `permission` list (`"allow bash(git *)"`, `"ask read_file(*.env)"`), the last match wins; `allow` and `deny` keys stop the start.
- **Breaking:** with approvals on, a `bash` command that only reads asks too, and so do reads of `.env` files; only an allow rule or an answer runs them.
- **Breaking:** the state and data folders cannot be links; give the folder the link points to.
- **Breaking:** code mode (`run_script`) is on by default; `--no-codemode` or `FINN_CODE_MODE=0` turns it off, and a client says when the running server's differs.
- `bash` rules check each command of the line (tree-sitter-bash); a line it cannot read clearly asks. `external_directory` rules check the paths outside the session folder that `cd`, `rm`, `cp` and the like name, and `read_file` rules check, best effort, the files `cat`, `head`, `tail`, `grep`, `wc`, `diff` and `cp` name.
- "Always" (`allow_prefix`) allows `NAME *` for a short list of plain programs (`ls *`), and the exact command for any other program, a redirection or a substitution.
- The version of Finn is the UTC time of its commit (`20261118123456`), with a `finn-` tag per merge to main; a client says when its server is older or newer and names `finn server restart`, and `finn chat` and `finn tui` refuse a server of another version. `finn server stop` ends a server that does not take the request by its pid (`--now` forces it).
- The `bash` package, and so `core`, holds no file over 1 MiB and downloads a prebuilt native library (release `bash-native-d63bc6fb66ee45a8`) for linux, macos and windows, so a fetched package needs no C compiler; the bash parser comes from a git submodule, so run `make install` once after updating a clone.
- The packages of the repository have no tags of their own, only `finn-<ts>`; using `core` from outside the repository waits for agentica#1850.
- The first start builds the bash parser; clients wait up to a minute and say so.
- A resumed session shows the thinking, tool calls and stop notes of its turns, and leaving `finn` or `finn chat` prints how to come back to it (`finn --session ID`).
- The footer shows the model's output speed (`42 tok/s`); `usage` events carry `output_ms`.
- `/resume` leaves out the session itself and the sessions with no message yet; `GET /v1/sessions` marks those `empty`.

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
