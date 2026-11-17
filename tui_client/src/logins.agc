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
      login_closed(State.noted(app.with(key_for: none, secret: "", asking_url: false), "no URL given"))
    TUI.Event.Key(TUI.Key.Escape, _) -> login_closed(State.noted(app.with(key_for: none, secret: ""), "no key given"))
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

def logged_in(app: State.Model, name: String, result: Result[Protocol.LoginStatus]) -> State.Model
  done = case result
    ok(status) if status.asks == Protocol.ASKS_URL and status.from == "env" ->
      State.noted(app, "#{name}: the URL is stored, but #{status.key_env} is set and wins over it")
    ok(status) if status.asks == Protocol.ASKS_URL -> moved(app, name, "#{name} is set up at #{status.base_url}")
    ok(status) if status.from == "env" ->
      State.noted(app, "#{name}: the key is stored, but #{status.key_env} is set and wins over it")
    ok(status) -> moved(app, name, "#{name} is set up (#{status.key_env} would also work)")
    error(e) -> State.noted(app, "error: #{e.message}")
  end

  return done.with(first_login: false) if not app.login_only
  return done.with(exit: some(0)) if result.ok?

  done.with(exit: some(1))
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

# A session on `local` (the fallback of a first start) moves to the provider just set up: on its only model, else the
# picker shows its models (Esc stays). Another session stays where it is; `said` then tells how to pick a model.
def moved(app: State.Model, name: String, said: String) -> State.Model
  return State.noted(app, "#{said}: /model lists its models") if app.login_only or app.id == ""

  case app.backend.list_providers.call()
    ok(list) ->
      own = list.providers.select { |p| p.name == name }
      models = own.flat_map { |p| p.models }
      return State.noted(app, "#{said}: /model #{name}/NAME picks one of its models") if models.empty?
      return State.noted(app, "#{said}: /model lists its models") if name == LOCAL or provider_of(app) != LOCAL

      if models.size > 1
        shown = State.noted(app, "#{said}: pick a model of #{name}, or Esc to stay on #{LOCAL}")
        return shown.with(picker: some(Picker.models(list.with(providers: own), "")))
      end

      State.tried(app, switched(app, name, models[0], said))
    error(e) -> State.noted(State.noted(app, said), "error: #{e.message}")
  end
end

def switched(app: State.Model, name: String, model: String, said: String) -> Result[State.Model]
  try app.backend.update_session.call(app.id, Protocol.UpdateSession(provider: some(name), model: some(model)))
  session = try app.backend.session.call(app.id)
  shown = State.noted(app, "#{said}: #{name}/#{model} from the next turn")
  ok(shown.with(serving: State.serving_of(session), new_model: some(model)))
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

  if found[0].asks == Protocol.ASKS_URL
    asked = app.with(key_for: some(name), secret: "", asking_url: true)
    return State.noted(
      asked,
      "the base URL of #{name} (now #{found[0].base_url}), as http://127.0.0.1:8080/v1: Enter checks it, Esc cancels",
    )
  end

  asking(app, name)
end

def asking(app: State.Model, name: String) -> State.Model
  State.noted(
    app.with(key_for: some(name), secret: ""),
    "the key of #{name}: typed hidden, Enter checks it, Esc cancels",
  )
end
