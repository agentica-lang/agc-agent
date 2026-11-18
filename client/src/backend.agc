## The calls a client makes on the server of one session at a time, as a record of functions (a port):
## `http_backend` fills it from the HTTP client, and a test fills it with what it needs (`unreachable_backend` fails
## every call) to run a client without a server.

import Protocol from "pkg/protocol/protocol"
import Discovery from "discovery"
import Events from "feed"
import Http from "http"

struct Backend
  create_session: Fn[Protocol.NewSession, Result[String]]
  session: Fn[String, Result[Protocol.Session]]
  send_message: Fn[String, String, Result[Protocol.MessageAccepted]]
  approve: Fn[String, String, Protocol.Decision, Result[Void]]
  stop: Fn[String, Optional[String], Result[Bool]]
  shell: Fn[String, Protocol.RunShell, Result[Protocol.ShellAccepted]]
  files: Fn[String, Result[Protocol.FileList]]
  update_session: Fn[String, Protocol.UpdateSession, Result[Void]]
  compact: Fn[String, Result[Bool]]
  tree: Fn[String, Result[Protocol.SessionTree]]
  exported: Fn[String, Result[Protocol.SessionExport]]
  branch: Fn[String, Int, Result[Protocol.Branched]]
  fork: Fn[String, Optional[Int], Result[Protocol.Branched]]
  list_sessions: Fn[Result[Protocol.SessionList]]
  list_providers: Fn[Result[Protocol.ProviderList]]
  list_profiles: Fn[String, Result[Protocol.ProfileList]]
  list_commands: Fn[String, Result[Protocol.CommandList]]
  list_logins: Fn[Result[Protocol.LoginList]]
  login: Fn[String, String, Result[Protocol.LoginStatus]]
  login_url: Fn[String, String, Result[Protocol.LoginStatus]]
  ## A device login (ChatGPT): its start, and where it is.
  device_start: Fn[String, Result[Protocol.DeviceLogin]]
  device_state: Fn[String, Result[Protocol.DeviceState]]
  logout: Fn[Optional[String], Result[Void]]
  ## The last lines of the server log (as many as asked) and its load warnings.
  server_log: Fn[Int, Result[Protocol.ServerLog]]
  ## The server reads its config, skills, extensions and project instructions again.
  reload: Fn[Result[Protocol.Reloaded]]
  skip_login: Fn[Result[Void]]
  ## The server is still the one of this version, before its stream is read again.
  recheck: Fn[Result[Void]]
  ## Starts the reader of the events of a session after an id; each item goes to the function given.
  subscribe: Fn[String, Int, Fn[Events.Item, Result[Void]], Task[Void]]
  ## The warning of `--yolo` on this server.
  yolo_warning: Fn[String]
  ## Whether the server's config leaves the mouse on for the full screen.
  mouse: Fn[Bool]
end

## The calls on `server` over HTTP.
def http_backend(server: Http.Server) -> Backend
  Backend(
    create_session: ->(request) { created_id(Http.create_session(server, request)) },
    session: ->(id) { Http.session(server, id) },
    send_message: ->(id, text) { Http.send_message(server, id, text) },
    approve: ->(id, approval_id, decision) { Http.approve(server, id, approval_id, decision) },
    stop: ->(id, turn_id) { Http.stop(server, id, turn_id) },
    shell: ->(id, request) { Http.shell(server, id, request) },
    files: ->(id) { Http.files(server, id) },
    update_session: ->(id, change) { Http.update_session(server, id, change) },
    compact: ->(id) { Http.compact(server, id) },
    tree: ->(id) { Http.tree(server, id) },
    exported: ->(id) { Http.exported(server, id) },
    branch: ->(id, entry) { Http.branch(server, id, entry) },
    fork: ->(id, entry) { Http.fork(server, id, entry) },
    list_sessions: -> { Http.list_sessions(server) },
    list_providers: -> { Http.list_providers(server) },
    list_profiles: ->(id) { Http.list_profiles(server, id) },
    list_commands: ->(id) { Http.list_commands(server, id) },
    list_logins: -> { Http.list_logins(server) },
    login: ->(provider, key) { Http.login(server, provider, key) },
    login_url: ->(provider, url) { Http.login_url(server, provider, url) },
    device_start: ->(provider) { Http.device_start(server, provider) },
    device_state: ->(provider) { Http.device_state(server, provider) },
    logout: ->(provider) { Http.logout(server, provider) },
    server_log: ->(lines) { Http.server_log(server, lines) },
    reload: -> { Http.reload(server) },
    skip_login: -> { Http.skip_login(server) },
    recheck: -> { Discovery.recheck(server) },
    subscribe: ->(id, from, tell) {
      Events.start(Events.Feed(server: server, session_id: id, last_event_id: from, tell: tell))
    },
    yolo_warning: -> { Http.yolo_warning(server) },
    mouse: -> { Http.mouse(server) },
  )
end

## Every call fails as a server that cannot be reached does, and a stream ends at once: a test replaces the calls it
## needs.
def unreachable_backend() -> Backend
  Backend(
    create_session: ->(_request) { failed() },
    session: ->(_id) { failed() },
    send_message: ->(_id, _text) { failed() },
    approve: ->(_id, _approval_id, _decision) { failed() },
    stop: ->(_id, _turn_id) { failed() },
    shell: ->(_id, _request) { failed() },
    files: ->(_id) { failed() },
    update_session: ->(_id, _change) { failed() },
    compact: ->(_id) { failed() },
    tree: ->(_id) { failed() },
    exported: ->(_id) { failed() },
    branch: ->(_id, _entry) { failed() },
    fork: ->(_id, _entry) { failed() },
    list_sessions: -> { failed() },
    list_providers: -> { failed() },
    list_profiles: ->(_id) { failed() },
    list_commands: ->(_id) { failed() },
    list_logins: -> { failed() },
    login: ->(_provider, _key) { failed() },
    login_url: ->(_provider, _url) { failed() },
    device_start: ->(_provider) { failed() },
    device_state: ->(_provider) { failed() },
    logout: ->(_provider) { failed() },
    server_log: ->(_lines) { failed() },
    reload: -> { failed() },
    skip_login: -> { failed() },
    recheck: -> { failed() },
    subscribe: ->(_id, _from, tell) { Task.spawn(-> { _ = tell.call(Events.Item.Ended("no server")) }) },
    yolo_warning: -> { Http.YOLO_ASKS_NOT },
    mouse: -> { true },
  )
end

private

def failed[T]() -> Result[T] = error("no server in this test", kind: Http.KIND_UNREACHABLE)

def created_id(created: Result[Protocol.SessionCreated]) -> Result[String]
  case created
    ok(c) -> ok(c.id)
    error(e) -> error(e)
  end
end
