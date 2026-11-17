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
| `GET /v1/health` | the server answers, with its version |
| `GET /v1/server` | the server's status: its pid, version and start time, how many sessions it has and how many turns run, whether it is stopping, and whether the approvals are on |
| `POST /v1/server/stop` | stop the server, as `finn server stop` does |
| `GET /v1/providers` | the providers and their models |
| `GET /v1/auth` | the logins: each provider, where its key comes from, and what a login asks for (`asks`: `key`, or `url` with the `base_url` of `local`) |
| `PUT /v1/auth` | make an empty key file when there is none, so the first-start login is not offered again |
| `POST /v1/auth/PROVIDER` | log in: `{"key": "..."}`, checked at the provider, then stored; `local` takes `{"base_url": "..."}`, checked with its `GET /models` |
| `DELETE /v1/auth/PROVIDER` | remove the stored key of a provider (the base URL of `local`); `DELETE /v1/auth` removes all |
| `POST /v1/sessions` | a new session: `{"cwd": "/path", "model": null}`, plus `provider` and `api` |
| `GET /v1/sessions` | the sessions, the last changed first |
| `GET /v1/sessions/ID` | one session: its settings, history and the `usage` of its last model call |
| `PATCH /v1/sessions/ID` | change `provider`, `model`, `effort` (the thinking level) or `accept_edits` |
| `DELETE /v1/sessions/ID` | delete a session and its file |
| `POST /v1/sessions/ID/messages` | send `{"text": "..."}`; it starts a turn, or joins the running one |
| `GET /v1/sessions/ID/events` | the event stream of the session |
| `POST /v1/sessions/ID/approvals/AID` | answer an approval: `{"decision": "allow"}` |
| `POST /v1/sessions/ID/stop` | stop the running turn or command; `{"turn_id": "..."}` stops only that turn while it runs; answers `{"stopped": true}` or `false` |
| `POST /v1/sessions/ID/compact` | fold the history now |
| `GET /v1/sessions/ID/tree` | the user messages of every branch |
| `POST /v1/sessions/ID/branch` | go on from an earlier message |
| `POST /v1/sessions/ID/fork` | a new session from an earlier message |
| `GET /v1/sessions/ID/files` | the files of the session folder that the deny rules do not hide, for the `@` completion: `{"files": [...], "truncated": false}`; `truncated` is true when the walk stopped at 5000 files, 2000 folders or about 2 s |
| `POST /v1/sessions/ID/shell` | run `{"command": "...", "context": true}` in the session folder |

A decision is `allow`, `deny`, `allow_session`, `allow_prefix` or `allow_tool` ([Answer](security.md#answer)).

A failed request answers with `{"kind": "...", "message": "..."}`. Branch on `kind`, a dotted name such as `session.busy`; the message is for people.

## Events

`GET /v1/sessions/ID/events` is a stream of Server-Sent Events. Each event has its kind as the SSE `event:`, its id as `id:`, and its JSON as `data:`.

| Event | When |
|---|---|
| `turn_started` | a turn starts with a user message |
| `text_delta`, `thinking_delta` | a piece of the model's answer or thinking |
| `tool_started`, `tool_finished` | a tool call starts and ends, with its output and the diff of an edit |
| `approval_requested`, `approval_resolved` | a call waits for an answer, and gets one |
| `message_queued` | a message sent while the turn runs |
| `shell_started`, `shell_finished` | a command that a client ran in the session folder (`!CMD`) |
| `usage` | the tokens of a model call: `input`, `cache_read`, `cache_write` and `context` of that call, `output` summed over the session, `cost`, `turn_cost` and `session_cost` when the catalog has prices, `window`, the model's window in tokens, when it is known, and `call_output`, the output of that call alone |
| `turn_finished` | the turn ended, with its stop reason |
| `error` | a failure, as `{"kind", "message"}` |
| `resync` | the stream cannot go on from where you asked: read the session again |

An event id counts from 1 in each session, and stays valid across a restart of the server. To go on after a lost connection, send the last id you read as `Last-Event-ID`: the stream repeats no event and misses none. An id that is unknown or too old gets `resync`; so does one that needs a text or thinking delta from before a restart, since those are not kept.

A reader should ignore a key it does not know: newer servers may add some.
