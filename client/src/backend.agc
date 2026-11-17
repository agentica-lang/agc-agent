## The calls a client makes on the server of one session at a time, as a record of functions (a port): `http_backend` fills
## it from the HTTP client, and a test fills it with what it needs (`unreachable_backend` fails every call) to run a client
## without a server.

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
  branch: Fn[String, Int, Result[Protocol.Branched]]
  fork: Fn[String, Optional[Int], Result[Protocol.Branched]]
  list_sessions: Fn[Result[Protocol.SessionList]]
  list_providers: Fn[Result[Protocol.ProviderList]]
  list_logins: Fn[Result[Protocol.LoginList]]
  login: Fn[String, String, Result[Protocol.LoginStatus]]
  login_url: Fn[String, String, Result[Protocol.LoginStatus]]
  logout: Fn[Optional[String], Result[Void]]
  skip_login: Fn[Result[Void]]
  ## The server is still the one of this version, before its stream is read again.
  recheck: Fn[Result[Void]]
  ## Starts the reader of the events of a session after an id; each item goes to the function given.
  subscribe: Fn[String, Int, Fn[Events.Item, Result[Void]], Task[Void]]
  ## The warning of `--yolo` on this server.
  yolo_warning: Fn[String]
end

## The calls on `server` over HTTP.
def http_backend(server: Http.Server) -> Backend
  Backend(
    create_session: ->(request) { Http.create_session(server, request) },
    session: ->(id) { Http.session(server, id) },
    send_message: ->(id, text) { Http.send_message(server, id, text) },
    approve: ->(id, approval_id, decision) { Http.approve(server, id, approval_id, decision) },
    stop: ->(id, turn_id) { Http.stop(server, id, turn_id) },
    shell: ->(id, request) { Http.shell(server, id, request) },
    files: ->(id) { Http.files(server, id) },
    update_session: ->(id, change) { Http.update_session(server, id, change) },
    compact: ->(id) { Http.compact(server, id) },
    tree: ->(id) { Http.tree(server, id) },
    branch: ->(id, entry) { Http.branch(server, id, entry) },
    fork: ->(id, entry) { Http.fork(server, id, entry) },
    list_sessions: -> { Http.list_sessions(server) },
    list_providers: -> { Http.list_providers(server) },
    list_logins: -> { Http.list_logins(server) },
    login: ->(provider, key) { Http.login(server, provider, key) },
    login_url: ->(provider, url) { Http.login_url(server, provider, url) },
    logout: ->(provider) { Http.logout(server, provider) },
    skip_login: -> { Http.skip_login(server) },
    recheck: -> { Discovery.recheck(server) },
    subscribe: ->(id, from, tell) {
      Events.start(Events.Feed(server: server, session_id: id, last_event_id: from, tell: tell))
    },
    yolo_warning: -> { Http.yolo_warning(server) },
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
    branch: ->(_id, _entry) { failed() },
    fork: ->(_id, _entry) { failed() },
    list_sessions: -> { failed() },
    list_providers: -> { failed() },
    list_logins: -> { failed() },
    login: ->(_provider, _key) { failed() },
    login_url: ->(_provider, _url) { failed() },
    logout: ->(_provider) { failed() },
    skip_login: -> { failed() },
    recheck: -> { failed() },
    subscribe: ->(_id, _from, tell) { Task.spawn(-> { _ = tell.call(Events.Item.Ended("no server")) }) },
    yolo_warning: -> { "--yolo: the tool calls of the turns this client starts run without asking" },
  )
end

private

def failed[T]() -> Result[T] = error("no server in this test", kind: Http.KIND_UNREACHABLE)
