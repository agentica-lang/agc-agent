# openai_chat fixtures of core

The fake LLM of the server tests streams these, in the order a test gives.

- `text.sse`: recorded from llama-server `b12012` with Qwen2.5-0.5B (the
  same as `llm/tests/fixtures/openai_chat/text.sse`): a short answer.
- The others are written by hand in the same shape: one tool call whose
  arguments come in two pieces, `finish_reason: "tool_calls"`, then the usage.
  `write_file.sse` writes `hello.txt`, `bash.sse` runs `cat hello.txt`,
  `slow_bash.sse` runs `sleep 30`, `read_file.sse` reads a missing file, and
  `long_text_then_write.sse` streams 12 text pieces before a `write_file` call.
