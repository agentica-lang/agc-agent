---
title: Approvals and security
description: What Finn's model may do on your machine, the deny and allow rules, the approvals, and how to run Finn in a sandbox.
weight: 90
---

# Approvals and security

Finn's model runs commands and edits files as you. Know what it can reach
before you point it at a folder.

## The default: no approvals

The approvals are off by default. The model runs any command and edits any
file that no deny rule refuses, without asking. Its file tools stay in the
session folder, but `bash` can do whatever you can.

So run Finn where a mistake costs little:

- in a container or a VM with only the project mounted;
- as a user that owns only the project;
- with the approvals on, and read each call before you allow it.

## Turn the approvals on

Any of these:

- `finn serve --approvals`, or `FINN_APPROVALS=1` in the server's environment;
- `"approvals": true` in `~/.config/finn/config.json`.

`FINN_APPROVALS=0` keeps them off over the file. A project's
`.finn/config.json` cannot change them.

With the approvals on, a call that no rule allows waits for your answer in the
client. You can allow it once, deny it, or allow for the rest of the session:

- the same call;
- the same `bash` command prefix (`git log`, `npm test`);
- the whole tool.

These answers last until the server restarts. None of them reaches into
`.git/`. A `bash` command that only reads inside the session folder runs
without asking.

When no client is attached for 90 seconds, a call that waits is denied.
`finn -p` denies such calls unless you add `--yolo`, which allows the calls of
its own turns.

## Rules

A rule is `tool(pattern)`, where `*` matches any text. For the file tools the
pattern matches the path, for `bash` the command, and for an MCP tool its JSON
input.

```json
{
  "allow": ["bash(npm test*)", "bash(git status*)", "mcp__fs__read_file(*)"],
  "deny": ["read_file(.env*)", "read_file(*.pem)", "bash(rm -rf *)"]
}
```

- **Deny rules always count**, with the approvals on or off, and they are
  checked first.
- **Allow rules** count only with the approvals on.
- The rules come from your config file and from the project's
  `.finn/config.json`. The project's deny rules always count; its allow rules
  count only under a folder of `FINN_TRUSTED_DIRS`.
- A deny rule of `read_file` also denies `edit_file` and hides the file from
  `glob` and `grep`.
- A change under `.git/` always asks, since git's config and hooks run
  programs. Only a deny rule changes that.

## What rules cannot do

A rule is a convenience, not a sandbox.

- A deny rule of `bash` is best effort: it sees a command as far as Finn's
  parser of bash does. A command it cannot check (a quote, a `$`, a glob) is
  refused while a deny rule of `bash` exists.
- With the approvals off, a `read_file` deny rule refuses the `bash` commands
  that name the file, but it cannot see a name that bash builds as it runs:
  `cat $(printf .env)` still reads `.env`.
- Allowing a program allows all of its options: `bash(git *)` allows
  `git -c alias.x=!cmd x`, which runs `cmd`. Allow only what is harmless with
  any argument.
- `bash` gets few environment variables, but the server's environment is in
  `/proc/$PPID/environ`, readable by a process of the same user.

Only a sandbox or a container keeps the model in.

## Your keys

- Stored keys are in `~/.config/finn/auth.json`, readable by you alone; Finn
  refuses a file that others may read.
- A key is never logged.
- Session files hold tool output and file contents in plain text, in a folder
  only you can open. Delete a session with `finn --delete ID`.
