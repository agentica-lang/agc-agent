## The events the server streams on `GET /v1/sessions/ID/events`: the SSE `event:` is the kind's name, `id:` the event
## id and `data:` the JSON of the payload.
##
## An event id is a counter per session: the first event is 1, and each one is the last plus one. The session keeps the
## counter across a restart, so a `Last-Event-ID` stays valid. A reader ignores a key it does not know.

import Errors from "errors"
import Kinds from "kinds"
import Requests from "requests"
import Wire from "wire"

enum EventKind
  TurnStarted
  TextDelta
  ThinkingDelta
  ToolStarted
  ToolFinished
  ApprovalRequested
  ApprovalResolved
  Usage
  TurnFinished
  Error
  Resync
end

## Who resolved an approval.
enum ApprovalSource
  ## A client answered.
  Client
  ## Nobody answered in time (the approval is denied).
  Timeout
  ## The turn was stopped (the approval is denied).
  Stop
  ## An `allow` or `deny` rule of the config answered.
  Rule
end

## Why a turn ended. `Other` keeps a reason this package does not know by its name, never a known one: build it with
## `parse_stop_reason`, and `encode_event` writes `Other` of a known name as that reason.
enum StopReason
  EndTurn
  MaxTokens
  Refusal
  ## The client stopped the turn.
  Cancelled
  ## The loop guard ended the turn.
  LoopGuard
  Other(String)
end

struct TurnStarted
  turn_id: String
end

struct TextDelta
  text: String
end

struct ThinkingDelta
  text: String
end

struct ToolStarted
  call_id: String
  name: String
  summary: String
end

struct ToolFinished
  call_id: String
  ok: Bool
  summary: String
  duration_ms: Int
end

struct ApprovalRequested
  approval_id: String
  call_id: String
  tool: String
  preview: String
end

struct ApprovalResolved
  approval_id: String
  decision: Requests.Decision
  source: ApprovalSource
end

## Token counts of one model call; `context` is the size of the context after it. None is negative.
struct Usage
  input: Int
  output: Int
  cache_read: Int
  cache_write: Int
  context: Int
end

struct TurnFinished
  turn_id: String
  stop_reason: StopReason
end

## `Resync` says the `Last-Event-ID` is unknown or too old: read the session again.
enum Event
  TurnStarted(TurnStarted)
  TextDelta(TextDelta)
  ThinkingDelta(ThinkingDelta)
  ToolStarted(ToolStarted)
  ToolFinished(ToolFinished)
  ApprovalRequested(ApprovalRequested)
  ApprovalResolved(ApprovalResolved)
  Usage(Usage)
  TurnFinished(TurnFinished)
  Error(Errors.Failure)
  Resync
end

## Every kind of event, in a fixed order.
def event_kinds() -> List[EventKind] = Wire.chain(EventKind.TurnStarted, &following_kind)

def event_kind(event: Event) -> EventKind
  case event
    Event.TurnStarted(_) -> EventKind.TurnStarted
    Event.TextDelta(_) -> EventKind.TextDelta
    Event.ThinkingDelta(_) -> EventKind.ThinkingDelta
    Event.ToolStarted(_) -> EventKind.ToolStarted
    Event.ToolFinished(_) -> EventKind.ToolFinished
    Event.ApprovalRequested(_) -> EventKind.ApprovalRequested
    Event.ApprovalResolved(_) -> EventKind.ApprovalResolved
    Event.Usage(_) -> EventKind.Usage
    Event.TurnFinished(_) -> EventKind.TurnFinished
    Event.Error(_) -> EventKind.Error
    Event.Resync -> EventKind.Resync
  end
end

def kind_name(kind: EventKind) -> String
  case kind
    EventKind.TurnStarted -> "turn_started"
    EventKind.TextDelta -> "text_delta"
    EventKind.ThinkingDelta -> "thinking_delta"
    EventKind.ToolStarted -> "tool_started"
    EventKind.ToolFinished -> "tool_finished"
    EventKind.ApprovalRequested -> "approval_requested"
    EventKind.ApprovalResolved -> "approval_resolved"
    EventKind.Usage -> "usage"
    EventKind.TurnFinished -> "turn_finished"
    EventKind.Error -> "error"
    EventKind.Resync -> "resync"
  end
end

def parse_kind(name: String) -> Result[EventKind] = Wire.lookup(event_kinds(), &kind_name, "event", name)

## Every source of an approval's resolution, in a fixed order.
def approval_sources() -> List[ApprovalSource] = Wire.chain(ApprovalSource.Client, &following_source)

def source_name(source: ApprovalSource) -> String
  case source
    ApprovalSource.Client -> "client"
    ApprovalSource.Timeout -> "timeout"
    ApprovalSource.Stop -> "stop"
    ApprovalSource.Rule -> "rule"
  end
end

def parse_source(name: String) -> Result[ApprovalSource]
  Wire.lookup(approval_sources(), &source_name, "source", name)
end

## Every stop reason but `Other`, in a fixed order.
def known_stop_reasons() -> List[StopReason] = Wire.chain(StopReason.EndTurn, &following_reason)

def stop_reason_name(reason: StopReason) -> String
  case reason
    StopReason.EndTurn -> "end_turn"
    StopReason.MaxTokens -> "max_tokens"
    StopReason.Refusal -> "refusal"
    StopReason.Cancelled -> "cancelled"
    StopReason.LoopGuard -> "loop_guard"
    StopReason.Other(name) -> name
  end
end

## The reason with that name on the wire; a name that is not known is `Other(name)`.
def parse_stop_reason(name: String) -> StopReason
  case Wire.lookup(known_stop_reasons(), &stop_reason_name, "stop reason", name)
    ok(reason) -> reason
    error(_) -> StopReason.Other(name)
  end
end

## The SSE `event:` of an event.
def event_name(event: Event) -> String = kind_name(event_kind(event))

## The SSE `data:` of an event.
def encode_event(event: Event) -> String
  case event
    Event.TurnStarted(data) -> JSON.encode(data)
    Event.TextDelta(data) -> JSON.encode(data)
    Event.ThinkingDelta(data) -> JSON.encode(data)
    Event.ToolStarted(data) -> JSON.encode(data)
    Event.ToolFinished(data) -> JSON.encode(data)
    Event.ApprovalRequested(data) -> JSON.encode(data)
    Event.ApprovalResolved(data) ->
      JSON.encode(
        ResolvedWire(
          approval_id: data.approval_id,
          decision: Requests.decision_name(data.decision),
          source: source_name(data.source),
        ),
      )
    Event.Usage(data) -> JSON.encode(data)
    Event.TurnFinished(data) ->
      JSON.encode(TurnFinishedWire(turn_id: data.turn_id, stop_reason: stop_reason_name(data.stop_reason)))
    Event.Error(data) -> Errors.encode_failure(data)
    Event.Resync -> "{}"
  end
end

## An event from its SSE `event:` and `data:`. An unknown name is `protocol.unknown`; bad data (a missing field, a
## wrong type, a negative count or duration) is `protocol.invalid`.
def decode_event(name: String, data: String) -> Result[Event]
  case try parse_kind(name)
    EventKind.TurnStarted -> ok(Event.TurnStarted(try Wire.decode(data, TurnStarted.codec)))
    EventKind.TextDelta -> ok(Event.TextDelta(try Wire.decode(data, TextDelta.codec)))
    EventKind.ThinkingDelta -> ok(Event.ThinkingDelta(try Wire.decode(data, ThinkingDelta.codec)))
    EventKind.ToolStarted -> ok(Event.ToolStarted(try Wire.decode(data, ToolStarted.codec)))
    EventKind.ToolFinished -> decode_tool_finished(data)
    EventKind.ApprovalRequested -> ok(Event.ApprovalRequested(try Wire.decode(data, ApprovalRequested.codec)))
    EventKind.ApprovalResolved -> decode_resolved(data)
    EventKind.Usage -> decode_usage(data)
    EventKind.TurnFinished -> decode_turn_finished(data)
    EventKind.Error -> ok(Event.Error(try Errors.decode_failure(data)))
    EventKind.Resync -> decode_resync(data)
  end
end

## The text of an event id (the SSE `id:`).
def format_event_id(id: Int) -> String = id.to_s

## The id of a `Last-Event-ID` header; anything but a whole number from 0 up is `protocol.invalid`.
def parse_event_id(text: String) -> Result[Int]
  case text.to_i
    ok(id) if id >= 0 and format_event_id(id) == text -> ok(id)
    _ -> error("invalid event id: #{text}", kind: Kinds.KIND_INVALID)
  end
end

private

struct ResolvedWire
  approval_id: String
  decision: String
  source: String
end

struct TurnFinishedWire
  turn_id: String
  stop_reason: String
end

def following_kind(kind: EventKind) -> Optional[EventKind]
  case kind
    EventKind.TurnStarted -> some(EventKind.TextDelta)
    EventKind.TextDelta -> some(EventKind.ThinkingDelta)
    EventKind.ThinkingDelta -> some(EventKind.ToolStarted)
    EventKind.ToolStarted -> some(EventKind.ToolFinished)
    EventKind.ToolFinished -> some(EventKind.ApprovalRequested)
    EventKind.ApprovalRequested -> some(EventKind.ApprovalResolved)
    EventKind.ApprovalResolved -> some(EventKind.Usage)
    EventKind.Usage -> some(EventKind.TurnFinished)
    EventKind.TurnFinished -> some(EventKind.Error)
    EventKind.Error -> some(EventKind.Resync)
    EventKind.Resync -> none
  end
end

def following_source(source: ApprovalSource) -> Optional[ApprovalSource]
  case source
    ApprovalSource.Client -> some(ApprovalSource.Timeout)
    ApprovalSource.Timeout -> some(ApprovalSource.Stop)
    ApprovalSource.Stop -> some(ApprovalSource.Rule)
    ApprovalSource.Rule -> none
  end
end

def following_reason(reason: StopReason) -> Optional[StopReason]
  case reason
    StopReason.EndTurn -> some(StopReason.MaxTokens)
    StopReason.MaxTokens -> some(StopReason.Refusal)
    StopReason.Refusal -> some(StopReason.Cancelled)
    StopReason.Cancelled -> some(StopReason.LoopGuard)
    StopReason.LoopGuard -> none
    StopReason.Other(_) -> none
  end
end

def decode_tool_finished(data: String) -> Result[Event]
  finished = try Wire.decode(data, ToolFinished.codec)
  try Wire.non_negative("duration_ms", finished.duration_ms)
  ok(Event.ToolFinished(finished))
end

def decode_usage(data: String) -> Result[Event]
  usage = try Wire.decode(data, Usage.codec)
  try Wire.non_negative("input", usage.input)
  try Wire.non_negative("output", usage.output)
  try Wire.non_negative("cache_read", usage.cache_read)
  try Wire.non_negative("cache_write", usage.cache_write)
  try Wire.non_negative("context", usage.context)
  ok(Event.Usage(usage))
end

def decode_resolved(data: String) -> Result[Event]
  wire = try Wire.decode(data, ResolvedWire.codec)
  decision = try Requests.parse_decision(wire.decision)
  source = try parse_source(wire.source)
  ok(Event.ApprovalResolved(ApprovalResolved(approval_id: wire.approval_id, decision: decision, source: source)))
end

def decode_turn_finished(data: String) -> Result[Event]
  wire = try Wire.decode(data, TurnFinishedWire.codec)
  ok(Event.TurnFinished(TurnFinished(turn_id: wire.turn_id, stop_reason: parse_stop_reason(wire.stop_reason))))
end

def decode_resync(data: String) -> Result[Event]
  case JSON.parse(data)
    ok(json) if JSON.kind(json) == "object" -> ok(Event.Resync)
    _ -> error("resync data must be a JSON object", kind: Kinds.KIND_INVALID)
  end
end
