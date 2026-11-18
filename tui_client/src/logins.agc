## `/login`, `/logout`, `finn login` and the login offered at the first start; a key is typed hidden.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import Picker from "picker"
import Prompt from "prompt"
import State from "state"

## `finn login`: the login picker on its own, until a login ends or it is closed.
def login_only(model: State.Model, provider: Optional[String]) -> Result[State.Model]
  app = State.effect(model.with(login_only: true), State.listen(model.signals))
  list = try app.backend.list_logins.call()
  for name in State.option_list(provider)
    return ok(named_login(app, list.providers, name))
  end

  ok(app.with(picker: some(Picker.logins(list))))
end

## The first start offers a login when the server has no key file and no key in the environment.
def welcomed(app: State.Model) -> State.Model
  case app.backend.list_logins.call()
    ok(list) if list.first ->
      shown = State.noted(
        app,
        "no provider is set up: pick one to give its key, or Esc to go on with the local server",
      )

      shown.with(picker: some(Picker.logins(list)), first_login: true)
    _ -> app
  end
end

def login_command(app: State.Model, name: Optional[String]) -> State.Model
  for given in State.option_list(name)
    return State.tried(app, named_from_server(app, given))
  end

  State.tried(app, login_picking(app))
end

def login_picked(app: State.Model, picker: Picker.Picker, name: String) -> State.Model
  named_login(app, picker.logins, name)
end

## The key goes only into the command that sends it; the model keeps no copy.
def on_secret_key(app: State.Model, name: String, event: TUI.Event) -> State.Model
  case event
    TUI.Event.Char(char, mods) if not mods.alt -> app.with(secret: app.secret + char)
    TUI.Event.Paste(text) -> app.with(secret: app.secret + Prompt.pasted(text).strip)
    TUI.Event.Key(TUI.Key.Backspace, _) ->
      app.with(secret: app.secret.slice(0, [app.secret.length - 1, 0].max.unwrap!))
    TUI.Event.Key(TUI.Key.Escape, _) if app.asking_url ->
      login_cancelled(State.noted(app.with(key_for: none, secret: "", asking_url: false), "no URL given"))
    TUI.Event.Key(TUI.Key.Escape, _) ->
      login_cancelled(State.noted(app.with(key_for: none, secret: ""), "no key given"))
    TUI.Event.Key(TUI.Key.Enter, _) if app.asking_url and not app.secret.strip.empty? ->
      backend = app.backend
      url = app.secret.strip
      checking = State.noted(
        app.with(key_for: none, secret: "", asking_url: false),
        "checking the base URL of #{name}",
      )

      State.effect(checking, TUI.Cmd.Run(-> { State.Msg.LoggedIn(name, backend.login_url.call(name, url)) }))
    TUI.Event.Key(TUI.Key.Enter, _) if not app.secret.strip.empty? ->
      backend = app.backend
      key = app.secret.strip
      checking = State.noted(app.with(key_for: none, secret: ""), "checking the key of #{name}")
      State.effect(checking, TUI.Cmd.Run(-> { State.Msg.LoggedIn(name, backend.login.call(name, key)) }))
    _ -> app
  end
end

## While a device login waits, Esc stops waiting for it; other keys do nothing.
def on_device_key(app: State.Model, event: TUI.Event) -> State.Model
  case event
    TUI.Event.Key(TUI.Key.Escape, _) ->
      stopped = app.with(device: none, device_serial: app.device_serial + 1)
      login_cancelled(State.noted(stopped, "the login of #{app.device_for} is cancelled"))
    _ -> app
  end
end

## The device login started: the user opens its URL and types its code, while the server waits; the app asks where
## it is every `DEVICE_POLL_MS`.
def device_started(app: State.Model, name: String, serial: Int, result: Result[Protocol.DeviceLogin]) -> State.Model
  return app if serial != app.device_serial

  case result
    ok(device) ->
      minutes = device.expires_in / 60
      shown = State.noted(
        app.with(device: some(device), device_for: name),
        "open #{device.url} and enter the code #{device.user_code} (within #{minutes} min): Esc cancels",
      )

      State.effect(shown, poll(app, name, serial))
    error(e) -> ended(State.noted(app, "error: #{e.message}"), false)
  end
end

def device_polled(app: State.Model, name: String, serial: Int, result: Result[Protocol.DeviceState]) -> State.Model
  return app if serial != app.device_serial or app.device.none?

  stopped = app.with(device: none, device_serial: serial + 1)
  case result
    ok(state) if state.state == Protocol.DEVICE_WAITING -> State.effect(app, poll(app, name, serial))
    ok(state) if state.state == Protocol.DEVICE_DONE ->
      ended(lined(moved(stopped, name, "#{name} is set up", state.made_default), name, state.made_default), true)
    ok(state) if state.state == Protocol.DEVICE_FAILED ->
      ended(State.noted(stopped, "error: the login of #{name} failed: #{state.message}"), false)
    ok(_) -> ended(State.noted(stopped, "error: the login of #{name} is no longer waited for"), false)
    error(e) -> ended(State.noted(stopped, "error: #{e.message}"), false)
  end
end

def logged_in(app: State.Model, name: String, result: Result[Protocol.LoginStatus]) -> State.Model
  done = case result
    ok(status) if status.asks == Protocol.ASKS_URL and status.from == "env" ->
      env_wins(
        State.noted(app, "#{name}: the URL is stored, but #{status.key_env} is set and wins over it"),
        name,
        status,
      )
    ok(status) if status.asks == Protocol.ASKS_URL ->
      lined(
        moved(app, name, "#{name} is set up at #{status.base_url}", status.made_default),
        name,
        status.made_default,
      )
    ok(status) if status.from == "env" ->
      env_wins(
        State.noted(app, "#{name}: the key is stored, but #{status.key_env} is set and wins over it"),
        name,
        status,
      )
    ok(status) ->
      said = "#{name} is set up (#{status.key_env} would also work)"
      lined(moved(app, name, said, status.made_default), name, status.made_default)
    error(e) -> State.noted(app, "error: #{e.message}")
  end

  ended(done, result.ok?)
end

## The end of a login: `finn login` exits with its status; the first-start offer is not made again.
def ended(done: State.Model, succeeded: Bool) -> State.Model
  return done.with(first_login: false) if not done.login_only
  return done.with(exit: some(0)) if succeeded

  done.with(exit: some(1))
end

## `finn login` ended by Esc: not a failure, so the status is 0, and the console says it.
def login_cancelled(app: State.Model) -> State.Model
  return login_closed(app) if not app.login_only

  app.with(exit: some(0), line: some("finn: login cancelled"))
end

## A first-start login closed with no key stores an empty key file, so it is offered once; `finn login` ends.
def login_closed(app: State.Model) -> State.Model
  return app.with(exit: some(1)) if app.login_only
  return app if not app.first_login

  _ = app.backend.skip_login.call()
  State.noted(app.with(first_login: false), "/login sets up a provider later")
end

def logout_command(app: State.Model, name: Optional[String]) -> Result[State.Model]
  try app.backend.logout.call(name)
  ok(State.noted(app, Client.logged_out(name)))
end

private

LOCAL = "local"
DEVICE_POLL_MS = 2000

# A session on `local` (the fallback of a first start) is offered the models of the provider just set up, in the
# picker: Enter moves it there from the next turn, Esc keeps it on `local`, which may be on purpose. Another session
# stays where it is; `said` then tells how to pick a model.
def moved(app: State.Model, name: String, said: String, made_default: Bool) -> State.Model
  return State.noted(app, "#{said}: /model lists its models") if app.login_only or app.id == ""
  return switched(app, name, said) if app.first_login and made_default and name != LOCAL and provider_of(app) == LOCAL

  case app.backend.list_providers.call()
    ok(list) ->
      own = list.providers.select { |p| p.name == name }
      models = own.flat_map { |p| p.models }
      return State.noted(app, "#{said}: /model #{name}/NAME picks one of its models") if models.empty?
      return State.noted(app, "#{said}: /model lists its models") if name == LOCAL or provider_of(app) != LOCAL

      shown = State.noted(app, "#{said}: pick a model of #{name}, or Esc to stay on #{LOCAL}")
      shown.with(picker: some(Picker.models(list.with(providers: own), "")))
    error(e) -> State.noted(State.noted(app, said), "error: #{e.message}")
  end
end

# The login made `name` the default provider: the session of the first start, which is on `local`, goes there too.
def switched(app: State.Model, name: String, said: String) -> State.Model
  models = case app.backend.list_providers.call()
    ok(list) -> list.providers.select { |p| p.name == name }.flat_map { |p| p.models }
    error(_) -> []
  end

  change = Protocol.UpdateSession(provider: some(name))
  if not models.empty?
    change = change.with(model: some(models[0]))
  end

  case app.backend.update_session.call(app.id, change)
    ok(_) ->
      case app.backend.session.call(app.id)
        ok(session) ->
          State.noted(
            app.with(serving: State.serving_of(session)),
            "#{said}: the session is on #{State.serving_of(session)} from the next turn",
          )
        error(e) -> State.noted(app, "#{said}: error: #{e.message}")
      end

    error(e) -> State.noted(app, "#{said}: /model #{name}/NAME picks a model (error: #{e.message})")
  end
end

# `finn login` when the environment's key (or URL) wins over the stored one: it says so, not that the login is in use.
def env_wins(app: State.Model, name: String, status: Protocol.LoginStatus) -> State.Model
  return app if not app.login_only

  app.with(line: some("finn: logged in to #{name}; #{status.key_env} is set in the environment and wins over it"))
end

# What `finn login` prints once the screen is closed.
def lined(app: State.Model, name: String, made_default: Bool) -> State.Model
  return app if not app.login_only

  text = "finn: logged in to #{name}"
  if made_default
    text = "#{text}; run `finn` to start"
  elsif name != LOCAL
    text = "#{text}; use `finn --provider #{name}`, or /model, to use it"
  end

  app.with(line: some(text))
end

def provider_of(app: State.Model) -> String = app.serving.split("/")[0]

def named_from_server(app: State.Model, name: String) -> Result[State.Model]
  ok(named_login(app, (try app.backend.list_logins.call()).providers, name))
end

def login_picking(app: State.Model) -> Result[State.Model]
  ok(app.with(picker: some(Picker.logins(try app.backend.list_logins.call()))))
end

# A name that is no login is not shown again: it may be a key typed in the wrong place.
def named_login(app: State.Model, logins: List[Protocol.LoginStatus], name: String) -> State.Model
  found = logins.select { |l| l.name == name }
  return login_closed(State.noted(app, "no login has that name: /login lists them")) if found.empty?
  return login_closed(State.noted(app, "#{found[0].label}: coming, there is no login for it yet")) if found[0].coming

  return device_login(app, name) if found[0].asks == Protocol.ASKS_DEVICE

  if found[0].asks == Protocol.ASKS_URL
    asked = app.with(key_for: some(name), secret: "", asking_url: true)
    return State.noted(
      asked,
      "the base URL of #{name} (now #{found[0].base_url}), as http://127.0.0.1:8080/v1: Enter checks it, Esc cancels",
    )
  end

  asking(app, name)
end

# A new device login drops the polls of one that still waits.
def device_login(app: State.Model, name: String) -> State.Model
  backend = app.backend
  serial = app.device_serial + 1
  starting = State.noted(app.with(device: none, device_serial: serial), "starting the login of #{name}")
  State.effect(starting, TUI.Cmd.Run(-> { State.Msg.DeviceStarted(name, serial, backend.device_start.call(name)) }))
end

def poll(app: State.Model, name: String, serial: Int) -> TUI.Cmd[State.Msg]
  backend = app.backend
  TUI.Cmd.Run(
    -> {
      Task.sleep(DEVICE_POLL_MS)
      State.Msg.DevicePolled(name, serial, backend.device_state.call(name))
    },
  )
end

def asking(app: State.Model, name: String) -> State.Model
  State.noted(
    app.with(key_for: some(name), secret: ""),
    "the key of #{name}: typed hidden, Enter checks it, Esc cancels",
  )
end
