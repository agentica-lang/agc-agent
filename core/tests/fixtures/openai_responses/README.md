# openai_responses fixtures of core

- `text.sse`: the same as `llm/tests/fixtures/openai_responses/text.sse`, recorded from llama-server `b12426`.
- `write_file.sse`: written by hand in the shape of `encrypted_reasoning.sse` of `llm`: a reasoning item with
  `encrypted_content`, the text "I will write it.", then a `write_file` call whose arguments come in two pieces;
  usage with cached tokens.
- `summary.sse`: written by hand, the summary a compaction asks for (the text of `openai_chat/summary.sse`).
