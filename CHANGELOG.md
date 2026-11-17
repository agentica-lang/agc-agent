# Changelog

## [Unreleased]

### Changed

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

### Added

- Profiles: `--profile NAME` picks the tools the model sees; `build` (every tool) and `plan` (reads only) are built in, `NAME.md` files add more, and the clients name the profile and show its warnings.
- `finn`: Ctrl+G edits the prompt in `$VISUAL` or `$EDITOR`.
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

- A `!` command that a server restart cut ends as failed instead of running forever.
- Esc stops the turn it was pressed for, never the next one.
- `finn` stays fast with long pasted lines and long transcripts.
