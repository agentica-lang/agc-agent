---
title: Approvals and security
description: What Finn's model may do on your machine, the deny and allow rules, the approvals, and how to run Finn in a sandbox.
weight: 90
---

# Approvals and security

Finn's model runs commands and edits files as you. Know what it can reach before you point it at a folder.

## The default: no approvals

The approvals are off by default. The model runs any command and edits any file that no deny rule refuses, without asking. Its file tools reach any path you can, like `bash` ([Tools](tools.md#the-session-folder) says how to keep them in the session folder).

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

With the approvals on, a call of these tools waits for your answer unless a rule or an earlier answer allows it: `write_file`, `edit_file`, `apply_patch`, `bash`, `web_fetch`, the MCP tools, and the tools of an [extension](extensions.md) that has `asks: true`.

`read_file`, `glob`, `grep`, `todo_write`, `activate_skill` and `run_script` never ask, except for a path outside the session folder: a file tool that reaches there asks like `bash` does, with the approvals on and no rule for the folder (unlike a `bash` command, which runs): an allow rule of `external_directory(FOLDER/*)` covers the folder, and a deny rule refuses it. The folders of the skills the session can load are read without asking, and never written. The calls that a `run_script` script makes are checked one by one, as direct calls.

Every `bash` call asks unless an allow rule or an earlier answer allows each of its commands, even one that only reads. A read of a `.env` or `.env.*` file asks too, but `.env.example`, with the `read_file` tool or, best effort, with `cat .env` and the like; an `allow read_file(*)` rule turns that off.

When no client is attached for 90 seconds, a call that waits is denied. `finn -p` denies such calls unless you add `--yolo`, which allows the calls of its own turns.

`web_fetch` can send data out: its URL, headers and body go to any public host the model names, and what it fetches is untrusted text that may hold instructions aimed at the model (prompt injection); the compact form of a page is that text too, and it hides only what minibot's `html_compact` drops (`hidden`, `aria-hidden`, `display:none`, `visibility:hidden`), so text hidden in another way reaches the model. Only an approval or an operating system sandbox (planned, [#213](https://github.com/agentica-lang/agc-agent/issues/213)) keeps your data in: with the approvals off it runs without asking. With them on, the prompt shows the method, the URL, the headers and the body, an answer for the session covers that call only (the same method, URL, headers and body, so allowing a GET never allows a later POST), and a rule matches the URL whatever the method: `deny web_fetch(https://evil.example/*)` also denies a POST, and `allow web_fetch(https://docs.example.com/*)` allows every kind of call to that host. A rule sees the URL with the scheme and host in lower case, no trailing dot and no default port.

`web_fetch` reaches public addresses only, whatever the approvals say: it refuses a private, loopback, link-local or reserved address (a metadata endpoint such as 169.254.169.254 included), an IP written in any short or numeric form, `localhost`, user info and control characters in the URL, and it connects to the address it checked, so a DNS answer that changes cannot lead elsewhere ([how](tools.md#web_fetch)). When a name resolves to public and private addresses at once, Finn connects to the public ones only and never dials the private one. There is no setting that allows a private address.

## Answer

Both clients show the call: the tool, its path or command, and what it would write.

- `finn`: Ctrl+Y allows and Ctrl+N denies from the prompt. Tab moves to the approval panel, where `y` allows, `n` denies and `a` allows the same call for the rest of the session; Tab or Esc goes back to the prompt.
- `finn chat`: type `y`, `n` or `a` and Enter.

The [HTTP API](server.md#routes) takes two more answers:

- `allow_prefix` ("always") allows, for each command of the line, its name and ` *` (`ls *`) when the program is one of `echo`, `ls`, `pwd`, `sleep`, `which` and `df`. The request shows them. Any other program, a command with an assignment before its name (`FOO=1 rm x`), or a word with `$` or a substitution (`ls $(pwd)`), gets the same command only, and a later command of that kind is not allowed by a name and ` *`. A line with a `>` or `<` anywhere (`echo hi > f`, `{ echo hi; } > f`) is always asked exactly: each of its commands gets the same command only. For a line that tree-sitter-bash cannot read clearly, it allows the same call only.
- `allow_tool` allows every call of the tool.

The accept-edits mode (`PATCH /v1/sessions/ID` with `{"accept_edits": true}`) runs the calls of `write_file`, `edit_file` and `apply_patch` without asking, for paths in the session folder; a path outside it still asks.

Answers and the accept-edits mode last until the server restarts. A child's call asks on its parent's stream, with the child's id, and is answered there: the parent's session allows count for the child, but the accept-edits mode does not follow it. With the approvals on, a change under `.git/` or `.finn/` always asks, even when an allow rule, an answer or accept-edits covers it, since git's config and hooks run programs and `.finn/` holds the project's rules, skills, profiles and slash commands; only a deny rule refuses it instead. With the approvals off it runs.

## Rules

Finn's rules are [OpenCode's](https://opencode.ai/docs/permissions/), with Finn's tool names. A rule is `ACTION TOOL(PATTERN)`: the action `allow`, `ask` or `deny`, and `TOOL` alone means `TOOL(*)`. In the pattern and the tool, `*` matches any text and `?` one character; a pattern that ends in ` *` also matches without it, so `git *` matches `git`. `~` or `$HOME` at the start of a pattern is your home folder. For the file tools the pattern matches the path, for `bash` each command, for `web_fetch` the URL, and for an MCP tool its JSON input.

A rule matches the real path of a file, links followed: `~` or `$HOME` at the start of a pattern is the home folder (and its real path when that is a link). By default no tool reads or writes `auth.json`, `server.json`, `config.json` and `chatgpt.json` in Finn's own folders (the config folder, the state folder and the data folder, and the file of `FINN_CONFIG`; the key and token files, the server's address and its token), whatever the session folder: a session in `~/.config` is denied `finn/auth.json` too. A pattern of an absolute path also matches the files inside the session folder, which the tools name relative to it (`deny write_file(/*)` denies the writes there too; a `bash` or MCP rule never does). The last rule that matches wins, so an `allow` rule in your config file, which comes after, lets one through (`allow read_file(*)` lifts them all).

An [extension](extensions.md#prompts-and-events) that changes a call (`Core.Event.ToolBefore`) does so before the rules check it: the rules and the approval see the input that will run, and the call's result in the session file starts with the input that ran.

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
- A deny rule of `read_file` also denies `edit_file`, and hides the file from `glob`, `grep` and the `@` completion of `finn`. The rules of `read_file` also check, best effort, the files that `cat`, `head`, `tail`, `grep`, `wc`, `diff` and `cp` name in a `bash` command ([how](#how-rules-check-bash)). The rules of `edit_file` and `write_file` cover the file tools only.
- An old config with `"allow"` or `"deny"` stops the start, and the message lists its rules as `"allow X"` and `"deny X"` for `permission`.
- A rule with a space in its tool (`allow bash (git *)`) or a pattern over 256 characters is refused.

### How rules check bash

Finn reads a `bash` command with [tree-sitter-bash](https://github.com/tree-sitter/tree-sitter-bash) and checks each command of the line by its text: the parts of `;`, `&&`, `||`, `|`, a line end, `( )` and `$( )`. `deny bash(rm *)` refuses `ls && rm x` and `echo $(rm x)`. If any command is denied the call is denied, else if any asks the call asks. A rule matches the command's text as written, so `deny bash(rm *)` does not match `FOO=1 rm x` or `>log rm x`.

A command of `cd`, `rm`, `cp`, `mv`, `mkdir`, `touch`, `chmod`, `chown`, `cat`, `head`, `tail`, `grep`, `wc`, `diff` or `du` with a path outside the session folder also checks `external_directory(FOLDER/*)`, which runs unless a rule says otherwise: `"ask external_directory(*)"` asks for each such folder. A `cd` is checked only by its folder. OpenCode asks for such folders by default; Finn runs them. The `external_directory` rules govern the file tools too (see [What asks](#what-asks)). A path with `$` or a backtick is not followed, and a `cd` does not move the paths of the commands after it.

The files that `cat`, `head`, `tail`, `grep`, `wc`, `diff` and `cp` read also check `read_file(FILE)`: `cat .env` asks like the `read_file` tool, and `deny read_file(*.env)` denies it. Options and numbers are not files, nor the first word of `grep` (its pattern) unless `-e`, `-f` or `--` is there, nor the last argument of `cp` unless `-t` is there. This is best effort: a glob (`cat .en*`), `$`, `--opt=FILE`, a link, a folder read whole (`grep -r x .`) and other programs (`sed`, `awk`) are not seen. Under `ask *` a read such as `cat README.md` asks, since `read_file(*)` asks. "Always" on these programs allows the same command only.

A line that tree-sitter-bash cannot read, or one it is known to misread (such as nested backticks), asks even when an allow rule matches; a deny rule that matches the line or one of its commands still denies it. Where the parser is missing, every line is unclear: a clone with no C compiler, or a target that has no prebuilt library (a fetched `bash` has one for linux x86_64 and arm64, macos x86_64 and arm64, and windows x86_64).

A `!` command in the clients follows the same rules as a call of `bash`; it never asks, since you typed it.

## Credentials

Keys are stored in `auth.json` and the ChatGPT tokens in `chatgpt.json` in the state folder, each with mode 0600. Finn does not read either file when others may read it or another user owns it, nor `chatgpt.json` when it is a link, and the server says why. Keys and tokens never go to the log, the events, the session files or an error message. The worker of [code mode](tools.md#code-mode) runs with an empty environment, so it never sees them.

## What rules cannot do

Rules are a convenience, not a sandbox, and under `allow bash(*)` nothing stops a command from reading or writing any file you can. The file rules see only the files that a few `bash` programs name: `read_file(.env)` stops `cat .env` but not `sed -n p .env` or `cat .en*`. A `bash` deny rule matches the text, so it does not see a command written another way (`sudo rm x`, `/bin/rm x`, `"rm" x`, `sh -c 'rm x'`), and `bash(git *)` allows `git -c core.fsmonitor=./x.sh status`, which runs `x.sh`. Until the OS sandbox ([#213](https://github.com/agentica-lang/agc-agent/issues/213)) lands, run Finn in a sandbox or a container to keep the model in.
