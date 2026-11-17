## The paths and the header of the HTTP API, so the server and the clients share them.

HEALTH_PATH = "/v1/health"
SESSIONS_PATH = "/v1/sessions"
SERVER_PATH = "/v1/server"
SERVER_STOP_PATH = "/v1/server/stop"
PROVIDERS_PATH = "/v1/providers"
AUTH_PATH = "/v1/auth"

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

def tree_path(session_id: String) -> String = "#{session_path(session_id)}/tree"

def export_path(session_id: String) -> String = "#{session_path(session_id)}/export"

def branch_path(session_id: String) -> String = "#{session_path(session_id)}/branch"

def fork_path(session_id: String) -> String = "#{session_path(session_id)}/fork"

def shell_path(session_id: String) -> String = "#{session_path(session_id)}/shell"

def files_path(session_id: String) -> String = "#{session_path(session_id)}/files"

def profiles_path(session_id: String) -> String = "#{session_path(session_id)}/profiles"

def commands_path(session_id: String) -> String = "#{session_path(session_id)}/commands"

## A login to a provider (`POST`), or its logout (`DELETE`). `AUTH_PATH` lists the logins (`GET`), removes every
## stored key (`DELETE`), or makes an empty key file when there is none (`PUT`: a first-start login skipped).
def auth_path(provider: String) -> String = "#{AUTH_PATH}/#{provider}"

## The paths and the header, for `Protocol.wire_shape`.
def shape() -> List[String]
  [
    HEALTH_PATH,
    SESSIONS_PATH,
    SERVER_PATH,
    SERVER_STOP_PATH,
    PROVIDERS_PATH,
    AUTH_PATH,
    LAST_EVENT_ID_HEADER,
    session_path("ID"),
    events_path("ID"),
    messages_path("ID"),
    approval_path("ID", "A"),
    stop_path("ID"),
    compact_path("ID"),
    tree_path("ID"),
    export_path("ID"),
    branch_path("ID"),
    fork_path("ID"),
    shell_path("ID"),
    files_path("ID"),
    profiles_path("ID"),
    commands_path("ID"),
    auth_path("P"),
  ]
end
