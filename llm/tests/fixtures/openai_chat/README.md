# openai_chat fixtures

Recorded from llama.cpp `llama-server` build `b12012` (the prebuilt
`ubuntu-x64` archive; the smoke tests now run `b12426`, and these recordings
were kept as they are), started with `--jinja -c 4096 -t 2` and `--alias` (so
`model` is the alias, not a local path). Requests: `stream: true`,
`stream_options.include_usage`, `temperature: 0`, `seed: 1`.

| File | Model | Request |
|---|---|---|
| `text.sse` | Qwen2.5-0.5B-Instruct Q4_K_M | system "Answer in one short sentence.", user "Say hello.", `max_tokens` 32 |
| `tool_call.sse` | Qwen2.5-0.5B-Instruct Q4_K_M | the `read_file` tool, `tool_choice: "required"`, user "Read the first 10 lines of README.md." |
| `length.sse` | Qwen2.5-0.5B-Instruct Q4_K_M | user "Count from one to twenty in words.", `max_tokens` 4 |
| `parallel_tool_calls.sse` | Qwen2.5-0.5B-Instruct Q4_K_M | the `read_file` tool, `parallel_tool_calls: true`, `tool_choice: "required"`, system "Call read_file once for each file the user names, all in one answer.", user "Read README.md and also read AGENTS.md." |
| `reasoning.sse` | Qwen3-0.6B Q4_K_M | user "What is 2 + 3? Answer with the number.", `max_tokens` 200 |
| `models.json` | Qwen2.5-0.5B-Instruct Q4_K_M | `GET /v1/models` |
| `unauthorized.json` | Qwen2.5-0.5B-Instruct Q4_K_M | the 401 body, server started with `--api-key` |

Models (sha256): Qwen2.5-0.5B-Instruct Q4_K_M
(`Qwen/Qwen2.5-0.5B-Instruct-GGUF`,
`74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db`);
Qwen3-0.6B Q4_K_M
(`7af3fdf842f87b24672f8a7f1dd50404043f0bfb71093ff91c31d2b49df4631d`).

Written by hand, since llama-server does not send them on demand:

- `rate_limited.json`: a 429 body in the OpenAI error shape.
- `stream_error.sse`: the first lines of `text.sse`, then an error object in
  the stream, as llama-server sends one when decoding fails.
- `tool_calls_no_index.sse`: two whole tool calls with no `index`, as some
  compatible APIs (Gemini's OpenAI layer) send them.
- `bad_arguments.sse`: a tool call whose arguments are not JSON.

Files here are compared byte for byte (`.gitattributes`: `-text`).
