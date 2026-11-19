## The paths and the header of the HTTP API, so the server and the clients share them.

HEALTH_PATH = "/v1/health"
SESSIONS_PATH = "/v1/sessions"
SERVER_PATH = "/v1/server"
SERVER_STOP_PATH = "/v1/server/stop"
## `GET`: the end of the server log (`?lines=N`), and the warnings the server logged since it started.
LOGS_PATH = "/v1/logs"
## `POST`: the server reads its config file, extensions, skills and project instructions again.
RELOAD_PATH = "/v1/reload"
PROVIDERS_PATH = "/v1/providers"
## `GET`: the MCP servers and their states (`?session=ID` adds those of the session's folder); `MCP_PATH/NAME/reconnect`
## (`POST`, with the same `?session=ID`) starts one server again, and `MCP_PATH/NAME/log` (`GET`, `?lines=N` too) gives the
## end of its log.
MCP_PATH = "/v1/mcp"
AUTH_PATH = "/v1/auth"

## The header a client sends to resume an event stream.
LAST_EVENT_ID_HEADER = "Last-Event-ID"

def mcp_reconnect_path(name: String) -> String = "#{MCP_PATH}/#{name}/reconnect"

def mcp_log_path(name: String) -> String = "#{MCP_PATH}/#{name}/log"

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

def status_segments_path(session_id: String) -> String = "#{session_path(session_id)}/status-segments"

## A login to a provider (`POST`), or its logout (`DELETE`); for a device login (`chatgpt`) the `POST` starts it, `GET`
## says where it is, and `DELETE` also ends a wait. `AUTH_PATH` lists the logins (`GET`), removes every
## stored key (`DELETE`), or makes an empty key file when there is none (`PUT`: a first-start login skipped).
def auth_path(provider: String) -> String = "#{AUTH_PATH}/#{provider}"

## The paths and the header, for `Protocol.wire_shape`.
def shape() -> List[String]
  [
    HEALTH_PATH,
    SESSIONS_PATH,
    SERVER_PATH,
    SERVER_STOP_PATH,
    LOGS_PATH,
    RELOAD_PATH,
    PROVIDERS_PATH,
    MCP_PATH,
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
    status_segments_path("ID"),
    auth_path("P"),
    mcp_reconnect_path("N"),
    mcp_log_path("N"),
  ]
end
