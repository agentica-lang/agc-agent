---
title: Quickstart
description: Install Finn, set up a provider, and run a first session in the line-mode client, the TUI or as one task.
weight: 10
---

# Quickstart

## Install

Finn runs on [Agentica](https://github.com/agentica-lang/agentica) 0.34.0 or later: `agentica` on your `PATH`, or `AGENTICA` set to the binary.

1. Clone the repository: `git clone https://github.com/agentica-lang/agc-agent`. Use a git clone, not an archive of the source: the parser of the `bash` package is a submodule, and a `bash` fetched as a package never builds from source (it uses a prebuilt library where its manifest names one).
2. In the clone, run `make install`. It fetches the packages that the server and the TUI depend on, and the submodule.
3. Use `bin/finn` from any folder, or link it into your `PATH`: `ln -s "$PWD/bin/finn" ~/.local/bin/finn`.

`finn --version` prints the versions of the server and the client: the UTC time of the commit, as `20261118123456` ([Versions](cli.md#versions)).

## Set up a provider

Out of the box, Finn talks to a llama.cpp `llama-server` at `http://127.0.0.1:8080/v1`. For any other provider, give it a key:

```sh
finn login              # pick a provider, then paste its key
finn login anthropic    # or name the provider
```

Finn checks the key with one call to the provider, then stores it for the next starts. A key in the environment works too, and wins over a stored one: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `FIREWORKS_API_KEY`, `GROQ_API_KEY`, `DEEPSEEK_API_KEY` or `OPENCODE_API_KEY`. See [Providers](providers.md).

On the first start, `finn` opens the login list itself when there is no key file, no key of a provider in the environment, and none of `FINN_BASE_URL`, `FINN_PROVIDER` and `FINN_API` is set. Close it with no key and it is not offered again: `/login` sets up a provider later. After a login, a session on `local` gets the models of the provider just set up in a list: Enter moves the session to the one picked, from the next turn, and Esc keeps it on `local`.

## The first session

Go to the folder of your project and start a client:

```sh
cd ~/src/my-project
finn            # the full screen (finn tui is the same)
finn chat       # or the line-mode client
```

The client starts the server when none runs, and leaves it running when you quit. Type a task and press Enter. The model answers, and shows each tool call it makes: the files it reads and edits, the commands it runs.

Some things to try:

- `/model` lists the models of your providers; `/model anthropic/NAME` picks one.
- `@` then part of a name completes a file path of the folder in your message (`finn`).
- `!git status` runs the command and gives its output to the model with your next message.
- `/resume` lists your sessions and switches to one.
- Esc (`finn`) or Ctrl+C (`finn chat`) stops the running turn ([Stop](cli.md#stop)).

The rest is on [CLI and TUI](cli.md).

## One task, then exit

```sh
finn -p "fix the failing test"
echo "explain this repo" | finn -p -
```

The answer goes to stdout and the rest to stderr ([One task](cli.md#one-task)).

## Before you trust it with a folder

The approvals are off by default: the model runs commands and edits files without asking. Run Finn in a sandbox or a container, or turn the approvals on ([Approvals and security](security.md)).
