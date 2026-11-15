# openai_responses fixtures

Recorded from llama.cpp `llama-server` build `b12426` (the prebuilt
`ubuntu-x64` archive) at `POST /v1/responses`, started with
`--jinja -c 4096 -t 2` and `--alias`. Requests: `stream: true`,
`temperature: 0`, `seed: 1`.

| File | Model | Request |
|---|---|---|
| `text.sse` | Qwen2.5-0.5B-Instruct Q4_K_M | `instructions` "Answer in one short sentence.", user "Say hello.", `max_output_tokens` 32 |
| `tool_call.sse` | Qwen2.5-0.5B-Instruct Q4_K_M | the `read_file` function tool, `tool_choice: "required"`, user "Read the first 10 lines of README.md." |
| `parallel_tool_calls.sse` | Qwen2.5-0.5B-Instruct Q4_K_M | the `read_file` tool, `parallel_tool_calls: true`, `tool_choice: "required"`, instructions "Call read_file once for each file the user names, all in one answer.", user "Read README.md and also read AGENTS.md." |
| `reasoning.sse` | Qwen3-0.6B Q4_K_M | user "What is 2 + 3? Answer with the number.", `max_output_tokens` 200 |

Changed or written by hand, from the documented event shapes:

- `length.sse`: recorded with `max_output_tokens` 4, but llama-server ends a
  cut answer with `response.completed`; the last event is changed to
  `response.incomplete` with `incomplete_details.reason: "max_output_tokens"`,
  as OpenAI sends it.
- `stream_error.sse`: the first events of `text.sse`, then `response.failed`.
- `encrypted_reasoning.sse`: as OpenAI and Codex stream it: a reasoning item
  with a summary of two parts and `encrypted_content`, a message with `phase:
  "commentary"`, then a `function_call` in two pieces; usage with cached and
  reasoning tokens.
- `custom_tool_call.sse`: a freeform `custom_tool_call` (`apply_patch`) whose
  input comes in two pieces.
- `refusal.sse`: a message whose content is one `refusal` part, streamed by
  `response.refusal.delta`.
- `mixed_refusal.sse`: a message with no item id whose content is an
  `output_text` part, then a `refusal` part.

The 429 and 401 tests use the bodies in `../openai_chat/` (the same error
shape). Files here are compared byte for byte (`.gitattributes`: `-text`).
