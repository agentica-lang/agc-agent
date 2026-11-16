## The paths and the header of the HTTP API, so the server and the clients share them.

HEALTH_PATH = "/v1/health"
SESSIONS_PATH = "/v1/sessions"

## The header a client sends to resume an event stream.
LAST_EVENT_ID_HEADER = "Last-Event-ID"

def session_path(session_id: String) -> String = "#{SESSIONS_PATH}/#{session_id}"

def events_path(session_id: String) -> String = "#{session_path(session_id)}/events"

def messages_path(session_id: String) -> String = "#{session_path(session_id)}/messages"

def approval_path(session_id: String, approval_id: String) -> String
  "#{session_path(session_id)}/approvals/#{approval_id}"
end

def stop_path(session_id: String) -> String = "#{session_path(session_id)}/stop"

def compact_path(session_id: String) -> String = "#{session_path(session_id)}/compact"
