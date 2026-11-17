---
title: Finn
description: Finn is a coding agent for the terminal, written in Agentica. It reads and edits your files, runs commands and talks to the model of your choice.
---

# Finn

Finn is a coding agent for the terminal, like Claude Code or OpenCode, written in [Agentica](https://github.com/agentica-lang/agentica). You give it a task in a folder; it reads files, edits them, runs commands and answers.

```sh
make install          # in a clone of agc-agent
bin/finn login        # set up a provider with its key
bin/finn tui          # chat on the full screen in this folder
```

[Quickstart](quickstart.md) · [Providers](providers.md) · [CLI and TUI](cli.md) · [Approvals and security](security.md)

## What Finn does

- **One server, several clients.** The agent runs as a server on localhost. The line-mode client (`finn`) and the full-screen client (`finn tui`) talk to it over HTTP and Server-Sent Events. A session goes on when a client closes.
- **Many model providers.** Anthropic, OpenAI, OpenRouter, Fireworks, Groq, DeepSeek, a local llama.cpp server, and any OpenAI-compatible API of your config file.
- **Tools.** Read, write and edit files, search them, and run bash commands. Code mode lets the model call the tools from a Python script in a sandbox.
- **Sessions you can go back in.** Resume a session, go back to an earlier message, fork or clone it. Long histories fold into a summary.
- **Skills and MCP.** `SKILL.md` folders and MCP servers add what the model can do.
- **Extensions.** An Agentica program can serve Finn with its own tools, wrappers and services.
- **Approvals when you want them.** Off by default; deny rules count either way, with a [known gap](security.md#known-gap-allow-rules-and-bash). See [Approvals and security](security.md).

## Before you start

Tools run without asking by default: the model can run any command and change any file that you can, except what a deny rule refuses. Run Finn in a sandbox or a container, or turn the approvals on with `finn serve --approvals`.
