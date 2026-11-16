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
| `client` | what every client shares: finding or starting the server, the HTTP calls, the event reader |
| `cli` | the line-mode client: sends messages, prints the events, answers approvals, stops with Ctrl+C |
| `tui_client` | the full-screen client on [agentica-tui](https://github.com/agentica-lang/agentica-tui): markdown transcript, tool notices, approvals |

## Try it

Needs Agentica 0.32.0 or later (`agentica` on PATH, or `AGENTICA` set to it). One command, `bin/finn`, from any
folder (link it into your PATH if you like):

```sh
bin/finn --help
bin/finn                               # chat in this folder; starts the server when none runs
bin/finn tui                           # the same on the full screen: Enter sends, Ctrl+J newline, Ctrl+T thinking, Shift+Tab level, Esc stops
# (the mouse answers panel keys, opens tool calls and thinking, and moves the prompt cursor; --yolo allows its own turns)
# in both: /new, /resume, /tree, /fork, /clone, /model, /thinking, /compact, /stop, /help, /quit
# in finn: !CMD runs CMD in the folder and the model gets its output with the next message; !!CMD does not give it
bin/finn -p "fix the failing test"    # one task, then exit with its status; approvals denied (--yolo allows its own turn)
bin/finn serve                         # the server in the foreground, on a llama-server at http://127.0.0.1:8080/v1
bin/finn serve --api openai_responses  # the same on /v1/responses
bin/finn serve --api anthropic         # Anthropic: ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN or `ant auth login`
FIREWORKS_API_KEY=... bin/finn serve  # a preset provider once its key is set: /model fireworks/MODEL in a session
bin/finn --version
```

`finn server status`, `stop` (waits for the running turns and ends when the server has gone; `--now` cancels them),
`restart`, `start` and `logs [-f]` manage the server a
client started in the background.

The flags of `finn serve` (`--api`, `--model`, `--base-url`) override their environment variables (`FINN_API`,
`FINN_MODEL`, `FINN_BASE_URL`); `finn serve --help` lists them all.

Development: `make test` and `make smoke-llama` (the second fetches llama.cpp and a 0.5B model, about 500 MB, into
`.tools/`). The tests against a real model (`make smoke-llama` and the targets that call a paid API) run only on your
machine, never in CI.
