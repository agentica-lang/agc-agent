# Finn Agent

A coding agent for the terminal, like Claude Code or OpenCode, written in
[Agentica](https://github.com/agentica-lang/agentica).

- The agent runs as a server on localhost; clients connect to it over HTTP and
  Server-Sent Events. A line-mode client comes first, then a TUI.
- The `llm` package is the client for LLM APIs: one provider-neutral API with
  providers underneath: `openai_chat` and `openai_responses` (OpenAI, llama.cpp's
  `llama-server`, Fireworks and other compatible APIs) and `anthropic` (the
  Anthropic Messages API); Codex comes later.
- Extensions are Agentica packages that your own `main.agc` registers, or MCP
  servers on stdio.

Nothing works yet. The plan and its phases are in issue #1.

## Packages

The repo is an Agentica workspace (`agentica.toml`): one folder per package.

| Package | What |
|---|---|
| `sse` | Server-Sent Events: a parser and a writer |
| `llm` | client for LLM APIs |
| `protocol` | the records, events and JSON codecs between the server and its clients |
| `monty` | Python scripts in pydantic's Monty sandbox, through its `monty subprocess` worker |
| `core` | the server: agent loop, tools, approval, sessions, extensions, code mode (`FINN_CODE_MODE=1`) |
| `cli` | the line-mode client: sends messages, prints the events, answers approvals, stops with Ctrl+C |

## Try it

Needs Agentica 0.32.0 or later (`agentica` on PATH, or `AGENTICA` set to it). One command, `bin/finn`, from any
folder (link it into your PATH if you like):

```sh
bin/finn --help
bin/finn                               # chat in this folder; starts the server when none runs
bin/finn -p "fix the failing test"    # one task, then exit with its status; approvals denied (--yolo allows all)
bin/finn serve                         # the server in the foreground, on a llama-server at http://127.0.0.1:8080/v1
bin/finn serve --api openai_responses  # the same on /v1/responses
bin/finn serve --api anthropic         # Anthropic: ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN or `ant auth login`
bin/finn --version
```

The flags of `finn serve` (`--api`, `--model`, `--base-url`) override their environment variables (`FINN_API`,
`FINN_MODEL`, `FINN_BASE_URL`); `finn serve --help` lists them all.

Development: `make test` and `make smoke-llama` (the second fetches llama.cpp and a 0.5B model, about 500 MB, into
`.tools/`).
