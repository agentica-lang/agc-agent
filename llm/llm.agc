## A client for LLM APIs: one provider-neutral API (messages, tools, a stream of events, usage, stop reasons and
## errors) with providers underneath. Callers see only these records; each provider maps them to its wire format.
##
## Errors have a kind and, for an HTTP answer, the status as `code`: `llm.auth`, `llm.rate_limit` (`retry_after_ms` in
## `details`), `llm.overloaded`, `llm.invalid_request`, `llm.server`, `llm.network`, `llm.protocol` (bad SSE or JSON,
## a cut stream), `llm.api` (an error inside the stream), `llm.cancelled`, `llm.slow_reader` (the events were not read
## in time), `llm.unsupported` (a feature the provider does not have). A request is tried again only before the
## first byte of its stream, on 429, 5xx and network errors.

import Anthropic from "src/anthropic"
import Api from "src/api"
import OpenAIChat from "src/openai_chat"
import Http from "src/http"
import OpenAIResponses from "src/openai_responses"
import Stop from "src/stop_reason"
import Types from "src/types"

VERSION = "0.0.1"
## The Anthropic API, its default model and its cheap one.
ANTHROPIC_URL = Anthropic.URL
ANTHROPIC_MODEL = Anthropic.MODEL
ANTHROPIC_CHEAP_MODEL = Anthropic.CHEAP_MODEL

export Http.Options
export Anthropic.anthropic
export OpenAIChat.openai_chat
export OpenAIResponses.openai_responses
export Api.Provider
export Api.Stream
export Api.stream
export Api.cancel
export Api.response
export Api.models
export Stop.StopReason
export Types.Block
export Types.Event
export Types.Message
export Types.Model
export Types.Piece
export Types.Request
export Types.Response
export Types.Role
export Types.TextPart
export Types.ThinkingPart
export Types.Tool
export Types.ToolCall
export Types.ToolChoice
export Types.ToolKind
export Types.ToolOutput
export Types.ToolStart
export Types.Usage
