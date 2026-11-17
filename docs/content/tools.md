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
| `apply_patch` | add, delete and change files with one patch, in the format of Codex; offered on the OpenAI Responses API only |

Skills add `activate_skill` ([Skills](skills.md)), MCP servers add their own tools ([MCP](mcp.md)), and an [extension](extensions.md) can add more. Which calls ask before they run is on [Approvals and security](security.md#what-asks).

The model sees at most 30000 characters of a tool's output; the rest is cut, with a note that says how long it was.

## The session folder

The file tools reach only files whose real path is inside the session folder: a `..` or a link that leads out is refused. `read_file` also reads the files of a skill the session can load. `glob` and `grep` never follow a link.

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

`FINN_CODE_MODE=1` adds `run_script`: the model writes a short Python script that calls the tools as plain functions (`read_file(path="a.txt")`). The script runs in [Monty](https://github.com/pydantic/monty), pydantic's Python sandbox. Each call from the script goes through the same checks and approvals as a direct call; a denied call raises `PermissionError`. Only what the script prints and its last value go back to the model.

The Monty worker is `FINN_MONTY` (a Monty 1.6.0 binary you trust: its hash is not checked), else the pinned Monty 1.6.0, fetched from PyPI on first use into `~/.cache/finn` with its sha256 checked.
