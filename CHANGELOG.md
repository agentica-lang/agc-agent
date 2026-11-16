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
- `core serve` keeps each session in a JSON Lines file of the data folder (`FINN_DATA_DIR`): a session resumes after a restart with its history and event ids, and a turn the restart cut ends as `cancelled`. The files are plain text (tool output and file contents included), keep the events and messages until the session is deleted. When a file cannot be written, the turn stops with a `session.storage` error.
- `usage` events: `output` is the sum over the session (kept across a restart), and `context` is the prompt size of the call (input and cache counts, without the output).
- Session files no longer keep text and thinking deltas; after a restart, a `Last-Event-ID` that would need one gets `resync`, and ids may skip.
- `core serve` lists the sessions from the first line of their files at start and loads a session on its first request; one that cannot be loaded now answers 503 `session.unavailable`.
- `DELETE /v1/sessions/ID` deletes a session and its file (`session.busy` while a turn runs); `finn --delete ID` does it from the cli.
- Compaction: past 80 % of the model's window (`FINN_CONTEXT_WINDOW`, else llama-server's `/props`, else `GET /models`), the history between the first task and the running turn becomes a summary by `FINN_COMPACT_MODEL` (else the session's model), saved in the session file; the system prompt and tools stay the same. The running turn is never compacted, the summary's tokens are not in `usage`, and a failed summary or an unknown window is an `error` event.
- `protocol`: `turn_started` and `turn_finished` carry `history_size`, the size of the session's history after the event. `cli`: after a resync, the client prints the part of the history it missed (the end of a turn a restart cut, a later turn), and says when the turn ended while the stream was away.
- `core serve` loads a session file in a task of its own: a big file no longer holds up the list, new sessions or other sessions while it loads.
- `core serve`: the 503 of a session that cannot load no longer shows the error behind it (a path, a crash); the server logs it.
- Compaction folds the older tool rounds of the running turn too, so the first turn or one long turn is compacted; the last round stays whole.
- Compaction stops for the rest of a turn when a fold leaves the context past the limit (an `error` event), instead of folding again every round.
- A turn that a restart cuts after a compaction keeps the text of its folded rounds in its answer.
- `core serve` speaks the OpenAI Responses format too: `FINN_API=openai_responses` (`openai`, chat completions, stays the default); it sends `store: false` and asks for the encrypted reasoning to replay it.
- `llm` `openai_responses`: with `store: false`, replayed items go back without their ids (the API refuses ids it did not keep).
- `bin/finn`: one command for everything, from any folder: `finn` (chat), `finn serve` (with `--api`, `--model`, `--base-url`), `finn --version`, `finn --help`.
- A session names its model API (`finn --api openai_responses`, `api` of `POST /v1/sessions`) and keeps it in its file; an older session uses the server's.
- Sessions made before the API choice keep no API in their file: one made with `FINN_API=openai_responses` follows the server's current default. `GET /v1/sessions` shows the API of each session.
- **Breaking:** the command is `finn` (`bin/finn`), the product Finn Agent: variables are `FINN_*` and folders `finn`; the `AGC_AGENT_*` names and an existing `agc-agent` folder still work.
- The approval of an `edit_file` call marks each old line `-` and each new line `+`.
- The `tui_client` package: a full-screen client on agentica-tui with a scrolling transcript of the streamed answer, a multiline prompt (Enter sends, Ctrl+J adds a line) and Esc to stop the turn.
