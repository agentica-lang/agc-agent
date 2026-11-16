# anthropic fixtures

Recorded from llama.cpp `llama-server` build `b12426` at `POST /v1/messages`,
with Qwen2.5-0.5B-Instruct Q4_K_M, `--jinja -c 4096 -t 2 --alias qwen`, and
`stream: true`, `temperature: 0`:

| File | Request |
|---|---|
| `text.sse` | system "Be short.", user "Say hello.", `max_tokens` 20 |
| `tool_call.sse` | the `read_file` tool, `tool_choice: {"type": "any"}`, user "Read the first 10 lines of README.md." |

Written by hand, from the documented shapes of the Anthropic API:

- `thinking_tool_use.sse`: a `thinking` block with its `signature_delta` in
  two pieces, a `ping`, a `redacted_thinking` block, text, then a `tool_use`
  block whose input comes in pieces; usage with cache reads and writes.
- `stop_refusal.sse`, `stop_pause_turn.sse`, `stop_max_tokens.sse`: a message
  with no content that stops for that reason.
- `empty_input.sse`: a `tool_use` block with no input pieces.
- `no_message_stop.sse`: `text.sse` without its `message_stop`.
- `stream_error.sse`: the first events of a message, then an `error` event
  (`overloaded_error`).
- `models.json`, `unauthorized.json` (401), `overloaded.json` (529): bodies
  of `GET /v1/models` and of errors.

Files here are compared byte for byte (`.gitattributes`: `-text`).
