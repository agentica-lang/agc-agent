---
title: Approvals and security
description: What Finn's model may do on your machine, the deny and allow rules, the approvals, and how to run Finn in a sandbox.
weight: 90
---

# Approvals and security

Finn's model runs commands and edits files as you. Know what it can reach before you point it at a folder.

## The default: no approvals

The approvals are off by default. The model runs any command and edits any file that no deny rule refuses, without asking. Its file tools stay in the session folder ([Tools](tools.md#the-session-folder)), but `bash` can do whatever you can ([bash](tools.md#bash)).

So run Finn where a mistake costs little:

- in a container or a VM with only the project mounted;
- as a user that owns only the project;
- with the approvals on, and read each call before you allow it.

## Turn the approvals on

Any of these:

- `finn serve --approvals`, or `FINN_APPROVALS=1` in the server's environment;
- `"approvals": true` in `~/.config/finn/config.json`.

`FINN_APPROVALS=0` keeps them off over the file. A project's `.finn/config.json` cannot change them.

## What asks

With the approvals on, a call of these tools waits for your answer unless a rule or an earlier answer allows it: `write_file`, `edit_file`, `apply_patch`, `bash`, the MCP tools, and the tools of an [extension](extensions.md) that has `asks: true`.

`read_file`, `glob`, `grep`, `activate_skill` and `run_script` never ask. The calls that a `run_script` script makes are checked one by one, as direct calls.

A `bash` command that only reads inside the session folder runs without asking, but only while no deny rule of `read_file` or of `bash` exists, and only when each of its programs is found in a folder of `PATH` that only root can change (such as `/usr/bin`). A program found only in a folder of yours (`~/.cargo/bin`) makes the command ask.

When no client is attached for 90 seconds, a call that waits is denied. `finn -p` denies such calls unless you add `--yolo`, which allows the calls of its own turns.

## Answer

Both clients show the call: the tool, its path or command, and what it would write.

- `finn tui`: Ctrl+Y allows and Ctrl+N denies from the prompt. Tab moves to the approval panel, where `y` allows, `n` denies and `a` allows the same call for the rest of the session; Tab or Esc goes back to the prompt.
- `finn`: type `y`, `n` or `a` and Enter.

The [HTTP API](server.md#routes) takes two more answers:

- `allow_prefix` allows the `bash` commands that start with the same words: the first word, or the first two for programs such as `git`, `npm`, `cargo`, `make` or `docker` (`git log`). For a program that runs another one (`env`, `xargs`, `sudo`, `timeout`, a shell or an interpreter such as `python`), it allows only the same call.
- `allow_tool` allows every call of the tool.

While a deny rule of `read_file` exists, every answer for `bash` allows only the same call, since any command may read the file.

The accept-edits mode (`PATCH /v1/sessions/ID` with `{"accept_edits": true}`) runs the calls of `write_file`, `edit_file` and `apply_patch` without asking.

Answers and the accept-edits mode last until the server restarts. With the approvals on, a change under `.git/` always asks, even when an allow rule, an answer or accept-edits covers it, since git's config and hooks run programs. With the approvals off it runs.

## Rules

A rule is `tool(pattern)`, where `*` matches any text. For the file tools the pattern matches the path, for `bash` the command, and for an MCP tool its JSON input.

```json
{
  "allow": ["bash(npm test*)", "bash(git status*)", "mcp__fs__read_file(*)"],
  "deny": ["read_file(.env*)", "read_file(*.pem)", "bash(rm -rf *)"]
}
```

- **Deny rules count with the approvals on or off.** They are checked before the answers, but see the [known gap](#known-gap-allow-rules-and-bash) below.
- **Allow rules** let a call run without asking, with the approvals on.
- The rules come from your config file and from the project's `.finn/config.json` ([Configuration](config.md)). The project's deny rules always count; its allow rules count only under a [trusted folder](config.md#trusted-folders).
- A deny rule of `read_file` also denies `edit_file` and hides the file from `glob` and `grep`.

### Known gap: allow rules and bash

Until [#197](https://github.com/agentica-lang/agc-agent/issues/197) is fixed, an allow rule that matches a `bash` command skips the deny checks of `bash`, in both modes. With `deny: ["read_file(.env*)"]` and `allow: ["bash(cat *)"]`, `cat .env` runs. With `deny: ["bash(rm *)"]` and `allow: ["bash(sudo *)"]`, `sudo rm -rf x` runs. Do not write an allow rule for `bash` that covers a command a deny rule must stop.

## What rules cannot do

A rule is a convenience, not a sandbox.

- A deny rule of `bash` sees a command as far as Finn's parser of bash does. It matches each simple command of a line, also after `sudo`, `env` or `timeout 5`. While a deny rule of `bash` exists, a command whose words the parser cannot check (a quote, a `$`, a glob) is refused with the approvals off, and asks with them on, where no rule or answer lets it through.
- With the approvals off, a `read_file` deny rule refuses the `bash` commands that name the file, but it cannot see a name that bash builds as it runs: `cat $(printf .env)` still reads `.env`.
- Allowing a program allows all of its options and config: `bash(git status*)` allows `git -c core.fsmonitor=./x.sh status`, which runs `x.sh`. Allow only what is harmless with any argument.

Only a sandbox or a container keeps the model in.
