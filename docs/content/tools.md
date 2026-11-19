---
title: Tools
description: The tools Finn gives the model, the folder they are kept in, what bash can and cannot do, and code mode.
weight: 60
---

# Tools

The model works through tools. Each call shows in the client: the file it reads or edits, the command it runs.

## The built-in tools

| Tool | What it does |
|---|---|
| `read_file` | read a text file, from a line `offset`, `limit` lines (2000 by default, at most 5000) and at most 27000 characters |
| `write_file` | create or replace a file; missing folders are made |
| `edit_file` | replace `old_string` with `new_string`; it must occur once, unless `replace_all` |
| `glob` | list the files whose path matches a pattern such as `**/*.py` |
| `grep` | find the lines that match a regex, in the files a `glob` picks |
| `bash` | run a command with bash in the session folder |
| `todo_write` | keep a todo list for a task of several steps: each call gives the whole list, at most 100 items of at most 500 characters, each `pending`, `in_progress` or `completed` and one in progress at most; the clients show it, the session keeps it, and a compaction gives it back to the model |
| `apply_patch` | add, delete and change files with one patch, in the format of Codex; offered on the OpenAI Responses API only |

Skills add `activate_skill` ([Skills](skills.md)), MCP servers add their own tools ([MCP](mcp.md)), and an [extension](extensions.md) can add more. Which calls ask before they run is on [Approvals and security](security.md#what-asks).

The model sees at most 30000 characters of a tool's output; the rest is cut, with a note that says how long it was.

## Profiles

A profile decides which tools the model of a session sees. Pick one for a new session with `--profile NAME`, or change it with `/profile NAME` between turns (`/profile` alone lists them, and Shift+Tab in `finn` goes to the next one; while a turn runs the change is refused). The session keeps its profile across a restart, a `/tree` move and a fork. There are two built in:

- `build`, the default: every tool;
- `plan`: `read_file`, `glob`, `grep`, `todo_write` and `activate_skill`, with a note in the system prompt to change nothing. No `bash`, no writes, no MCP tools.

A profile is a file `NAME.md` in `~/.config/finn/profiles/` (`$XDG_CONFIG_HOME/finn/profiles/`), or in `.finn/profiles/` of a [trusted](config.md#trusted-folders) project, which wins over yours. A file named `build.md` or `plan.md` replaces the built-in one, so a trusted project may replace `plan`; a project file that replaces a profile is a warning the clients show. NAME is lowercase letters, digits, `-` and `_`: another `.md` file there (a `README.md`, a link out of the folder) is skipped with a warning.

```markdown
---
description: Reads and plans, changes nothing
tools_allow: [read_file, grep, glob, todo_write, "mcp__github__*"]
model: anthropic/claude-sonnet-4-5
thinking: high
---
Plan the change. Do not edit files.
```

- `description` says what the profile is for.
- `tools_allow` shows only the tools it names, and `tools_deny` all but those; set one of them, or neither for every tool. A `*` matches any text, so `mcp__github__*` covers one MCP server. An empty `tools_allow` shows no tool, with a warning.
- `model` (`[PROVIDER/]NAME`) and `thinking` (`low`, `medium`, `high` or `default`) change the session's model and thinking level when the profile is chosen; a `--model`, `--provider` or `/model` given then wins, and a later profile without them keeps the session's. A project's profile stays on the session's provider: its whole `model` is a model name there.
- The text after the front matter goes after the system prompt.

A file that does not load (an unknown key, both lists) fails only its own name: choosing it is an error with the file and the key, and the server warns about it when it starts. A name in a list that no tool has is a warning the clients show. A saved session whose profile is gone or broken stays closed: it shows no tool and refuses its turns. It opens again with `/profile NAME`, or on a restart once the file is back and loads.

A profile only hides tools from the model: a call to a hidden one is refused, and the [approval rules](security.md) still decide on the calls of the tools it shows. A profile never allows what a rule denies. A `!command` you type is yours: a profile does not limit it.

## The session folder

The file tools reach any path the server can: `read_file`, `write_file`, `edit_file`, `apply_patch`, `glob` and `grep` take a path in any folder, as `bash` does. A relative path starts at the session folder. The [deny and ask rules](security.md#rules) apply to every path. With the approvals on, a path outside the session folder asks, as it does for `bash` ([why and how to allow it](security.md#what-asks)), and the accept-edits mode runs only the writes inside the folder.

To keep the file tools in the session folder, set `confine_files` to `true` in your [config file](config.md), or `FINN_CONFINE_FILES=1` for the server, or type `/confine on` in a session (`/confine off` undoes it, `/confine` shows it; it lasts until the server restarts). Then a path whose real path is outside the folder is refused, also through a `..` or a link, and `read_file` also reads the files of a skill the session can load. `glob` and `grep` never follow a link either way. A `glob` or `grep` that starts outside the folder (it may be `/`) stops after 5 seconds, 10000 files or 32 levels with a note, skips `/proc`, `/sys` and `/dev`, and leaves out the files a deny rule of `read_file` hides.

An `apply_patch` call is checked whole before any file changes. When a step fails, every file goes back as it was.

## bash

`bash` runs the command in its own process group, in the session folder, with no input. It times out after 2 minutes by default (`timeout_ms`, at most 10 minutes), and its output is cut at 1 MiB.

The command gets only a few variables of the server's environment (`PATH`, `HOME`, `USER`, `LANG`, `TERM`, `TMPDIR`, `SHELL` and some more), so the keys of your providers are not in it.

Bash is not a sandbox. The command runs as you, and can do what you can:

- It can still read the server's environment, keys included: `/proc/$PPID/environ` shows it to a process of the same user.
- A timeout or a stop kills the process group; a command that leaves it (`setsid`) outlives them.
- The paths a call names are checked before it runs, not while it runs.

To keep the model in, run Finn in a container or a sandbox ([Approvals and security](security.md)).

## Code mode

Code mode is on by default: the `run_script` tool, where the model writes a short Python script that calls the tools as plain functions (`read_file(path="a.txt")`). The script runs in [Monty](https://github.com/pydantic/monty), pydantic's Python sandbox. Each call from the script goes through the same checks and approvals as a direct call; a denied call raises `PermissionError`. Only what the script prints and its last value go back to the model.

The Monty worker is `FINN_MONTY` (a Monty 1.6.0 binary you trust: its hash is not checked), else the pinned Monty 1.6.0, fetched from PyPI at the first script (never at start) into `~/.cache/finn` with its sha256 checked. Where no Monty is pinned for the machine and `FINN_MONTY` is not set, `run_script` is not offered. The worker runs once (`--version`) before it is kept: one that cannot run here (a musl system, say) is not installed. A failed fetch is not tried again for 10 minutes. The cached worker is used only while `~/.cache/finn` and its `monty-1.6.0` folder are yours, no one else can write them, and the worker is a file, not a link. The worker runs with an empty environment, so it never sees your API keys.

`finn --no-codemode` (also `finn chat`, `finn serve` and `finn server start` or `restart`) or `FINN_CODE_MODE=0` turns code mode off. It is set when the server starts: when the running server's code mode is not the one you ask for, the client says so in one line, and `finn server restart` (with `--no-codemode` to turn it off) applies it.
