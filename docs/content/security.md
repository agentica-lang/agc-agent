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

Every `bash` call asks unless an allow rule or an earlier answer allows each of its commands, even one that only reads. A read of a `.env` or `.env.*` file asks too, but `.env.example`; an `allow read_file(*)` rule turns that off.

When no client is attached for 90 seconds, a call that waits is denied. `finn -p` denies such calls unless you add `--yolo`, which allows the calls of its own turns.

## Answer

Both clients show the call: the tool, its path or command, and what it would write.

- `finn`: Ctrl+Y allows and Ctrl+N denies from the prompt. Tab moves to the approval panel, where `y` allows, `n` denies and `a` allows the same call for the rest of the session; Tab or Esc goes back to the prompt.
- `finn chat`: type `y`, `n` or `a` and Enter.

The [HTTP API](server.md#routes) takes two more answers:

- `allow_prefix` ("always") allows, for each command of the line, its name and ` *` (`ls *`) when the program is one of `cat`, `echo`, `grep`, `ls`, `ps`, `pwd`, `sleep`, `tail`, `head`, `wc`, `which`, `diff`, `du` and `df`. The request shows them. Any other program, a command with an assignment before its name (`FOO=1 rm x`), a redirection (`echo hi > f`), or a word with `$` or a substitution (`ls $(pwd)`), gets the same command only, and a later command of that kind is not allowed by a name and ` *`. For a line that tree-sitter-bash cannot read clearly, it allows the same call only.
- `allow_tool` allows every call of the tool.

The accept-edits mode (`PATCH /v1/sessions/ID` with `{"accept_edits": true}`) runs the calls of `write_file`, `edit_file` and `apply_patch` without asking.

Answers and the accept-edits mode last until the server restarts. With the approvals on, a change under `.git/` always asks, even when an allow rule, an answer or accept-edits covers it, since git's config and hooks run programs; only a deny rule refuses it instead. With the approvals off it runs.

## Rules

Finn's rules are [OpenCode's](https://opencode.ai/docs/permissions/), with Finn's tool names. A rule is `ACTION TOOL(PATTERN)`: the action `allow`, `ask` or `deny`, and `TOOL` alone means `TOOL(*)`. In the pattern and the tool, `*` matches any text and `?` one character; a pattern that ends in ` *` also matches without it, so `git *` matches `git`. `~` or `$HOME` at the start of a pattern is your home folder. For the file tools the pattern matches the path, for `bash` each command, and for an MCP tool its JSON input.

**The last rule that matches wins**, so put the broad rules first:

```json
{
  "permission": [
    "ask bash(*)",
    "allow bash(git *)",
    "allow bash(npm test *)",
    "deny bash(git push *)",
    "deny read_file(*.pem)",
    "allow mcp__fs__read_file(*)"
  ]
}
```

- Before your rules come the defaults: `ask read_file(*.env)`, `ask read_file(*.env.*)` and `allow read_file(*.env.example)`.
- When no rule matches, the tool's default holds: with the approvals on, the tools of [What asks](#what-asks) ask and the others run.
- **Deny rules count with the approvals on or off**, and no answer or mode allows what a rule denies. `ask` and `allow` rules count with the approvals on.
- With the approvals off, a call that would ask runs, an unclear `bash` line too: only the deny rules count.
- The rules come from your config file, then from the project's `.finn/config.json` ([Configuration](config.md)), whose rules come after yours. The project's `deny` rules always count; its `allow` and `ask` rules count only under a [trusted folder](config.md#trusted-folders).
- A deny rule of `read_file` also denies `edit_file`, and hides the file from `glob`, `grep` and the `@` completion of `finn`. The rules of `read_file`, `edit_file` and `write_file` apply to these file tools only: they do not stop a `bash` command from reading or writing the file (`cat .env` runs).
- An old config with `"allow"` or `"deny"` stops the start, and the message lists its rules as `"allow X"` and `"deny X"` for `permission`.
- A rule with a space in its tool (`allow bash (git *)`) or a pattern over 256 characters is refused.

### How rules check bash

Finn reads a `bash` command with [tree-sitter-bash](https://github.com/tree-sitter/tree-sitter-bash) and checks each command of the line by its text: the parts of `;`, `&&`, `||`, `|`, a line end, `( )` and `$( )`. `deny bash(rm *)` refuses `ls && rm x` and `echo $(rm x)`. If any command is denied the call is denied, else if any asks the call asks. A rule matches the command's text as written, so `deny bash(rm *)` does not match `FOO=1 rm x` or `>log rm x`.

A command of `cd`, `rm`, `cp`, `mv`, `mkdir`, `touch`, `chmod`, `chown` or `cat` with a path outside the session folder also checks `external_directory(FOLDER/*)`, which runs unless a rule says otherwise: `"ask external_directory(*)"` asks for each such folder. A `cd` is checked only by its folder. OpenCode asks for such folders by default; Finn runs them. A path with `$` or a backtick is not followed, and a `cd` does not move the paths of the commands after it.

A line that tree-sitter-bash cannot read, or one it is known to misread (such as nested backticks), asks even when an allow rule matches; a deny rule that matches the line or one of its commands still denies it. Without a C compiler the parser cannot be built, and every line is unclear.

A `!` command in the clients follows the same rules as a call of `bash`; it never asks, since you typed it.

## What rules cannot do

Rules are a convenience, not a sandbox. The rules of `read_file`, `edit_file` and `write_file` do not cover `bash`: `read_file(.env)` does not stop `cat .env`. "Always" on `git diff` allows `git diff *`, which allows `git diff --output=../x`, which writes outside the folder. A `bash` deny rule matches the text, so it does not see a command written another way (`sudo rm x`, `/bin/rm x`, `"rm" x`, `sh -c 'rm x'`), and `bash(git *)` allows `git -c core.fsmonitor=./x.sh status`, which runs `x.sh`. Until the OS sandbox ([#213](https://github.com/agentica-lang/agc-agent/issues/213)) lands, run Finn in a sandbox or a container to keep the model in.
