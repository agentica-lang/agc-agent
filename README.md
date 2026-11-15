# agc-agent

A coding agent for the terminal, like Claude Code or OpenCode, written in
[Agentica](https://github.com/agentica-lang/agentica).

- The agent runs as a server on localhost; clients connect to it over HTTP and
  Server-Sent Events. A line-mode client comes first, then a TUI.
- The `llm` package is the client for LLM APIs: one provider-neutral API with
  providers underneath. The first is `openai_chat` (llama.cpp's
  `llama-server`, Fireworks); Anthropic Messages, OpenAI Responses and Codex
  come later.
- Extensions are Agentica packages that your own `main.agc` registers, or MCP
  servers on stdio.

Nothing works yet. The plan and its phases are in issue #1.

## Packages

The repo is an Agentica workspace (`agentica.toml`): one folder per package.

| Package | What |
|---|---|
| `sse` | Server-Sent Events: a parser and a writer |
| `llm` | client for LLM APIs |
| `core` | the server: agent loop, tools, approval, sessions, extensions |

## Try it

Needs Agentica 0.32.0 or later.

```sh
agentica core/main.agc --version
make test
make smoke-llama   # fetches llama.cpp and a 0.5B model (about 500 MB) into .tools/
```
