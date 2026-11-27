---
title: Configuration
description: Finn's config files, its environment variables and the folders where it keeps its state, sessions and keys.
weight: 30
---

# Configuration

Finn reads environment variables when the server starts, and a few JSON files. A flag of `finn serve` sets its variable: `--api`, `--provider`, `--model`, `--base-url` and `--approvals`.

## The user's config file

`~/.config/finn/config.json` (`$XDG_CONFIG_HOME/finn/config.json` when that is set; `FINN_CONFIG` names another file):

```json
{
  "approvals": false,
  "permission": ["ask bash(*)", "allow bash(npm test *)", "deny read_file(.env*)", "deny bash(rm *)"],
  "providers": [
    {"name": "together", "base_url": "https://api.together.xyz/v1", "key_env": "TOGETHER_API_KEY"}
  ]
}
```

| Key | What it does |
|---|---|
| `approvals` | `true` makes a call of a [tool that asks](security.md#what-asks) wait for your answer, unless a rule allows it |
| `permission` | the rules, in order: the last one that matches a call allows it, asks or denies it; a file rule covers the file tools, and a `read_file` rule also, best effort, the files that `cat`, `grep` and the like name in `bash` ([how they check bash](security.md#how-rules-check-bash)) |
| `providers` | OpenAI-compatible APIs of your own ([Providers](providers.md#your-own-provider)) |
| `confine_files` | `true` keeps the file tools in the session folder; by default they reach any path ([The session folder](tools.md#the-session-folder)) |
| `mouse` | `false` starts `finn` with the mouse reporting off (the server reads it when it starts: restart it after a change), so the terminal selects text with a plain drag; `/mouse` turns it on ([Copying text](cli.md#copying-text)) |
| `clipboard`, `clipboard_command` | how `finn` copies a selection: `auto` (the default) picks tmux, a tool of the local display or OSC 52; `osc52`, `tmux` or `command` forces one, and `command` runs the program that `clipboard_command` lists, such as `["xclip", "-selection", "clipboard"]` ([Copying text](cli.md#copying-text)) |
| `keys` | change the keys of `finn`: an object from an action to a key, such as `{"thinking_level": "f3", "logs": "f9"}`; case is ignored, a name has no spaces inside, the old key of an action that moved stops working, and Esc is fixed ([Keys of the full screen](cli.md#keys-of-the-full-screen)) |
| `status_line` | the segments of the status row of `finn`, an object with `left` and `right` lists of names ([The status line](#the-status-line)) |
| `skills` | extra user and trusted-project skill paths; other agents' folders are opt-in ([Skills](skills.md#where-finn-finds-them)) |
| `files` | `{"command": ["rg", "--files"]}`: the program that lists the files for the `@` completion, in place of the built-in walk ([The files command](#the-files-command)) |

Every key is optional, and so is the file. How the rules work is on [Approvals and security](security.md#rules), and where they fall short in [What rules cannot do](security.md#what-rules-cannot-do).

### The files command

`files.command` names a program and its arguments, such as `["rg", "--files"]`, `["fd", "-t", "f"]` or `["git", "-c", "core.fsmonitor=false", "ls-files"]`. Only your own config file can name it: a project's `.finn/config.json` cannot, since a cloned repository must not choose what runs when you type `@`. The command runs unasked in every session folder, so pick a program that runs nothing from that folder's config: `rg --files` and `fd` run nothing, while a plain `git ls-files` runs the program that the folder's `.git/config` names in `core.fsmonitor`, which a folder that comes with its `.git/` (a tarball, a zip, a shared folder) can set.

The server runs it in the session folder as the `bash` tool runs a command: in its own process group, with a clean environment and no input. It reads one path per line, for 2 seconds at most, up to 20000 lines and 1 MiB. The command only proposes paths: a path stays only when it is a regular file inside the folder, reached through no link, with a printable name, and no `read_file` deny rule hides it or a folder above it. An `ask` rule hides nothing from the list; only a `deny` rule does. Which hidden files and build folders it lists is the command's choice, unlike the built-in walk, which skips them. If the command fails or does not end in time, the built-in walk lists the files, and `finn` shows a note that says why. Whatever the command started is killed when the list is read.

### The status line

`status_line` sets which segments the status row of `finn` shows, and in what order: `{"status_line": {"left": ["state", "usage", "rate", "chatgpt.quota", "hints"], "right": ["model"]}}`. A side that is missing is empty. The built-in segments are `state` (`ready`, `YOLO`, `approval waiting`), `usage` (the [counts](cli.md#footer-of-the-full-screen)), `rate`, `hints` and `model`; `chatgpt.quota` is the remaining five-hour and seven-day quota of a ChatGPT session, such as `5h 62% · 7d 80%`, and an [extension](extensions.md#status-line-segments) can add more names. A name that no segment has, or a segment with no text now, is skipped without a word.

Without `status_line` the row is the one above, with `chatgpt.quota` after the rate. When the row is too narrow, a layout of your own loses whole segments from the end of the right side, then from the end of the left; the last one is cut with `…`. List a segment you want to keep longest first on the left.

A `status_line` that is not an object, or whose `left` or `right` is not a list of names, never stops the server: the default row stays, with a warning in the log and in the report of `/reload`.

`/reload` applies a change.

## The project file

`.finn/config.json` in the folder of a session holds `permission` rules for that project, which come after yours. Its `deny` rules always count. Its `allow` and `ask` rules count only when the folder is under a trusted folder, since an `ask` after your `deny` would win over it. A file with the old `allow` and `deny` keys is ignored there with a warning that names the rules to write. A project file cannot turn the approvals on or off.

## Trusted folders

`FINN_TRUSTED_DIRS` lists folders, separated by `:`. A session in one of them, or below, reads what anyone who can write its repository could plant:

- the `allow` and `ask` rules of its `.finn/config.json`;
- its skills ([Skills](skills.md));
- its slash commands, in `.finn/commands/` ([Slash commands](cli.md#slash-commands));
- its profiles, in `.finn/profiles/`, which choose the tools, the model (on the session's provider) and the thinking level ([Profiles](tools.md#profiles));
- its MCP servers, in `.finn/mcp.json`, which start programs ([MCP](mcp.md#a-project-file)).

The deny rules of a project count everywhere.

## Folders

| What | Where | Variable |
|---|---|---|
| state: `server.json`, the log, the model catalog, MCP logs | `~/.local/state/finn` | `FINN_STATE_DIR` (else `$XDG_STATE_HOME/finn`) |
| sessions, one file each | `~/.local/share/finn/sessions` | `FINN_DATA_DIR` (else `$XDG_DATA_HOME/finn`) |
| config and stored keys | `~/.config/finn` | `$XDG_CONFIG_HOME/finn` |
| the Monty worker of code mode | `~/.cache/finn` | `$XDG_CACHE_HOME/finn` |

The server makes the state and data folders with mode 0700, and refuses one that others can open or that is a link. Only the folder itself is checked: a link higher up its path is fine.

## The provider and model of a new session

A new session takes its provider and model from the first of these that names them:

1. the request that opens it (`--provider` and `--model` of `finn`, `/new`, or the API);
2. `FINN_PROVIDER` (or `FINN_API` or `FINN_BASE_URL`, which choose the provider too) and `FINN_MODEL`, which win over the choice below, each for what it names;
3. the choice last made: the server keeps the provider and model you picked with `/model`, with `finn --provider P --model M`, or by a login with no choice yet (the provider's first model) in `choice.json` of its state folder (mode 0600);
4. `local`.

A one-shot run (`finn -p`) never changes the choice, so a script does not reset your default. `/new` opens the next session with the options of the start, so `finn --model x` keeps `x` through `/new` and makes it the choice again. A choice whose provider is not offered any more (its key is gone), or whose model is not in the `models` list of its provider, is skipped with one warning at the start. Delete `choice.json` to forget it.

## Reload

`/reload` (`POST /v1/reload`) makes the running server read these again, with no restart and without stopping a turn:

- the user's config file: the permission rules and `approvals`, `files.command`, `mouse`, `status_line`, skill paths and the providers it adds;
- the MCP servers (the user's file, `FINN_MCP_CONFIG`, and the `.finn/mcp.json` of each folder with sessions): when a list changed, its servers stop and the new list starts (a call that runs on a stopped one fails, and the new tools come as the servers list them); only MCP servers reload, not extensions registered in code;
- the skills, `AGENTS.md` and approval rules of each running session. If Finn cannot save the updated prompt for a restart, it reports a warning and applies the changes to the running session.

A session that runs uses them from its next turn; a turn that runs keeps what it started with. The answers that a session gave with "always" are forgotten, the accept-edits mode stays. A new session, or one that loads later, reads everything fresh. The answer says what changed (`skills: 2 added, 1 removed; config reloaded (3 rules, approvals on); restarting 1 MCP server(s)`), and the warnings of the load go to `/logs`. Two reloads never run at once, and a draining server refuses one.

A config file that does not read stays as it was, with the reason as a warning: a reload never leaves the server without a config. Environment variables, the model catalog and `FINN_STATE_DIR` are not read again, and `confine_files` stays per session (`/confine`).

## Environment variables

| Variable | What it does |
|---|---|
| `FINN_API` | the API of `local`: `openai` (chat completions, the default) or `openai_responses`; `anthropic` makes Anthropic the server's provider |
| `FINN_BASE_URL` | where `local` is: `http://127.0.0.1:8080/v1` by default |
| `FINN_API_KEY` | the key of `local` |
| `FINN_PROVIDER` | the provider of a session that names none (wins over the last choice) |
| `FINN_MODEL` | the model of a session that names none (wins over the last choice) |
| `FINN_CONFINE_FILES` | `1` keeps the file tools in the session folder, `0` lets them reach any path, over the config file |
| `FINN_APPROVALS` | `1` turns the approvals on; `0` keeps them off over the config file |
| `FINN_CONFIG` | the user's config file |
| `FINN_THEME` | the HTML file whose `<style>` blocks style the full screen (`theme.html` next to the config file by default) |
| `FINN_TRUSTED_DIRS` | the [trusted folders](#trusted-folders) |
| `FINN_HOME` | the install, the folder with `docs/`: `bin/finn` sets it, for the [skill `finn`](skills.md#the-finn-skill) and `finn docs` |
| `FINN_MCP_CONFIG` | the JSON file of MCP servers, in place of `~/.config/finn/mcp.json` ([MCP](mcp.md)) |
| `FINN_CODE_MODE` | `0` turns off code mode, the `run_script` tool, as `--no-codemode` does; on by default ([Tools](tools.md#code-mode)) |
| `FINN_RESTART` | `1` restarts a server of another version without asking, as `--restart` does ([versions](cli.md#versions)) |
| `FINN_MONTY` | a Monty 1.6.0 binary you trust, for code mode |
| `FINN_CONTEXT_WINDOW` | the model's context window in tokens, for compaction |
| `FINN_MAX_TOKENS` | the most tokens of one reply, thinking included; by default the model's own limit from the models.dev catalog, else none on the OpenAI APIs (the provider's maximum) and 64000 on Anthropic |
| `FINN_COMPACT_MODEL` | the model that writes the summary of a compaction ([Sessions](sessions.md#compaction)) |
| `FINN_MODELS_URL` | the models.dev catalog of prices and windows; `off` for none |
| `FINN_MODELS_PROVIDER` | the provider of the model in that catalog |
| `FINN_DRAIN_MS` | how long `finn server stop` waits for the running turns (60000) |
| `FINN_WAKES_MAX` | how often an extension may wake a session per user message (100; `0` for no cap): past the cap a wake parks for the next user message |
| `FINN_HTTP2` | `0` or `off` keeps HTTP/1.1 to the model providers; by default an `https://` provider is reached over HTTP/2 (ALPN) and a plain `http://` one over HTTP/1.1 |
| `FINN_STATE_DIR`, `FINN_DATA_DIR` | the folders above |
| `FINN_SERVER_COMMAND` | the program a client runs to start a server |

The key variables of the providers are on [Providers](providers.md).

### The theme file

`FINN_THEME` names the HTML file whose `<style>` blocks style the full screen (`theme.html` next to the config file by default; with no known config folder there is none).
- selectors name a region: `.transcript-user`, `.transcript-assistant`, `.transcript-bold`, `.transcript-heading`, `.transcript-code`, `.transcript-thinking`, `.transcript-notice`, `.transcript-tool`, `.transcript-arg-running`, `.transcript-arg-done`, `.transcript-arg-failed`, `.transcript-output`, `.transcript-removed`, `.transcript-added`, `.panel-head`, `.panel-text`, `.panel-selected`, `.panel-removed`, `.panel-added`, `.banner-text`, `.footer-status`, `.footer-status-<segment>`, `.editor-text`, `.editor-cursor`, `.rules-default`, `.rules-low`, `.rules-medium`, `.rules-high` (`.sidebar`, `.modal`, `.panel` and `.popover` style the panel text, `.notice` the notice, `.input` the prompt, `.tooltip` the banner).
- `.footer-status` is the base of the status row: its filler, separators and any segment no rule names. `.footer-status-<segment>` styles one named segment: `state`, `usage`, `rate`, `hints`, `model`, `chatgpt.quota` or an extension's name, lowercased with its dots kept (`.footer-status-chatgpt.quota` styles `chatgpt.quota`). Names that differ only in case share one entry; with no rule for it a segment draws in `.footer-status`, so a file that only sets `.footer-status` looks as before.
- shared screen parts draw with that mapping: `modal` (title `panel.head`, frame `panel.text`), `sidebar` (edge `panel.text`), `notice` (`banner.text`), `input_row` (text `editor.text`, cursor `editor.cursor`), `tooltip` and `popover` (frame `panel.text`), `select_list` (cursor `panel.selected`, rest `panel.text`).
- selectors are `.class`, `#id` or element names, matched case-insensitively; anything else is ignored.
- properties are `color` and `background-color` (a named color, `#rgb`/`#rrggbb` or `ansi(0)`–`ansi(255)`), `font-weight: bold`, `font-style: italic`, `text-decoration: underline` and `dim: true`; unknown properties and values are ignored.
- later rules win over earlier ones, declarations of one rule merge in order, and every change adds to the built-in theme instead of clearing it (even on eight-color terminals).
- a file that does not parse, or is over 1 MiB, keeps the built-in theme with a note; a missing file changes nothing.

Copy this to `theme.html` next to the config file and tweak it:

```html
<!DOCTYPE html>
<html>
<head>
<style>
.transcript-user { color: red; font-weight: bold; }
.transcript-code { color: magenta; }
.panel-selected { background-color: ansi(24); }
.banner-text { color: black; background-color: #ffcc00; }
.editor-text { color: white; }
.footer-status { color: ansi(245); font-style: italic; }
.footer-status-model { color: white; }
.footer-status-usage { color: ansi(250); }
.footer-status-chatgpt.quota { color: cyan; }
.rules-high { color: red; font-weight: bold; }
</style>
</head>
<body></body>
</html>
```

## Coming from agc-agent

Finn was called agc-agent before. Some old names still work:

- Most `AGC_AGENT_` variables still work in place of their `FINN_` names, but not `AGC_AGENT_CONFIG` or `AGC_AGENT_MCP_CONFIG`: while one is set without its `FINN_` name, `finn serve` does not start and says to set `FINN_CONFIG` or `FINN_MCP_CONFIG`.
- The state and data folders fall back to an `agc-agent` folder while there is no `finn` one.
- The config folder does not. While `config.json` is in `$XDG_CONFIG_HOME/agc-agent/` or `~/.config/agc-agent/` and not in the `finn` folder, `finn serve` does not start, so its deny rules are not lost: move it to the `finn` folder it names. An old `auth.json` only gets a warning at start: move it there too to keep its stored keys.
