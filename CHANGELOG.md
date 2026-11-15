# Changelog

## [Unreleased]

- The repo skeleton: a workspace with the `llm` and `core` packages, and CI.
- The `sse` package: a Server-Sent Events parser and writer.
- The `protocol` package: the records of the commands and events between the server and its clients, with JSON codecs.
- The `llm` common API (messages, tools, a stream of events, usage, stop reasons, errors, retry) and its first provider, `openai_chat`.
- The six base tools of `core` (`read_file`, `write_file`, `edit_file`, `glob`, `grep`, `bash`), the path rule, the approval rules and the bash environment.
- `protocol`: `decode_session` checks that `turn_id` and `turn_from_event_id` come together and agree with `last_event_id`; `StopReason.Other` is never a known name.
