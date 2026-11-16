# Changelog

## [Unreleased]

- The repo skeleton: a workspace with the `llm` and `core` packages, and CI.
- The `sse` package: a Server-Sent Events parser and writer.
- The `protocol` package: the records of the commands and events between the server and its clients, with JSON codecs.
- The `llm` common API (messages, tools, a stream of events, usage, stop reasons, errors, retry) and its first provider, `openai_chat`.
- The six base tools of `core` (`read_file`, `write_file`, `edit_file`, `glob`, `grep`, `bash`), the path rule, the approval rules and the bash environment.
- `protocol`: `decode_session` checks that `turn_id` and `turn_from_event_id` come together and agree with `last_event_id`; `StopReason.Other` is never a known name.
- `make smoke-llama` (and the CI `llama` job) runs the `llm` tests against a real llama-server; `make live-fireworks` makes one real Fireworks call.
- The `openai_responses` provider (the OpenAI Responses format: reasoning items, custom tools and item ids sent back unchanged); llama.cpp for the smoke tests is now `b12426`.
- The `cli` package: the line-mode client. It starts the server when none runs, prints the events of a session, answers approvals with y, n or a, and stops a turn with Ctrl+C.
- `core serve`: the agent loop (tool calls, approvals, stop, loop guard) behind the HTTP and SSE API on 127.0.0.1, with a Bearer token in `server.json`, `Host` and `Origin` checks, and every event of the running turn kept for a client that attaches mid-turn.
- `protocol`: `ServerInfo`, the record of `server.json`; `ApprovalRequested.detail`, the content a call would write.
- `read_file`: a line over 1 MiB in a file over 1 MiB keeps the lines before it and adds a note; a clamped `limit` adds the "continue with offset" note.
- `cli`: the state folder is resolved with its symlinks, and a symlink that is not yours is refused.
- `core serve` keeps each session in a JSON Lines file of the data folder (`AGC_AGENT_DATA_DIR`) and loads them all at start: a session resumes after a restart with its history and event ids, and a turn the restart cut ends as `cancelled`. The files are plain text (tool output and file contents included), keep every event and are all read at start; remove a session's file to delete it. When a file cannot be written, the turn stops with a `session.storage` error.
- `usage` events: `output` is the sum over the session (kept across a restart), and `context` is the prompt size of the call (input and cache counts, without the output).
- Compaction: past 80 % of the model's window (`AGC_AGENT_CONTEXT_WINDOW`, else llama-server's `/props`, else `GET /models`), the history between the first task and the running turn becomes a summary by `AGC_AGENT_COMPACT_MODEL` (else the session's model), saved in the session file; the system prompt and tools stay the same. The running turn is never compacted, the summary's tokens are not in `usage`, and a failed summary or an unknown window is an `error` event.
