# anthropic fixtures of core

- `text.sse`: the same as `llm/tests/fixtures/anthropic/text.sse`, recorded
  from llama-server `b12426`.
- `thinking_tool_use.sse`: the same as the file of that name in `llm`, written
  by hand: a `thinking` block with its signature, a `redacted_thinking` block,
  text, and a `read_file` call of `README.md`; usage with cache reads and
  writes.
- `text_large.sse`: `text.sse` with 500 input tokens, past the window of a
  compaction test.
- `models.json` and `unauthorized.json`: the same as the files of those names
  in `llm`.
