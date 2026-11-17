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

Every `bash` call asks unless an allow rule or an earlier answer allows it, even one that only reads.

When no client is attached for 90 seconds, a call that waits is denied. `finn -p` denies such calls unless you add `--yolo`, which allows the calls of its own turns.

## Answer

Both clients show the call: the tool, its path or command, and what it would write.

- `finn`: Ctrl+Y allows and Ctrl+N denies from the prompt. Tab moves to the approval panel, where `y` allows, `n` denies and `a` allows the same call for the rest of the session; Tab or Esc goes back to the prompt.
- `finn chat`: type `y`, `n` or `a` and Enter.

The [HTTP API](server.md#routes) takes two more answers:

- `allow_prefix` allows the plain `bash` commands that start with the same words: the first word, or the first two for programs such as `git`, `npm`, `cargo`, `make` or `docker` (`git log`). A plain command has no quotes, `$`, `;`, `|`, `&`, `>` or other character special to bash. For a command that is not plain, or a program that runs another one (`env`, `xargs`, `sudo`, `timeout`, a shell or an interpreter such as `python`), it allows only the same call.
- `allow_tool` allows every call of the tool.

The accept-edits mode (`PATCH /v1/sessions/ID` with `{"accept_edits": true}`) runs the calls of `write_file`, `edit_file` and `apply_patch` without asking.

Answers and the accept-edits mode last until the server restarts. With the approvals on, a change under `.git/` always asks, even when an allow rule, an answer or accept-edits covers it, since git's config and hooks run programs; only a deny rule refuses it instead. With the approvals off it runs.

## Rules

A rule is `tool(pattern)`, where `*` matches any text. In a `bash` rule, a `*` right after a letter matches only the end or a space and more: `git status*` matches `git status --short`, not `git statusx`. For the file tools the pattern matches the path, for `bash` the command, and for an MCP tool its JSON input.

```json
{
  "allow": ["bash(npm test*)", "bash(git status*)", "mcp__fs__read_file(*)"],
  "deny": ["read_file(.env*)", "read_file(*.pem)", "bash(rm -rf *)"]
}
```

- **Deny rules count with the approvals on or off.** They win over every allow rule and answer ([How rules check bash](#how-rules-check-bash)).
- **Allow rules** let a call run without asking, with the approvals on.
- The rules come from your config file and from the project's `.finn/config.json` ([Configuration](config.md)). The project's deny rules always count; its allow rules count only under a [trusted folder](config.md#trusted-folders).
- A deny rule of `read_file` also denies `edit_file`, and hides the file from `glob`, `grep` and the `@` completion of `finn`. The rules of `read_file`, `edit_file` and `write_file` apply to these file tools only: they do not stop a `bash` command from reading or writing the file (`cat .env` runs).

### How rules check bash

A `bash` rule matches the whole command text, best effort. `bash(rm *)` refuses `rm -rf x` but not `ls && rm x`, `sudo rm x` or `/bin/rm x`. An allow rule matches only a plain command, so `bash(git status*)` does not allow `git status; rm x`. A `!` command in the clients follows the same rules as a call of `bash`; it never asks, since you typed it.

## What rules cannot do

Rules are a convenience, not a sandbox. The rules of `read_file`, `edit_file` and `write_file` do not cover `bash`: `read_file(.env)` does not stop `cat .env`. A `bash` deny rule does not see a command written another way, and `bash(git *)` allows `git -c core.fsmonitor=./x.sh status`, which runs `x.sh`. Until the OS sandbox ([#213](https://github.com/agentica-lang/agc-agent/issues/213)) lands, run Finn in a sandbox or a container to keep the model in.
