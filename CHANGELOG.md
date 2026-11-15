# Changelog

## [Unreleased]

- The repo skeleton: a workspace with the `llm` and `core` packages, and CI.
- The `sse` package: a Server-Sent Events parser and writer.
- The `llm` common API (messages, tools, a stream of events, usage, stop reasons, errors, retry) and its first provider, `openai_chat`.
- `make smoke-llama` (and the CI `llama` job) runs the `llm` tests against a real llama-server; `make live-fireworks` makes one real Fireworks call.
