## The events the server streams on `GET /v1/sessions/ID/events`: the SSE `event:` is the kind's name, `id:` the event
## id and `data:` the JSON of the payload.

import Errors from "errors"
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
end

## Token counts of one model call; `context` is the size of the context after it.
struct Usage
  input: Int
  output: Int
  cache_read: Int
  cache_write: Int
  context: Int
end

struct TurnFinished
  turn_id: String
  stop_reason: String
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

def kind(event: Event) -> EventKind
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

def parse_kind(name: String) -> Result[EventKind] = Wire.lookup(KINDS, &kind_name, "event", name)

## The SSE `event:` of an event.
def event_name(event: Event) -> String = kind_name(kind(event))

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
      JSON.encode(ResolvedWire(approval_id: data.approval_id, decision: Requests.decision_name(data.decision)))
    Event.Usage(data) -> JSON.encode(data)
    Event.TurnFinished(data) -> JSON.encode(data)
    Event.Error(data) -> Errors.encode_failure(data)
    Event.Resync -> "{}"
  end
end

## An event from its SSE `event:` and `data:`. An unknown name is `protocol.unknown`; bad data is `protocol.invalid`.
def decode_event(name: String, data: String) -> Result[Event]
  case try parse_kind(name)
    EventKind.TurnStarted -> ok(Event.TurnStarted(try Wire.decode(data, TurnStarted.codec)))
    EventKind.TextDelta -> ok(Event.TextDelta(try Wire.decode(data, TextDelta.codec)))
    EventKind.ThinkingDelta -> ok(Event.ThinkingDelta(try Wire.decode(data, ThinkingDelta.codec)))
    EventKind.ToolStarted -> ok(Event.ToolStarted(try Wire.decode(data, ToolStarted.codec)))
    EventKind.ToolFinished -> ok(Event.ToolFinished(try Wire.decode(data, ToolFinished.codec)))
    EventKind.ApprovalRequested -> ok(Event.ApprovalRequested(try Wire.decode(data, ApprovalRequested.codec)))
    EventKind.ApprovalResolved -> decode_resolved(data)
    EventKind.Usage -> ok(Event.Usage(try Wire.decode(data, Usage.codec)))
    EventKind.TurnFinished -> ok(Event.TurnFinished(try Wire.decode(data, TurnFinished.codec)))
    EventKind.Error -> ok(Event.Error(try Errors.decode_failure(data)))
    EventKind.Resync -> decode_resync(data)
  end
end

## The text of an event id (the SSE `id:`; an event id starts at 1).
def format_event_id(id: Int) -> String = id.to_s

## The id of a `Last-Event-ID` header; anything but a whole number from 0 up is `protocol.invalid`.
def parse_event_id(text: String) -> Result[Int]
  case text.to_i
    ok(id) if id >= 0 and format_event_id(id) == text -> ok(id)
    _ -> error("invalid event id: #{text}", kind: "protocol.invalid")
  end
end

private

KINDS = [
  EventKind.TurnStarted,
  EventKind.TextDelta,
  EventKind.ThinkingDelta,
  EventKind.ToolStarted,
  EventKind.ToolFinished,
  EventKind.ApprovalRequested,
  EventKind.ApprovalResolved,
  EventKind.Usage,
  EventKind.TurnFinished,
  EventKind.Error,
  EventKind.Resync,
]

struct ResolvedWire
  approval_id: String
  decision: String
end

def decode_resolved(data: String) -> Result[Event]
  wire = try Wire.decode(data, ResolvedWire.codec)
  decision = try Requests.parse_decision(wire.decision)
  ok(Event.ApprovalResolved(ApprovalResolved(approval_id: wire.approval_id, decision: decision)))
end

def decode_resync(data: String) -> Result[Event]
  case JSON.parse(data)
    ok(json) if JSON.kind(json) == "object" -> ok(Event.Resync)
    _ -> error("resync data must be a JSON object", kind: "protocol.invalid")
  end
end
