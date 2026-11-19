---
title: Server API and events
description: The HTTP API of Finn's server on localhost, its event stream over Server-Sent Events, and how a client finds the server.
weight: 110
---

# Server API and events

The clients of Finn talk to its server over HTTP on `127.0.0.1`. A program of your own can too: start a session, send it messages, read its events and answer its approvals. The `protocol` package of the repository has every record below with its JSON codec.

## Find the server

A running server writes `server.json` to its state folder (`~/.local/state/finn` by default), readable by you alone:

```json
{"port": 41234, "token": "...", "pid": 12345}
```

Every request sends `Authorization: Bearer TOKEN`. The server also refuses a `Host` that is not this machine, and an `Origin` other than its own, so a web page cannot call it.

```sh
state=~/.local/state/finn/server.json
port=$(jq .port "$state"); token=$(jq -r .token "$state")
curl -s -H "Authorization: Bearer $token" "http://127.0.0.1:$port/v1/sessions"
```

## Routes

| Method and path | What it does |
|---|---|
| `GET /v1/health` | the server answers, with its version (the UTC time of its commit, `YYYYMMDDhhmmss`, or `unknown`) and the digest of its protocol (`wire`) |
| `GET /v1/server` | the server's status: its pid, version and start time, how many sessions it has and how many turns run, whether it is stopping, and whether the approvals are on |
| `GET /v1/mcp[?session=ID]` | the MCP servers: `{"servers": [{"name", "scope", "transport", "target", "state", "error", "tools": [{"name", "description"}]}]}`; `scope` is `user` or, with `session`, `project` (the servers of that session's folder), `state` is `connecting`, `connected` or `failed`, and `target` is the program of a stdio server or the origin of an HTTP one, never its environment or headers |
| `POST /v1/mcp/NAME/reconnect[?session=ID]` | start that server again (its client stops, a new one starts and lists its tools); gives the same list with the one server; `404` (`mcp.not_found`) for a name that no server has, `409` (`mcp.starting`) while the servers are restarting after a reload |
| `POST /v1/reload` | read the config file, the MCP servers, the skills and the project instructions again ([`/reload`](config.md#reload)); gives `{"skills_added", "skills_removed", "config", "extensions", "sessions", "warnings", "rules", "approvals"}`; one reload runs at a time, and one that waits 150 s for another is refused with `409` `reload.busy` |
| `POST /v1/server/stop` | stop the server, as `finn server stop` does |
| `GET /v1/logs?lines=N` | the last N lines of the server log (default 50), the last 3 distinct warnings it logged since it started (a text that came again once, with `(×N)` after it), and how many distinct |
| `GET /v1/providers` | the providers and their models |
| `GET /v1/auth` | the logins: each provider, where its key comes from, and what a login asks for (`asks`: `key`, or `url` with the `base_url` of `local`) |
| `PUT /v1/auth` | make an empty key file when there is none, so the first-start login is not offered again |
| `POST /v1/auth/PROVIDER` | log in: `{"key": "..."}`, checked at the provider, then stored; `local` takes `{"base_url": "..."}`, checked with its `GET /models` |
| `DELETE /v1/auth/PROVIDER` | remove the stored key of a provider (the base URL of `local`, the tokens of `chatgpt`, which also ends a login that waits); `DELETE /v1/auth` removes all |
| `POST /v1/auth/chatgpt` | start the device login of a ChatGPT subscription: `{"user_code", "url", "expires_in"}`; the user opens `url` and types the code, and the server waits for that and stores the tokens in `chatgpt.json` of its state folder (0600) |
| `GET /v1/auth/chatgpt` | where that login is: `{"state", "message"}`, `state` being `none`, `waiting`, `done` or `failed` (`message` says why) |
| `POST /v1/sessions` | a new session: `{"cwd": "/path", "model": null}`, plus `provider`, `api` and `profile`; it answers its `id` and `profile` |
| `GET /v1/sessions` | the sessions, the last changed first; `empty` marks one with no message, compaction or output of a tool or command yet |
| `GET /v1/sessions/ID` | one session: its settings, history (the messages, and items with an empty `text` for what the turns did: `thinking` with its text, a `tool` call with its end in `done` (without its output and diff), or the `stop` of a turn that did not end as asked; while a turn runs, the history stops at its start, and the events from `turn_from_event_id` give the rest), the `usage` of its last model call, the model's `todos` and its `profile` (`name`, `source`: `built-in`, `user`, `project` or empty when it does not load, `description`, `warnings`) |
| `PATCH /v1/sessions/ID` | change `provider`, `model`, `effort` (the thinking level), `accept_edits`, `confine` or `profile` (with the model and thinking level it sets, unless the same request gives them; `409` while a turn, a command or a compaction runs) |
| `DELETE /v1/sessions/ID` | delete a session and its file |
| `POST /v1/sessions/ID/messages` | send `{"text": "..."}`; it starts a turn, or joins the running one |
| `GET /v1/sessions/ID/events` | the event stream of the session |
| `POST /v1/sessions/ID/approvals/AID` | answer an approval: `{"decision": "allow"}` |
| `POST /v1/sessions/ID/stop` | stop the running turn or command; `{"turn_id": "..."}` stops only that turn while it runs; answers `{"stopped": true}` or `false` |
| `POST /v1/sessions/ID/compact` | fold the history now |
| `GET /v1/sessions/ID/tree` | the user messages of every branch |
| `POST /v1/sessions/ID/branch` | go on from an earlier message |
| `POST /v1/sessions/ID/fork` | a new session from an earlier message |
| `GET /v1/sessions/ID/commands` | the session's slash commands: `{"commands": [{"name", "source", "description", "warnings"}]}`; one that does not load has an empty `source` |
| `GET /v1/sessions/ID/profiles` | the profiles the session may take: `{"profiles": [{"name", "source", "description", "warnings"}]}`; one that does not load has an empty `source` |
| `GET /v1/sessions/ID/files` | the files of the session folder that the deny rules do not hide, for the `@` completion: `{"files": [...], "truncated": false}`; `truncated` is true when the walk stopped at 5000 files, 2000 folders or about 2 s; with a [files command](config.md#the-files-command) they are the files of its output that the same rules let through, and `note` says why the walk listed them instead when it failed |
| `POST /v1/sessions/ID/shell` | run `{"command": "...", "context": true}` in the session folder |

A decision is `allow`, `deny`, `allow_session`, `allow_prefix` or `allow_tool` ([Answer](security.md#answer)).

A failed request answers with `{"kind": "...", "message": "..."}`. Branch on `kind`, a dotted name such as `session.busy`; the message is for people.

## Events

`GET /v1/sessions/ID/events` is a stream of Server-Sent Events. Each event has its kind as the SSE `event:`, its id as `id:`, and its JSON as `data:`. The stream has no heartbeat and stays quiet while the model thinks, so read it with no read timeout (with Agentica's `std/http`, `read_timeout_ms: 0`).

| Event | When |
|---|---|
| `turn_started` | a turn starts with a user message |
| `text_delta`, `thinking_delta` | a piece of the model's answer or thinking |
| `tool_started`, `tool_finished` | a tool call starts and ends, with its output and the diff of an edit |
| `approval_requested`, `approval_resolved` | a call waits for an answer, and gets one |
| `message_queued` | a message sent while the turn runs |
| `shell_started`, `shell_finished` | a command that a client ran in the session folder (`!CMD`) |
| `usage` | the tokens of a model call: `input`, `cache_read`, `cache_write` and `context` of that call, `output` summed over the session, `cost`, `turn_cost` and `session_cost` when the catalog has prices, `window`, the model's window in tokens, when it is known, `call_output`, the output of that call alone, and `output_ms`, the milliseconds from its first output to its end |
| `todos` | the model's whole todo list after a `todo_write` call: `{"todos": [{"content", "status"}]}` |
| `turn_finished` | the turn ended, with its stop reason |
| `error` | a failure, as `{"kind", "message"}` |
| `resync` | the stream cannot go on from where you asked: read the session again |

An event id counts from 1 in each session, and stays valid across a restart of the server. To go on after a lost connection, send the last id you read as `Last-Event-ID`: the stream repeats no event and misses none. An id that is unknown or too old gets `resync`; so does one that needs a text or thinking delta from before a restart, since those are not kept.

A reader should ignore a key it does not know: newer servers may add some.
