# agc-agent

A coding agent written in Agentica: a server (`core`) and its clients. The plan
and its phases are issue #1 and its sub-issues.

## Map

```text
agentica.toml        the workspace: its members are the packages below
sse/                 Server-Sent Events: parser and writer, pure; sse.agc is its public module
llm/                 client for LLM APIs; llm.agc is its public module, src/ the rest
mcp/                 client for MCP servers on stdio or streamable HTTP; mcp.agc is its public module;
                     tests/fixtures/http_peer.py the HTTP server it is tested against (Python standard library)
protocol/            commands, replies and events between server and clients, with JSON codecs, pure;
                     protocol.agc is its public module
monty/               Python scripts in pydantic's Monty sandbox: the pinned `monty subprocess` worker (fetched
                     with its sha256), its protobuf codec, and a fake worker that replays recorded frames
                     (`serve_fake`); monty.agc is its public module; real/ the tests on the real worker
bash/                the simple commands of a bash line, read by tree-sitter-bash; native/ holds the vendored C
                     (runtime/, grammar/, MIT) and the module, whose header native-gen makes (`make native-header`);
                     bash.agc is its public module; tests/test_bash_peer.py checks it against real bash
core/                the server: agent loop, tools, approval, sessions, extensions;
                     main.agc is the entry point, core.agc the public module (`Core.serve` with a registry
                     of extensions)
core/src/            one folder per domain: config/ (settings, CLI, the extension registry), http/ (the routes),
                     session/ (the registry of sessions; one session's actor, which calls turn.agc, stream.agc (the
                     event fan-out) and branch.agc, with its state in state.agc; store.agc, the records of a session
                     file, which reach the files only through the port of storage.agc (`disk`, or `memory` for tests);
                     the prompt; builtins.agc: the skills, MCP and the approval on the extension registry), agent/ (the
                     loop, compaction), providers/ (the presets and the user's providers, what a server offers, the
                     stored keys and logins, the model catalog), tools/ (the tools and their sandbox), ext/ (MCP,
                     skills), approval/ (the approval extension: rules, session allows); core/tests stay flat
client/              what every client shares: finding or starting the server, the HTTP calls and `Backend` (them
                     as a record of functions; a test fills its own), the event reader, the session rules of
                     both clients; client.agc is its public module
cli/                 the line-mode client: depends only on client and protocol; main.agc is the entry point
tui_client/          the TUI client on agentica-tui (pinned commit): client, protocol and tui; main.agc is the
                     entry point; app.agc routes each message to a file per feature (state.agc holds the
                     model); tests/test_pty.py runs it under a pty against core and a fake model
examples/extension/  how to extend Finn: a program that serves core with a tool and a wrapper; core's
                     tests/extension_test.agc runs it
docs/                the user guide (Hugo, the docs theme as a submodule in docs/themes/docs-theme):
                     hugo.toml, content/ one page per topic
<pkg>/tests/         *_test.agc tests of that package; fixtures/ the recorded data they read
llm/smoke/           tests against a real llama-server (make smoke-llama): local only, never in CI
llm/live/, core/live/ tests against a paid API (live-fireworks, smoke-anthropic, live-anthropic-core): never in CI
scripts/             fetch the pinned llama.cpp release and model into .tools/ (sha256)
Makefile             check, fmt-check, unit, smoke, test over every package; smoke-llama, live-fireworks,
                     smoke-anthropic, live-anthropic-core
.github/workflows/   ci.yml, on GitHub-hosted ubuntu-24.04: the pinned Agentica release, the cached packages and compile
                     caches (`_build/`), then fmt-check and test (no real-model job)
```

A package is added by the phase that needs it, never as an empty folder.

## Commands

- Binary: the release pinned in `.github/workflows/ci.yml`
  (`AGENTICA_VERSION`, with its sha256). Keep a local copy under `.tools/`
  (gitignored), never `/tmp`.
- `make test AGENTICA=...`: `check` (first `coupling`: the package rules
  below, with `rg`), `unit` (`agentica test tests` in each package; a package
  that passes no test fails), `smoke` (runs `core/main.agc`), `pty`
  (`tui_client/tests/run_pty.py`: one process per test of `test_pty.py`, the
  client and the core compiled once) and `peer`
  (`bash/tests/test_bash_peer.py`), both Python standard library only.
  `native-check` fails when `bash/native/bash_native.h` is stale (native-gen,
  cloned into `.tools/`). `install` fetches bond into `core/deps/` and
  agentica-tui into `tui_client/deps/` (gitignored); `check`, `smoke` and `pty`
  run it first.
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
  Tests against a real model (llama, and `core/live`) run only on a developer's
  machine, never in CI.
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
- `make live-anthropic-core`: a core session on `claude-haiku-5-5` (three
  calls: a tool round, then a second turn that must read the cache), with the
  same credentials and rules as `smoke-anthropic`.
- After a change of a package's dependencies: `agentica update` in that
  package's folder, and commit its `agentica.lock`.
- `make docs`: builds the user guide into `docs/public` (Hugo 0.167 or later,
  Dart Sass, Node; `git submodule update --init docs/themes/docs-theme` first);
  a Hugo warning, such as a link to no page, fails it. CI runs it in the `docs`
  job. `make docs-serve` serves it while you write.

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
  - Keep them loosely coupled, so one can move to its own repo: `llm`, `mcp`,
    `sse` and `protocol` never depend on `core` or a client, and a package imports
    another only through its public module (`pkg/llm/llm`), never its `src/`.
    `make coupling` checks both. A client (`cli`, `tui_client`) reaches
    the server only through `client`, `protocol` and `sse`: it never depends
    on `core`, `llm` or another client.
  - Inside `core/src`, a folder imports only these others (`make coupling`
    checks them): `tools` and `providers` import no other, `approval` and
    `ext` import `tools`; `agent` imports `tools`, `approval` and
    `providers`; `config` imports `tools`, `approval` and `providers`;
    `session` imports `agent`, `tools`, `ext`, `approval`, `config` and
    `providers`; `http` imports `session`, `config` and `providers`, and of
    `session` only `session/session`. No folder imports `http`. Inside
    `session`, only the actor's files (`actor`, `turn`, `stream`, `branch`,
    `state`) import `turn`, `stream`, `branch` and `state`. An import never
    has a `..` after its first folder.
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
- Fast tests: `make test` stays near a minute and no test file passes 5 s
  (`agentica test --timing`). Order of preference: a unit or functional test
  with fixtures, an app test on the fake terminal of `TUI.Testing` (`tui_client/tests/terminal_test.agc`), or on the
  model with a fake `Client.Backend` (`app_test.agc`),
  then a child process on pipes (`cli`), and a pty only for what the terminal
  does (raw mode, resize, mouse, paste, drawing, signals). No `Task.sleep` or
  `time.sleep` to wait for something: wait on the event (a channel the test
  closes, `HTTP.wait`, a line of output; the fake model holds a reply with
  `name@hold` and `H.release`). A timeout that a test needs shorter is an
  option of the code (`catalog_wait_ms`). A sleep that is the behavior under
  test (a timeout, a guard time) is as short as it can be, and a slow test
  says why in a comment.
- Changes that need the agentica, packages or agentica-tui repos are
  follow-up issues there, not work here.
- Every user-visible change adds a line under `## [Unreleased]` of
  `CHANGELOG.md`.
- A user-visible change updates its page of the user guide in
  `docs/content/` (`make docs` builds it). A page keeps one line per paragraph
  or list item, as the other sites of the docs theme do; a link to another
  page names its file (`[Tools](tools.md)`).
- The repo is private. Do not create other repos.
- A line that is only `end` is followed by an empty line, except before
  another `end`, `else`, `elsif`, a closing `)` or `]`, or the end of the file
  (`[style] blank_line_after_end`).
