# tui_client fixtures

OpenAI chat completions streams written by hand in the shape of
`core/tests/fixtures/openai_chat`: `thinking.sse` has two `reasoning_content`
pieces before a short answer, and `markdown.sse` an answer with a heading, a
list with bold text and a code block. `write_keys.sse` is
`write_file.sse` with a content whose lines look like panel keys (`a = 1`,
`^Y please`).
