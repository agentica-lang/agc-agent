# Changelog

## [Unreleased]

- The repo skeleton: a workspace with the `llm` and `core` packages, and CI.
- The `sse` package: a Server-Sent Events parser and writer.
- The `protocol` package: the records of the commands and events between the server and its clients, with JSON codecs.
- The `llm` common API (messages, tools, a stream of events, usage, stop reasons, errors, retry) and its first provider, `openai_chat`.
- `make smoke-llama` (and the CI `llama` job) runs the `llm` tests against a real llama-server; `make live-fireworks` makes one real Fireworks call.
- The `openai_responses` provider (the OpenAI Responses format: reasoning items, custom tools and item ids sent back unchanged); llama.cpp for the smoke tests is now `b12426`.
