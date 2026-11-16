## The provider-neutral records of a conversation with a model. Each provider maps them to its wire format and back.
##
## `replay` fields hold opaque provider data (item ids, signatures, encrypted reasoning, a Codex `phase`) that the same
## provider sends back unchanged; `none` when it has none. Callers keep them and never read them.

import {StopReason} from "stop_reason"

## Text the model wrote.
struct TextPart
  text: String
  replay: Optional[JSON.Value] = none
end

## The reasoning of the model, as far as the provider shows it.
struct ThinkingPart
  text: String
  replay: Optional[JSON.Value] = none
  ## The provider that gave it, as the caller names it (empty when not named): a caller that moves to another provider
  ## sends none of the thinking of the one before.
  source: String = ""
end

## A call of a tool by the model.
struct ToolCall
  ## The id a result points to.
  id: String
  name: String
  ## The arguments as the model sent them, sent back byte for byte. For a `Custom` tool, the input itself.
  arguments: String
  ## `arguments` parsed: a JSON object; `{}` for a `Custom` tool or when they do not parse.
  input: JSON.Value
  ## Why `arguments` is not a JSON object, for a `Function` tool: answer the call with an error result.
  input_error: Optional[String] = none
  kind: ToolKind = ToolKind.Function
  replay: Optional[JSON.Value] = none
end

## What a tool gave back for one call.
struct ToolOutput
  tool_use_id: String
  content: String
  is_error: Bool = false
end

## A message: the system prompt is not one (it is a field of `Request`).
struct Message
  role: Role
  content: List[Block]
end

## A tool the model may call.
struct Tool
  name: String
  description: String
  ## The JSON schema of the input of a `Function` tool; the format of a `Custom` one, as its provider takes it.
  input_schema: JSON.Value
  kind: ToolKind = ToolKind.Function
end

## One call to a model.
struct Request
  model: String
  messages: List[Message]
  system: String = ""
  tools: List[Tool] = []
  max_tokens: Int = 4096
  ## How hard the model thinks (`low`, `medium`, `high`), for the models that take it.
  effort: Optional[String] = none
  ## Ask the provider to cache the stable prefix (the system prompt and the tools) and, on Anthropic, the
  ## conversation so far.
  cache: Bool = false
  tool_choice: ToolChoice = ToolChoice.Auto
  ## Not sent by anthropic.
  temperature: Optional[Float] = none
  ## Sent by openai_chat only: the Responses API has no seed.
  seed: Optional[Int] = none
  ## Fields of the provider's own request body, put in last: they replace the fields above, except that an object
  ## merges into the object of the same key, one level deep (`reasoning: {summary: "auto"}` keeps `effort`).
  extra: Map[String, JSON.Value] = {}
  ## HTTP headers sent with the request. One replaces the provider's header of the same name (`Authorization`, say);
  ## names are compared without case, and of two that differ only in case the last one is sent.
  headers: Map[String, String] = {}
end

## Tokens of one call; zero when the provider does not say.
struct Usage
  ## Input tokens neither read from the cache nor written to it.
  input: Int = 0
  ## Output tokens, the reasoning ones included.
  output: Int = 0
  ## Input tokens read from the cache.
  cache_read: Int = 0
  ## Input tokens written to the cache.
  cache_write: Int = 0
  ## The part of `output` spent on reasoning.
  reasoning: Int = 0
end

## The whole answer of a call, once its stream ended.
struct Response
  message: Message
  stop_reason: StopReason
  usage: Usage
  ## The provider's id of the answer; `""` when it gives none.
  id: String = ""
end

## A model a provider serves.
struct Model
  id: String
  ## The context window in tokens, when the API says it.
  context: Optional[Int] = none
end

## A piece of a block as it streams. `index` is the place of the block in the content of the response.
struct Piece
  index: Int
  text: String
  ## The provider's id of the item the block comes from; `""` when it has none.
  item_id: String = ""
end

## A tool call that starts streaming.
struct ToolStart
  index: Int
  id: String
  name: String
  item_id: String = ""
end

## What a provider's wire made of one piece of its stream: the next state and the events it gave. Not exported.
struct Fold[S]
  state: S
  events: List[Event]
end

enum Role
  User
  Assistant
end

## One part of a message.
enum Block
  Text(TextPart)
  Thinking(ThinkingPart)
  ToolUse(ToolCall)
  ToolResult(ToolOutput)
end

enum ToolKind
  ## Its input is a JSON object that fits a schema.
  Function
  ## Freeform: its input is raw text (Responses custom tools, such as Codex `apply_patch`).
  Custom
end

enum ToolChoice
  ## The model decides.
  Auto
  ## The model must call a tool. Not on anthropic (`llm.unsupported`).
  Required
end

## What a stream gives as it comes.
enum Event
  TextDelta(Piece)
  ThinkingDelta(Piece)
  ToolUseStart(ToolStart)
  ## A piece of the arguments of a tool call.
  ToolInputDelta(Piece)
  UsageUpdate(Usage)
  Stop(StopReason)
end
