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

A `bash` command that only reads inside the session folder runs without asking, but only while no deny rule of `read_file` or of `bash` exists, and only when each of its programs is found in `/usr/local/bin`, `/usr/bin` or `/bin` while only root can change that folder. The builtins of bash (`echo`, `pwd` and the like) need no folder. A program found only elsewhere (`~/.cargo/bin`) makes the command ask.

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

Answers and the accept-edits mode last until the server restarts. With the approvals on, a change under `.git/` always asks, even when an allow rule, an answer or accept-edits covers it, since git's config and hooks run programs; only a deny rule refuses it instead. With the approvals off it runs.

## Rules

A rule is `tool(pattern)`, where `*` matches any text. In a `bash` rule, a `*` right after a letter matches only the end or a space and more: `git status*` matches `git status --short`, not `git statusx`. For the file tools the pattern matches the path, for `bash` the command, and for an MCP tool its JSON input.

```json
{
  "allow": ["bash(npm test*)", "bash(git status*)", "mcp__fs__read_file(*)"],
  "deny": ["read_file(.env*)", "read_file(*.pem)", "bash(rm -rf *)"]
}
```

- **Deny rules count with the approvals on or off.** They win over every allow rule and answer ([How deny rules check bash](#how-deny-rules-check-bash)).
- **Allow rules** let a call run without asking, with the approvals on.
- The rules come from your config file and from the project's `.finn/config.json` ([Configuration](config.md)). The project's deny rules always count; its allow rules count only under a [trusted folder](config.md#trusted-folders).
- A deny rule of `read_file` also denies `edit_file`, and hides the file from `glob`, `grep` and the `@` completion of `finn tui`.

### How deny rules check bash

Finn reads each `bash` command with its parser of bash, without running it, and the deny rules give one of three answers:

- **Matched: refused**, with the approvals on or off, before any allow rule or answer. A `bash` rule matches a program the command runs: its first word, also by its name (`/bin/rm`, `./rm`), a word after a program that runs another one (`sudo`, `env`, `timeout 5`, `xargs`, `nice`, `then`, `do`), a command in `sh -c '...'` or after `eval`, or after `find -exec`. A `read_file` rule matches a word that names a file it hides: as written, after a `=` (`--file=.env`) or a `@` (`curl -d @.env`), after a one-letter option joined to it (`-Csecrets`), by its last name, or resolved against the session folder (`sub/../secrets/key`, an absolute path); a word that names the folder of a `dir/**` rule matches too (`grep -r KEY secrets`).
- **Not cleared: asks** with the approvals on and is **refused** with them off; no allow rule or answer lets it through. While a deny rule exists, that is a command the parser cannot check: it does not parse, is longer than 16 KB or nests `sh -c` or `eval` more than 8 deep, has a word that is not plain text (a quote, a `$`, a glob such as `.e*`), or runs a shell on a script file or its input (`... | sh`, `bash x.sh`) or an interpreter (`python`, `perl`, `node`, `source`). A `bash` rule that matches words which are not a program (`echo rm`, `git commit -m rm`) also leaves the command not cleared.
- **Clear:** the deny rules do not stop it.

A `!` command in the clients runs only when it is clear, with the approvals on or off.

## What rules cannot do

A rule is a convenience, not a sandbox. The deny rules see only what the command shows, so they cannot catch:

- a program made as the command runs (`ln -s /bin/rm r && ./r`);
- an interpreter or a shell running a file, beyond refusing it while a deny rule exists;
- a program that reads a whole folder (`grep -r KEY .`) or one it changed into (`cd secrets && cat key`);
- names that come from another program's output (`ls | xargs cat`);
- a link to a hidden file, or a path through a link to the session folder: the check reads no disk;
- an option that does what a rule names, since a rule names a program and not an effect (`find . -delete` under `bash(rm *)`);
- the options of a program in another order than a narrow rule's;
- a tool whose config runs programs: `bash(git *)` allows `git -c core.fsmonitor=./x.sh status`, which runs `x.sh`, and make or npm scripts run whatever they hold;
- a name in other case on a filesystem that ignores case (macOS): the rules match case.

Only a sandbox or a container keeps the model in.
