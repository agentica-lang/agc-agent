## The messages between the agc-agent server and its clients: the bodies of the HTTP commands, their answers and the
## events of the SSE stream, with their JSON codecs. Pure: no I/O, and it depends on no other package.
##
## Each record has an `encode_X` and a `decode_X` (an event has `encode_event` and `decode_event`). Decoding fails with
## `protocol.invalid` for text that is not that record, and with `protocol.unknown` for an event, decision or role
## name that does not exist. Extra keys are ignored.

import Events from "src/events"
import Errors from "src/errors"
import Replies from "src/replies"
import Requests from "src/requests"

VERSION = "0.0.1"

export Requests.Decision
export Requests.NewSession
export Requests.SendMessage
export Requests.Approve
export Requests.decision_name
export Requests.parse_decision
export Requests.encode_new_session
export Requests.decode_new_session
export Requests.encode_send_message
export Requests.decode_send_message
export Requests.encode_approve
export Requests.decode_approve

export Replies.Role
export Replies.Health
export Replies.SessionCreated
export Replies.MessageAccepted
export Replies.SessionSummary
export Replies.SessionList
export Replies.Message
export Replies.Session
export Replies.role_name
export Replies.parse_role
export Replies.encode_health
export Replies.decode_health
export Replies.encode_session_created
export Replies.decode_session_created
export Replies.encode_message_accepted
export Replies.decode_message_accepted
export Replies.encode_session_list
export Replies.decode_session_list
export Replies.encode_session
export Replies.decode_session

export Errors.Failure
export Errors.encode_failure
export Errors.decode_failure

export Events.EventKind
export Events.Event
export Events.TurnStarted
export Events.TextDelta
export Events.ThinkingDelta
export Events.ToolStarted
export Events.ToolFinished
export Events.ApprovalRequested
export Events.ApprovalResolved
export Events.Usage
export Events.TurnFinished
export Events.kind
export Events.kind_name
export Events.parse_kind
export Events.event_name
export Events.encode_event
export Events.decode_event
export Events.format_event_id
export Events.parse_event_id
