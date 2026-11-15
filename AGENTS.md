# agc-agent

A coding agent written in Agentica: a server (`core`) and its clients. The plan
and its phases are issue #1 and its sub-issues.

## Map

```text
agentica.toml        the workspace: its members are the packages below
llm/                 client for LLM APIs; llm.agc is its public module, src/ the rest
core/                the server: agent loop, tools, approval, sessions, extensions;
                     main.agc is the entry point
<pkg>/tests/         *_test.agc unit tests of that package
Makefile             check, fmt-check, unit, smoke, test over every package
.github/workflows/   ci.yml: the pinned Agentica release, then fmt-check and test
```

Later phases add `sse`, `protocol`, `cli` and `tui_client`. A package is added
by the phase that needs it, never as an empty folder.

## Commands

- Binary: the release pinned in `.github/workflows/ci.yml`
  (`AGENTICA_VERSION`, with its sha256). Keep a local copy under `.tools/`
  (gitignored), never `/tmp`.
- `make test AGENTICA=...`: `check`, `unit` (`agentica test tests` in each
  package) and `smoke` (runs `core/main.agc`).
- `make fmt-check AGENTICA=...`: `agentica fmt --check` in each package.
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
- Tests are hermetic: localhost, port 0, no network, no keys. LLM APIs are
  faked by a local server that streams recorded fixtures. A real API call costs
  money: only through a `live` target, never in CI, and only with the owner's
  yes.
- Never commit a key or a token. Fixtures recorded from a real API have them
  removed.
- Prefer few end-to-end tests (a client against the server against a fake API)
  over many unit tests; unit tests for pure helpers (codecs, parsers).
- Changes that need the agentica, packages or agentica-tui repos are
  follow-up issues there, not work here.
- Every user-visible change adds a line under `## [Unreleased]` of
  `CHANGELOG.md`.
- The repo is private. Do not create other repos.
- A line that is only `end` is followed by an empty line, except before
  another `end`, `else`, `elsif`, a closing `)` or `]`, or the end of the file
  (`[style] blank_line_after_end`).
