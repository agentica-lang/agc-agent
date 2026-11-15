## The provider-neutral records of a conversation with a model. Each provider maps them to its wire format and back.

import {StopReason} from "stop_reason"

## A call of a tool by the model.
struct ToolCall
  id: String
  name: String
  ## A JSON object. When the model sent arguments that are not a JSON object, this is their raw text as a JSON
  ## string: answer the call with an error result.
  input: JSON.Value
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
  ## The JSON schema of the input.
  input_schema: JSON.Value
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
  ## Ask the provider to cache the stable prefix (the system prompt and the tools).
  cache: Bool = false
  tool_choice: ToolChoice = ToolChoice.Auto
  temperature: Optional[Float] = none
  seed: Optional[Int] = none
end

## Tokens of one call; zero when the provider does not say. `input` does not count the cached tokens.
struct Usage
  input: Int = 0
  output: Int = 0
  cache_read: Int = 0
  cache_write: Int = 0
end

## The whole answer of a call, once its stream ended.
struct Response
  message: Message
  stop_reason: StopReason
  usage: Usage
end

## A model a provider serves.
struct Model
  id: String
  ## The context window in tokens, when the API says it.
  context: Optional[Int] = none
end

enum Role
  User
  Assistant
end

## One part of a message.
enum Block
  Text(String)
  ## The text, and opaque provider data that goes back unchanged (`null` when the provider has none).
  Thinking(String, JSON.Value)
  ToolUse(ToolCall)
  ToolResult(ToolOutput)
end

enum ToolChoice
  ## The model decides.
  Auto
  ## The model must call a tool.
  Required
end

## What a stream gives as it comes.
enum Event
  TextDelta(String)
  ThinkingDelta(String)
  ## The id and the name of a tool call that starts.
  ToolUseStart(String, String)
  ## The id of a tool call and a piece of its input, as JSON text.
  ToolInputDelta(String, String)
  UsageUpdate(Usage)
  Stop(StopReason)
end
