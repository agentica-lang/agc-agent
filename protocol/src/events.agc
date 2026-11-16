## The events the server streams on `GET /v1/sessions/ID/events`: the SSE `event:` is the kind's name, `id:` the event
## id and `data:` the JSON of the payload.
##
## An event id is a counter per session: the first event is 1, and each one is the last plus one. The session keeps the
## counter across a restart, so a `Last-Event-ID` stays valid; a restart may skip ids. The server does not keep text
## and thinking deltas across a restart: a `Last-Event-ID` that would need one gets `resync`. A reader ignores a key it
## does not know.

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
  MessageQueued
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

## `history_size` in `turn_started` and `turn_finished` is the size of the session's `history` once the event happened
## (the user message is in it at the start, the answer, if any, at the end); none in an event of an older server. A
## client that reads the session again after a `resync` prints the history from there.
struct TurnStarted
  turn_id: String
  history_size: Optional[Int] = none
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

## `preview` is what the call touches: the path, or the command for `bash`; an `allow_session` answer allows the same
## tool on the same `preview`. `detail` is what it would write (the content, or the old and new text of an edit), cut
## to a few KB; empty when there is nothing more to show.
struct ApprovalRequested
  approval_id: String
  call_id: String
  tool: String
  preview: String
  detail: String
end

struct ApprovalResolved
  approval_id: String
  decision: Requests.Decision
  source: ApprovalSource
end

## Token counts after a model call. `input`, `cache_read` and `cache_write` are that call's, `output` is the sum over
## every call of the session, and `context` is the size of the prompt of that call (`input + cache_read +
## cache_write`). None is negative.
struct Usage
  input: Int
  output: Int
  cache_read: Int
  cache_write: Int
  context: Int
  ## In USD, from the prices of the model catalog: this call, the turn so far and the session so far (the sums
  ## count the calls that had a price). None when the catalog has no prices for the model. The calls that write a
  ## compaction's summary are not counted.
  cost: Optional[Float] = none
  turn_cost: Optional[Float] = none
  session_cost: Optional[Float] = none
end

## A message sent while the turn `turn_id` runs: the turn reads it before its next model call.
struct MessageQueued
  turn_id: String
  text: String
end

struct TurnFinished
  turn_id: String
  stop_reason: StopReason
  history_size: Optional[Int] = none
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
  MessageQueued(MessageQueued)
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
    Event.MessageQueued(_) -> EventKind.MessageQueued
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
    EventKind.MessageQueued -> "message_queued"
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
    Event.TurnStarted(data) ->
      JSON.encode(TurnStartedWire(turn_id: data.turn_id, history_size: field(data.history_size)))
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
    Event.Usage(data) ->
      wire = UsageWire(
        input: data.input,
        output: data.output,
        cache_read: data.cache_read,
        cache_write: data.cache_write,
        context: data.context,
        cost: Wire.field(data.cost),
        turn_cost: Wire.field(data.turn_cost),
        session_cost: Wire.field(data.session_cost),
      )

      JSON.encode(wire)
    Event.TurnFinished(data) ->
      wire = TurnFinishedWire(
        turn_id: data.turn_id,
        stop_reason: stop_reason_name(data.stop_reason),
        history_size: field(data.history_size),
      )

      JSON.encode(wire)
    Event.Error(data) -> Errors.encode_failure(data)
    Event.Resync -> "{}"
    Event.MessageQueued(data) -> JSON.encode(data)
  end
end

## An event from its SSE `event:` and `data:`. An unknown name is `protocol.unknown`; bad data (a missing field, a
## wrong type, a negative count or duration) is `protocol.invalid`.
def decode_event(name: String, data: String) -> Result[Event]
  case try parse_kind(name)
    EventKind.TurnStarted -> decode_turn_started(data)
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
    EventKind.MessageQueued -> ok(Event.MessageQueued(try Wire.decode(data, MessageQueued.codec)))
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

## The fields of the events and the names of their values on the wire, for `Protocol.WIRE`.
def shape() -> List[String]
  records = [
    TurnStarted.members,
    TextDelta.members,
    ThinkingDelta.members,
    ToolStarted.members,
    ToolFinished.members,
    ApprovalRequested.members,
    ApprovalResolved.members,
    Usage.members,
    TurnFinished.members,
    ResolvedWire.members,
    TurnStartedWire.members,
    TurnFinishedWire.members,
    Errors.Failure.members,
  ]

  names = event_kinds().map(&kind_name) + approval_sources().map(&source_name)
  Wire.fields(records) + names + known_stop_reasons().map(&stop_reason_name)
end

private

struct ResolvedWire
  approval_id: String
  decision: String
  source: String
end

struct UsageWire
  input: Int
  output: Int
  cache_read: Int
  cache_write: Int
  context: Int
  cost: JSON.Field[Float]
  turn_cost: JSON.Field[Float]
  session_cost: JSON.Field[Float]
end

struct TurnStartedWire
  turn_id: String
  history_size: JSON.Field[Int]
end

struct TurnFinishedWire
  turn_id: String
  stop_reason: String
  history_size: JSON.Field[Int]
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
    EventKind.Resync -> some(EventKind.MessageQueued)
    EventKind.MessageQueued -> none
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
  wire = try Wire.decode(data, UsageWire.codec)
  usage = Usage(
    input: wire.input,
    output: wire.output,
    cache_read: wire.cache_read,
    cache_write: wire.cache_write,
    context: wire.context,
    cost: Wire.optional(wire.cost),
    turn_cost: Wire.optional(wire.turn_cost),
    session_cost: Wire.optional(wire.session_cost),
  )

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

def decode_turn_started(data: String) -> Result[Event]
  wire = try Wire.decode(data, TurnStartedWire.codec)
  ok(Event.TurnStarted(TurnStarted(turn_id: wire.turn_id, history_size: try history_size(wire.history_size))))
end

def decode_turn_finished(data: String) -> Result[Event]
  wire = try Wire.decode(data, TurnFinishedWire.codec)
  finished = TurnFinished(
    turn_id: wire.turn_id,
    stop_reason: parse_stop_reason(wire.stop_reason),
    history_size: try history_size(wire.history_size),
  )

  ok(Event.TurnFinished(finished))
end

# An event of an older server has no `history_size`.
def field(size: Optional[Int]) -> JSON.Field[Int]
  case size
    some(n) -> JSON.Field.Value(n)
    none -> JSON.Field.Absent
  end
end

def history_size(size: JSON.Field[Int]) -> Result[Optional[Int]]
  case size
    JSON.Field.Value(n) ->
      try Wire.non_negative("history_size", n)
      ok(some(n))
    _ -> ok(none)
  end
end

def decode_resync(data: String) -> Result[Event]
  case JSON.parse(data)
    ok(json) if JSON.kind(json) == "object" -> ok(Event.Resync)
    _ -> error("resync data must be a JSON object", kind: Kinds.KIND_INVALID)
  end
end
