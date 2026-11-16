# agc-agent

A coding agent written in Agentica: a server (`core`) and its clients. The plan
and its phases are issue #1 and its sub-issues.

## Map

```text
agentica.toml        the workspace: its members are the packages below
sse/                 Server-Sent Events: parser and writer, pure; sse.agc is its public module
llm/                 client for LLM APIs; llm.agc is its public module, src/ the rest
protocol/            commands, replies and events between server and clients, with JSON codecs, pure;
                     protocol.agc is its public module
monty/               Python scripts in pydantic's Monty sandbox: the pinned `monty subprocess` worker (fetched
                     with its sha256), its protobuf codec, and a fake worker that replays recorded frames
                     (`serve_fake`); monty.agc is its public module; real/ the tests on the real worker
core/                the server: agent loop, tools, approval, sessions, extensions;
                     main.agc is the entry point
cli/                 the line-mode client: depends only on sse and protocol; main.agc is the entry point
<pkg>/tests/         *_test.agc tests of that package; fixtures/ the recorded data they read
llm/smoke/           tests against a real llama-server (make smoke-llama)
llm/live/            tests against a paid API (live-fireworks, smoke-anthropic): never in CI
scripts/             fetch the pinned llama.cpp release and model into .tools/ (sha256)
Makefile             check, fmt-check, unit, smoke, test over every package; smoke-llama, live-fireworks,
                     smoke-anthropic
.github/workflows/   ci.yml: the pinned Agentica release, then fmt-check and test; the llama job
```

Later phases add `tui_client`. A package is added
by the phase that needs it, never as an empty folder.

## Commands

- Binary: the release pinned in `.github/workflows/ci.yml`
  (`AGENTICA_VERSION`, with its sha256). Keep a local copy under `.tools/`
  (gitignored), never `/tmp`.
- `make test AGENTICA=...`: `check` (first `coupling`: the package rules
  below, with `rg`), `unit` (`agentica test tests` in each package; a package
  that passes no test fails) and `smoke` (runs `core/main.agc`).
- `cli` tests run the client as a child process on pipes (the Makefile
  exports `AGENTICA` for it) against a fake protocol server in
  `cli/tests/support/`. The client finds the server in the state folder
  (`--state-dir`, `FINN_STATE_DIR`, else `$XDG_STATE_HOME/finn`):
  `server.json` `{port, token, pid}`, and `server.lock` for the start. A
  server command that is started gets the folder in `FINN_STATE_DIR`;
  without `--server-command` (or words after `--`) and
  `FINN_SERVER_COMMAND` it is `core/main.agc serve` next to the client's
  own main file, never one of the current folder.
- `make fmt-check AGENTICA=...`: `agentica fmt --check` in each package.
- `make smoke-llama`: fetches llama.cpp and Qwen2.5-0.5B (pinned in
  `scripts/`, one tag and its sha256 to bump), then runs `llm/smoke` against a
  llama-server it starts on port 0 and stops; `LLAMA_URL` uses a running one.
  CI runs it in the `llama` job.
- `make smoke-monty`: the `monty` tests on the real worker (the pinned wheel
  from PyPI into `.tools/cache`, or `MONTY_BIN`). Record the fixtures again
  with `MONTY_RECORD=path/to/monty` set for `make unit`.
- `make live-fireworks`: one real call to Fireworks (`FIREWORKS_API_KEY`,
  `FIREWORKS_MODEL`); it skips without the key. It costs money: only with the
  owner's yes, never in CI.
- `make smoke-anthropic`: four calls to `claude-haiku-5-5` (text, a tool
  round, a cache read) with `ANTHROPIC_API_KEY`, else `ANTHROPIC_AUTH_TOKEN`,
  else the token of `ant auth login`; it skips without any. It costs money:
  only with the owner's yes, never in CI. The token is never printed.
- After a change of a package's dependencies: `agentica update` in that
  package's folder, and commit its `agentica.lock`.

## Rules

- Search with `rg`.
- Load the `agentica-programming` and `agentica-code-guidelines` skills of the
  Agentica repository before writing `.agc` code. Lines are at most 119
  characters; `agentica fmt --check` passes.
- Packages:
  - One folder per package, each with its own `agentica.toml`, listed in the
    root `[workspace]` `members` and in `PACKAGES` of the `Makefile`.
  - Names are Ruby style: short, lowercase, `snake_case`.
  - A package depends on another with a normal entry: `git` is this repo,
    `subdir` the folder, `tag` `NAME-VERSION`. The workspace reads it in place.
  - Keep them loosely coupled, so one can move to its own repo: `llm`, `sse`
    and `protocol` never depend on `core` or a client, and a package imports
    another only through its public module (`pkg/llm/llm`), never its `src/`.
    `make coupling` checks both. A client (`cli`, later `tui_client`) reaches
    the server only through `protocol` and `sse`: it never depends on `core` or
    `llm`.
  - Each package has one `VERSION` constant in its public module, equal to its
    tag (`llm-0.0.1` is `VERSION = "0.0.1"`). A release goes in this order: tag
    the dependency (`llm-X`), then a PR that bumps the dependent's entry and
    `agentica.lock`, then tag the dependent (`core-Y`).
- Tests are hermetic: localhost, port 0, no network, no keys. LLM APIs are
  faked by a local server that streams recorded fixtures. A real API call costs
  money: only through a `live` target, never in CI, and only with the owner's
  yes.
- Never commit a key or a token. Fixtures recorded from a real API have them
  removed.
- Tests: functional tests first (a client against the server against a fake
  API, or a provider against a fake API server), then unit tests, only for pure
  parts with many edge cases (codecs, parsers). Fixtures over factories: the
  recorded SSE and JSON go in `<pkg>/tests/fixtures/`. Few tests, high value.
  Every `.agc` test run shows how many tests passed, and a run that passes
  none fails.
- Changes that need the agentica, packages or agentica-tui repos are
  follow-up issues there, not work here.
- Every user-visible change adds a line under `## [Unreleased]` of
  `CHANGELOG.md`.
- The repo is private. Do not create other repos.
- A line that is only `end` is followed by an empty line, except before
  another `end`, `else`, `elsif`, a closing `)` or `]`, or the end of the file
  (`[style] blank_line_after_end`).
