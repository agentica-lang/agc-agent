# Changelog

## [Unreleased]

- Both clients show a child's tool calls under the open `agent` call, or as a labelled `child ID` group when concurrent or async children cannot be tied to one call; overlapping call ids of two children stay apart, and a child's approval prompt names its child while the routed id stays the approval's own. A queued, delivered, parked or woken message reads as who answered, never as typed input; an async child's answer arrives as an `extension` wake and is labelled so, never attributed from its text. The footer cost already covers the children's calls, summed by the server; a replay from the history shows the same call groups, but a wake's text there still reads as a user message, since the file keeps no provenance for it.
- `agent`, `agent_send` and `agent_stop` start and drive subagents over the session's handle: one child session per task with its own provider, model and profile, answers in input order (cut at 8000 characters) or ids with an async wake, a roster of the set-up profiles, user profiles that may cross providers and project profiles that stay, on by default and hidden by `tools_deny` (never in `plan`, `run_script`, or on a child), with `FINN_SUBAGENTS_MAX` (0 for no cap; an async batch that does not fit starts nothing) and `FINN_SUBAGENT_TIMEOUT_MS` (0 for no timeout); a parent's `/stop` during a waited call stops the children's turns and they stay open. A waited child that finishes is deleted with its answer; a timed-out or async child stays open for follow-up and dies with its parent.
- A child's approval id names its owner (`SESSION:aN`), so concurrent siblings and their parent never share an id: the parent's route answers a child's ask directly by its owner, never by first match, and a bare id only ever answers its own session. The parent's snapshot lists the children's pending asks with their owners, and a child's cost adds to the parent's turn sum only while the parent has a running turn (the session sums stay exact).
- A child's tool calls, approvals and usage reach its parent's stream with the child's id (`session`), saved in the parent's file and replayed with it; the child's text and thinking never do. A child's approval is answered on the parent's route, which reaches only the parent's own approvals and its children's. The parent's session allows count for the child, but its accept-edits mode does not, a child's asks wait while a client watches the parent, and the child's cost adds to the parent's turn and session sums while the parent keeps its own context.
- `turn_started` and `message_queued` carry who sent the message when the user did not (`source`: a child session's answer or an extension), and `tool_started`, `tool_finished`, `approval_requested` and `usage` carry the child session whose call it is (`session`).
- Extension tools can start child sessions on any configured provider, send to them, and watch, stop and delete them (`Core.Host`); a child takes its parent's provider, model and profile unless told otherwise, never shows more tools than its parent, and stays in memory and out of the session list.
- `Core.Host.send` to the session itself wakes it, and a child wakes its parent the same way (`child:ID` for a child's answer, `extension` otherwise); only a wake that starts a turn counts toward `FINN_WAKES_MAX` (100 per user message, 0 for no cap), past the cap or after a user stop a wake parks for the next user message (an empty `turn_id`), which takes parked wakes before its own and resets the count, so no watcher restarts a stopped parent. A stop that stops nothing leaves the wake window as it was. Parked wakes survive a restart and are taken exactly once, in order with the next user message (after a shell's output, if any); they stay with the session across a branch (a crash before the next user message no longer loses them, and moving back never brings back a consumed one) and stay out of forks and copies; the wake count and the stop window restart with the server, a wake during a shell or compaction is refused as `session.busy`, and a child may wake itself.
- A session can switch from OpenAI Responses to Chat Completions or Anthropic after `apply_patch`: Finn replays the old call and result in a compatible format, without offering or rerunning the patch.
- Large tool results, including errors, are saved as private session artifacts with a preview and paginated readback. When the encoded model request exceeds 1 MiB, Finn shortens tool results from both new and resumed sessions and tries again without rerunning the tools.
- OpenAI-format providers no longer fail with HTTP 400 on a tool with an `Int` or `UInt64` field: its 64-bit bounds are left out of the schema they get.
- `web_fetch` fetches an `http://` or `https://` URL for the model, as minibot's `http_request` does, but for public addresses only: the host is resolved, every address that is not public is refused (`web_fetch_private_address`), and the connection goes to the address that was checked. It asks for approval, follows no redirect, cuts the body at 16384 bytes, and gives HTML as compact text that keeps links, forms and tables (read in a task with a time limit and an input cap; a page that exceeds them comes as plain text).
- `agent_send` with `wait: false` to a child that a waited `agent` call started now wakes the session with the child's answer, as it does for a child an async call started: the wake is owed to the async turn itself (which holds the real session), never to the watcher the first call registered. The cap (`FINN_SUBAGENTS_MAX`) counts children with a running turn, so a `/stop` that cancels a waited call frees its slots at once and the parent can launch again; a follow-up keeps the profile's display name instead of showing the child id. An async answer that finishes before the call registers it still wakes the session exactly once with the headed answer, instead of failing the call (`the subagent ended before its turn started`) or losing the answer: the send records the turn it accepted and reconciles the finish from its snapshot, so a finish that lands early wakes nothing on its own, a late or duplicate turn never wakes and never hides the live turn from the cap, and a waited turn's answer still goes to its waiter first, with no turn, waiter or wake left behind. A finish racing the reconciling send wakes exactly once through a per-child claim, and a send contended by a live waiter removes neither the owed wake nor the waiter entry.

## [finn-20261126095207] - 2026-11-26

- A turn stops after 500 tool rounds (stop reason `max_rounds`, 50 before), and the loop guard also catches a cycle of two or three tool rounds that repeats three times in a row, not only three identical rounds.
- Finn needs Agentica 0.39.0: the pinned release, the `agentica` versions of the packages and the CI are updated, `monty` reads and writes frames and floats with the sized types of 0.38, `tui_client` builds on agentica-tui at the commit that renames its `Term`, and the `Terminal` import alias is `Tty`.
- `/mcp` opens a centered dialog that keeps the session visible around it and owns the keyboard until dismissed.
- The full-screen transcript renders Markdown pipe tables with aligned columns, styled headers and wrapping within each cell.
- Finn reuses HTTP connections for model provider requests and accepts gzip and deflate model lists.
- `FINN_THEME` (or `theme.html` next to the config file) styles the full screen: its `<style>` blocks name the theme regions (`.transcript-user`, `.panel-selected`, ...).
- User messages in the transcript draw on a subtle tinted background, so they read apart from the assistant's; CSS `.transcript-user` tunes it.
- The `/mcp` tools view, `/help` and `/shortcuts` list one entry per line with air between them and the names in bold (CSS `.panel-text` and `.panel-head` style them).
- Model provider calls to an `https://` API use HTTP/2 (negotiated with ALPN) on http-client 0.5.0, whose streams a session reads piece by piece; one whose peer does not negotiate `h2` falls back to HTTP/1.1 and stays there, a plain `http://` provider keeps HTTP/1.1, and `FINN_HTTP2=0` keeps HTTP/1.1 to every provider.
- `/reload` applies updated approval rules even if saving the updated session prompt fails.
- An MCP server that a request starts (a call, or a `/mcp` listing) is charged to `start_ms`, so the request still gets its whole `timeout_ms`; before, the start ate the request's budget and a slow server failed every call (and made the restart of a hung server flaky).
- Reopening an expired MCP HTTP session no longer waits past the original request deadline.
- Skills now default to `.finn/skills` only. Configure extra user and trusted-project paths with `skills` in `config.json`. Existing sessions pick up path changes on reload or resume.
- The full-screen status row shows the remaining ChatGPT five-hour and seven-day quota (`5h 62% · 7d 80%`) in ChatGPT sessions, and drops it first on a narrow row.
- `status_line` in the config file chooses and orders the segments of the full-screen status row; `/reload` applies it.
- Agentica extensions can add named status line segments with `Core.add_status_segment`.
- The full screen draws its banner through the shared notice component and the prompt's cursor row through the shared input-row component, with no visual change.
- The full screen draws its side panel edge through the shared sidebar segments, with no visual change.
- `.footer-status-<segment>` in the theme file styles one named segment of the full-screen status row (`state`, `usage`, `rate`, `hints`, `model`, `chatgpt.quota` or an extension's name, lowercased with its dots kept); `.footer-status` stays the base for the filler, the separators and any segment no rule names, so a file without segment rules looks as before.
- The full screen runs on agentica-tui 0.1.0, written in Agentica alone: no native termbox library is loaded, so there is no C code under the TUI. It draws on standard input and output, which must both be terminals, and reads SGR mouse reports only; a terminal that does not answer the status request of `ESC [ 5 n` delays the exit or the editor by half a second.
- `opencode-go` sends each model to the API that models.dev gives it (chat completions, OpenAI Responses or Anthropic Messages), so `/model` lists the Claude and GPT models of OpenCode Go too; models with another API (Google) stay hidden.
- A message sent while a turn runs shows above the prompt until the turn reads it, then moves into the transcript as a user message; the server sends a new `message_delivered` event when it does, and `finn chat` prints `[delivered]`.
### Changed

- The ChatGPT provider asks for the model catalog of Codex 0.171.0, which lists GPT-6.2 Sol and the other new models of your plan.

## [finn-20261119135800] - 2026-11-19

### Fixed

- `POST /v1/mcp/NAME/reconnect` answers `409` (`mcp.starting`) when the servers end while the new client starts, and not a connected server.

### Added

- `finn` and `finn chat` on a terminal ask `Restart it and go on? [Y/n]` when the server runs another version of Finn, instead of stopping (`[y/N]` and the running turns named while turns run); `--restart` or `FINN_RESTART=1` answers yes without asking.
- In `finn`, `/shortcuts` opens the side panel with every key in effect, one row each, with the ones your `keys` map sets and the keys of the `/mcp` panel; `/help` no longer ends with the keys.
- In `finn`, `/mcp` is a panel with a cursor: Up and Down (or `j` and `k`) move it, `r` reconnects the server under it, `t` or Enter lists its tools, `l` shows the end of its log, Esc goes back. The keys work only while the panel has the focus (F6). The server has `GET /v1/mcp/NAME/log`. The panel scrolls with the cursor and gives its keys up while the prompt has text.

### Changed

- Finn needs Agentica 0.35.0: the pinned release, the `agentica` versions of the packages and the Monty download are updated, the date of `finn export` comes from the builtin `Time`, and `core` can be used from outside the repository (`workspace = true`).

## [finn-20261119111956] - 2026-11-19

### Added

- `/mcp` shows the MCP servers and their states (`connecting`, `connected`, `failed` with the reason) in the side panel of `finn` (`finn chat` prints them), `/mcp NAME` lists the tools of one, and `/mcp reconnect NAME` starts one again (Tab completes the name); a server that failed at the start is in the banner. The server has `GET /v1/mcp` and `POST /v1/mcp/NAME/reconnect`.
- MCP servers come from `~/.config/finn/mcp.json` by default (`FINN_MCP_CONFIG` replaces it) and from `.finn/mcp.json` of a session folder under `FINN_TRUSTED_DIRS`: the servers of a project start with the first session in its folder and stop with the last one, a project server named like a user server is left out, and a project file cannot read `${NAME}` of the environment. `/reload` reads both files again.
- `keys` in the user's config file changes the keys of `finn` (`cycle_profile`, `thinking_level`, `show_thinking`, `show_tools`, `logs`, `side_focus`, `edit_prompt`, `page_up`, `page_down`): `{"keys": {"thinking_level": "f3"}}` (case is ignored, no spaces inside a name; the old key of a moved action stops working; Esc is fixed). A bad entry is a warning and keeps the default; `/reload` applies it, and the hints and `/help` show the keys in effect.
- In `finn`, Shift+Tab goes through the profiles (`build`, `plan`, then yours by name), from the next turn; a turn that runs refuses it with a note.

### Fixed

- In `finn`, `/prof` and Enter, then Enter or an arrow key before the profiles are listed, no longer runs the bare `/profile` and opens the side panel: keys typed before the list shows are dropped (Esc ends the wait), so press Enter again once it shows, and Enter on `/profile ` runs the profile of its row.

### Changed

- **Breaking:** the thinking level moves from Shift+Tab to F2 (`/thinking` stays), since Shift+Tab now cycles the profiles. F2 is free in tmux, readline and terminals, unlike Alt+T, which window managers take.
- **Breaking:** with the side panel open, Esc closes it whatever has the focus (a selection is cleared first); the next Esc does what it did before.
- `/help` ends with the keys, the panel's title names F6, and the footer says `^P logs` while the panel is closed.
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
