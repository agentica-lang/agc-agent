# openai_chat fixtures of core

The fake LLM of the server tests streams these, in the order a test gives.

- `text.sse`: recorded from llama-server `b12012` with Qwen2.5-0.5B (the
  same as `llm/tests/fixtures/openai_chat/text.sse`): a short answer.
- The others are written by hand in the same shape: one tool call whose
  arguments come in two pieces, `finish_reason: "tool_calls"`, then the usage.
  `write_file.sse` writes `hello.txt`, `bash.sse` runs `cat hello.txt`,
  `bash_echo.sse` runs `echo other`, `slow_bash.sse` writes its pid to
  `pid.txt` and sleeps 30 s, `read_file.sse` reads a missing file, and
  `long_text_then_write.sse` streams 12 text pieces before a `write_file` call.
- `length_tool.sse` stops with `finish_reason: "length"` in the middle of a
  `write_file` call.
- `bash_echo_small.sse` is `bash_echo.sse` with 50 prompt tokens.
- `text_cached.sse` is `text.sse` with other usage: 150 prompt tokens, 120 of
  them cached, and 7 completion tokens.
- `summary.sse` is the summary a compaction asks for, and `models_small.json` a
  llama-server `GET /models` answer whose only model (`qwen`, not the model the
  tests name) has a window of 120 tokens.
- `props_small.json` is a llama-server `b12426` `GET /props` answer, cut down,
  with `n_ctx` 120. `summary_empty.sse` is a summary of blanks, and
  `summary_length.sse` one cut by `finish_reason: "length"`.
  `not_found.json` and `bad_request.json` are error bodies (404 and 400).
