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
- `bash` rules check each command of the line (tree-sitter-bash); a line it cannot read clearly asks. File rules cover the file tools only.
- "Always" (`allow_prefix`) allows each command's first words from OpenCode's arity table (`npm run dev *`).
- "Always" on a command with an assignment or a redirect first, or with glob characters in its first words, allows only that exact command.
- `external_directory` rules check the paths outside the session folder that `cd`, `rm`, `cp` and the like name.
- **Breaking:** with approvals on, reads of `.env` files ask by default.
- The first start builds the bash parser; clients wait up to a minute and say so.
- `finn chat` and `finn tui` refuse a server of another version and say how to stop it.

### Added

- `finn`: Ctrl+Left/Right, Alt+B/F and Alt+Backspace work; Delete takes a whole character, word moves stop at line ends, and Up/Down keep their column.
- `finn` has pi's editing keys: Ctrl+A/E, Ctrl+W, Ctrl+U/K, Delete, Alt+Left/Right by word, Up/Down between the rows of the prompt, and Ctrl+D on an empty prompt quits.
- `finn` shows a footer: the folder, git branch and first message, then the last model call's tokens, cache and context, the session's cost, and the model with its thinking level.
- `finn login local` stores the base URL of a local server; `FINN_BASE_URL` wins.
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
- MCP servers on stdio and streamable HTTP.
- Agent Skills from `.finn/skills`, `.agents/skills` and `.claude/skills`.
- Code mode (`FINN_CODE_MODE=1`): the model calls tools from a sandboxed Python script.
- Extensions: your own program serves Finn's core with its tools, wrappers and prompts.
- `finn server status|start|stop|restart|logs` manages the server.

### Fixed

- A `!` command that a server restart cut ends as failed instead of running forever.
- Esc stops the turn it was pressed for, never the next one.
- `finn` stays fast with long pasted lines and long transcripts.
