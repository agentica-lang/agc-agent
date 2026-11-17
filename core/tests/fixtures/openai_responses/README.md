# openai_responses fixtures of core

- `text.sse`: the same as `llm/tests/fixtures/openai_responses/text.sse`, recorded from llama-server `b12426`.
- `write_file.sse`: written by hand in the shape of `encrypted_reasoning.sse` of `llm`: a reasoning item with
  `encrypted_content`, the text "I will write it.", then a `write_file` call whose arguments come in two pieces;
  usage with cached tokens.
- `summary.sse`: written by hand, the summary a compaction asks for (the text of `openai_chat/summary.sse`).
- `apply_patch.sse`: written by hand in the shape of `custom_tool_call.sse` of `llm`: an `apply_patch` custom tool
  call, its input in two pieces, that updates `notes.txt` and adds `hello.txt`.
- `codex_*.json`: written by hand in the shapes of OpenAI's device login and Codex, for `chatgpt_test`: the user code,
  a poll still pending (403), the grant, the tokens (an `id_token` whose claims name the account `acct-1`, signature
  not checked), Codex's model list, a 401 of a turn, the refreshed tokens, and a refused refresh that quotes the token.
