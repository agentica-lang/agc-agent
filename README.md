# Finn Agent

A coding agent for the terminal, like Claude Code or OpenCode, written in
[Agentica](https://github.com/agentica-lang/agentica).

- The agent runs as a server on localhost; clients connect to it over HTTP and
  Server-Sent Events: a full-screen client (`finn`) and a line-mode one (`finn chat`).
- The `llm` package is the client for LLM APIs: `openai_chat` and `openai_responses` (OpenAI, llama.cpp's
  `llama-server`, Fireworks and other compatible APIs) and `anthropic` (the Anthropic Messages API).
- Extensions are Agentica packages that your own `main.agc` registers, or MCP
  servers on stdio or streamable HTTP.

## Try it

Needs Agentica 0.35.0 or later (`agentica` on PATH, or `AGENTICA` set to it). Run `make install`, then use `bin/finn`
from any folder (link it into your PATH if you like):

```sh
bin/finn                               # the full screen in this folder; starts the server when none runs
bin/finn chat                          # the same as a line chat
bin/finn -p "fix the failing test"     # one task, then exit with its status
bin/finn login                         # set up a provider with its key
bin/finn --help
```

Tools run without asking by default: the model can run any command and change any file you can, except what a `deny`
rule refuses. Run Finn in a sandbox or a container, or turn the approvals on with `finn serve --approvals`.

## Docs

| Page | What |
|---|---|
| [Quickstart](docs/content/quickstart.md) | install, a provider, a first session |
| [CLI and TUI](docs/content/cli.md) | commands, options, slash and shell commands, keys, the server commands |
| [Providers](docs/content/providers.md) | APIs, presets, logins and keys |
| [Configuration](docs/content/config.md) | environment variables and config files |
| [Approvals and security](docs/content/security.md) | what asks, the rules, and what they cannot do |
| [Tools](docs/content/tools.md), [Sessions](docs/content/sessions.md), [Skills](docs/content/skills.md), [MCP](docs/content/mcp.md) | what the agent can use and keep |
| [Extensions](docs/content/extensions.md), [Server API](docs/content/server.md), [Architecture](docs/content/architecture.md) | building on Finn |

## Packages

The repo is an Agentica workspace (`agentica.toml`): one folder per package.

| Package | What |
|---|---|
| `sse` | Server-Sent Events: a parser and a writer |
| `llm` | client for LLM APIs |
| `protocol` | the records, events and JSON codecs between the server and its clients |
| `monty` | Python scripts in pydantic's Monty sandbox, through its `monty subprocess` worker |
| `bash` | the simple commands of a bash line, read by tree-sitter-bash (a native module) |
| `core` | the server: agent loop, tools, approval, sessions, extensions, code mode (`--no-codemode` turns it off) |
| `client` | what every client shares: finding or starting the server, the HTTP calls, the event reader |
| `cli` | the line-mode client: sends messages, prints the events, answers approvals, stops with Ctrl+C |
| `tui_client` | the full-screen client on [agentica-tui](https://github.com/agentica-lang/agentica-tui): markdown transcript, tool notices, approvals |
| `examples/extension` | how to extend Finn: a program that serves `core` with its own tool, a wrapper of every tool and a service (`Core.serve`) |

## Development

`make test` and `make smoke-llama` (the second fetches llama.cpp and a 0.5B model, about 500 MB, into `.tools/`). The
tests against a real model (`make smoke-llama` and the targets that call a paid API) run only on your machine, never in
CI.
