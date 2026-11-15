# Changelog

## [Unreleased]

- The repo skeleton: a workspace with the `llm` and `core` packages, and CI.
- The `sse` package: a Server-Sent Events parser and writer.
- The `protocol` package: the records of the commands and events between the server and its clients, with JSON codecs.
- The `llm` common API (messages, tools, a stream of events, usage, stop reasons, errors, retry) and its first provider, `openai_chat`.
