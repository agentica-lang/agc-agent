## The messages between the Finn Agent server and its clients: the bodies of the HTTP commands, their answers and the
## events of the SSE stream, with their JSON codecs, and the paths and error kinds both sides share. Pure: no I/O, and
## it depends on no other package.
##
## Each record has an `encode_X` and a `decode_X` (an event has `encode_event` and `decode_event`). Decoding fails with
## `protocol.invalid` for text that is not that record, and with `protocol.unknown` for an event, decision, source or
## role name that does not exist; the JSON error is the cause. The decoders of the requests refuse a key they do not
## know and an empty required string. The decoders of the replies and the events ignore extra keys, so a reader older
## than the writer still works, and leave empty strings to the server.
##
## Resume: `Session.last_event_id` is the `Last-Event-ID` that misses and repeats no event. A client that attaches
## while a turn runs uses `Session.turn_from_event_id` instead, so the replay gives it the whole running turn.

import Errors from "src/errors"
import Events from "src/events"
import Kinds from "src/kinds"
import Replies from "src/replies"
import Requests from "src/requests"
import Routes from "src/routes"

VERSION = "0.0.1"
## The bidi control characters, which reorder the text around them on a screen. Titles and text shown from another
## client leave them out.
BIDI = Set.new([0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069])

export Replies.ASKS_KEY
export Replies.ASKS_URL
export Kinds.KIND_INVALID
export Kinds.KIND_UNKNOWN
export Kinds.KIND_UNAUTHORIZED
export Kinds.KIND_FORBIDDEN
export Kinds.KIND_SESSION_NOT_FOUND
export Kinds.KIND_SESSION_BUSY
export Kinds.KIND_QUEUE_DROPPED
export Kinds.KIND_SESSION_STORAGE
export Kinds.KIND_SESSION_UNAVAILABLE
export Kinds.KIND_APPROVAL_NOT_FOUND
export Kinds.KIND_APPROVAL_RESOLVED
export Kinds.KIND_SERVER_STOPPING
export Kinds.KIND_SHELL_DENIED
export Kinds.KIND_LOGIN_REJECTED
export Kinds.KIND_LOGIN_STORAGE

export Routes.HEALTH_PATH
export Routes.SESSIONS_PATH
export Routes.SERVER_PATH
export Routes.SERVER_STOP_PATH
export Routes.PROVIDERS_PATH
export Routes.AUTH_PATH
export Routes.LAST_EVENT_ID_HEADER
export Routes.session_path
export Routes.events_path
export Routes.messages_path
export Routes.approval_path
export Routes.stop_path
export Routes.compact_path
export Routes.tree_path
export Routes.branch_path
export Routes.fork_path
export Routes.shell_path
export Routes.files_path
export Routes.profiles_path
export Routes.commands_path
export Routes.auth_path

export Requests.Decision
export Requests.NewSession
export Requests.SendMessage
export Requests.Approve
export Requests.UpdateSession
export Requests.Compacted
export Requests.Branch
export Requests.Fork
export Requests.StopServer
export Requests.RunShell
export Requests.Login
export Requests.LoginUrl
export Requests.encode_login_url
export Requests.decode_login_url
export Requests.EFFORTS
export Requests.EFFORT_DEFAULT
export Requests.decisions
export Requests.decision_name
export Requests.parse_decision
export Requests.encode_new_session
export Requests.decode_new_session
export Requests.encode_send_message
export Requests.decode_send_message
export Requests.encode_approve
export Requests.decode_approve
export Requests.encode_update_session
export Requests.decode_update_session
export Requests.encode_compacted
export Requests.decode_compacted
export Requests.encode_branch
export Requests.decode_branch
export Requests.encode_stop_server
export Requests.decode_stop_server
export Requests.StopTurn
export Requests.encode_stop_turn
export Requests.decode_stop_turn
export Requests.encode_fork
export Requests.decode_fork
export Requests.encode_run_shell
export Requests.decode_run_shell
export Requests.encode_login
export Requests.decode_login

export Replies.Role
export Replies.Health
export Replies.ServerInfo
export Replies.SessionCreated
export Replies.MessageAccepted
export Replies.SessionSummary
export Replies.SessionList
export Replies.ProviderInfo
export Replies.ProviderList
export Replies.Profile
export Replies.Message
export Replies.Session
export Replies.TreeNode
export Replies.SessionTree
export Replies.Branched
export Replies.ServerStatus
export Replies.ShellAccepted
export Replies.LoginStatus
export Replies.LoginList
export Replies.roles
export Replies.role_name
export Replies.parse_role
export Replies.encode_health
export Replies.decode_health
export Replies.encode_server_info
export Replies.decode_server_info
export Replies.encode_session_created
export Replies.decode_session_created
export Replies.encode_message_accepted
export Replies.decode_message_accepted
export Replies.encode_session_list
export Replies.decode_session_list
export Replies.encode_provider_list
export Replies.decode_provider_list
export Replies.ProfileList
export Replies.encode_profile_list
export Replies.decode_profile_list
export Replies.CommandInfo
export Replies.CommandList
export Replies.encode_command_list
export Replies.decode_command_list
export Replies.encode_session
export Replies.decode_session
export Replies.encode_session_tree
export Replies.decode_session_tree
export Replies.encode_branched
export Replies.decode_branched
export Replies.encode_server_status
export Replies.decode_server_status
export Replies.encode_shell_accepted
export Replies.decode_shell_accepted
export Replies.Stopped
export Replies.encode_stopped
export Replies.decode_stopped
export Replies.FileList
export Replies.encode_file_list
export Replies.decode_file_list
export Replies.encode_login_status
export Replies.decode_login_status
export Replies.encode_login_list
export Replies.decode_login_list

export Errors.Failure
export Errors.encode_failure
export Errors.decode_failure

export Events.EventKind
export Events.ApprovalSource
export Events.StopReason
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
export Events.MessageQueued
export Events.ShellStarted
export Events.ShellFinished
export Events.Todo
export Events.Todos
export Events.TODO_STATUSES
export Events.event_kinds
export Events.event_kind
export Events.kind_name
export Events.parse_kind
export Events.approval_sources
export Events.source_name
export Events.parse_source
export Events.known_stop_reasons
export Events.stop_reason_name
export Events.parse_stop_reason
export Events.event_name
export Events.encode_event
export Events.decode_event
export Events.format_event_id
export Events.parse_event_id

## Every record with its fields, every enum with its names on the wire, the error kinds, the paths and the header.
def wire_shape() -> List[String] = Events.shape() + Replies.shape() + Requests.shape() + Kinds.shape() + Routes.shape()

## A digest of `wire_shape`. A client and a server from different code have different ones when the wire changed, so
## a client can tell that the server it reached is of another version.
def wire_digest() -> String = OpenSSL.Digest.sha256_hexdigest(wire_shape().join(";").bytes)
