# Shift+Tab goes through the profiles, and Enter on `/profile ` picks a profile and never runs the bare command.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import App from "../src/app"
import Args from "../src/args"

# Shift+Tab: build, plan, the user's profiles by name, build again; a profile that does not load is skipped; a
# turn that
# runs refuses it with a note, and the thinking level is F2 now.
def test_shift_tab_goes_through_the_profiles() -> Result[Void]
  chosen: Channel[String] = Channel.new(16)
  backend = profiles_backend(chosen, ["ro", "plan", "broken", "build", "alpha"])
  model = model_of().with(backend: backend, id: "s1")
  seen: List[String] = []
  for _ in 0...5
    model = App.update(model, back_tab()).model
    seen = seen.push(model.profile)
  end

  try Test.eq(seen, ["plan", "alpha", "ro", "", "plan"])
  try Test.eq(drain(chosen), ["plan", "alpha", "ro", "build", "plan"])
  try Test.assert(model.entries.last.text.include?("profile plan from the next turn"), model.entries.last.text)

  running = App.update(model.with(turn: true), back_tab()).model
  try Test.eq(running.profile, "plan")
  try Test.eq(drain(chosen), [])
  try Test.assert(running.entries.last.text.include?("a turn is running"), running.entries.last.text)
  levelled = App.update(model, back_tab())
  try Test.eq(levelled.model.effort, none)
  Test.eq(App.update(model, f2()).model.effort, some("low"))
end

# `/prof` and Enter completes the name; Enter again before the server listed the profiles waits, as do Up and Down, and
# once the list is there Enter runs the profile of its row. The bare `/profile` is never run, so no panel opens.
def test_enter_on_the_profile_list_picks_a_profile_and_never_runs_the_bare_command() -> Result[Void]
  chosen: Channel[String] = Channel.new(16)
  model = model_of().with(
    backend: profiles_backend(chosen, ["build", "plan", "alpha"]),
    id: "s1",
    prompt: "/prof",
    cursor: 5,
  )

  completed = App.update(model, enter())
  try Test.eq(completed.model.prompt, "/profile ")
  try Test.eq(completed.cmds.size, 1)
  try Test.eq(drain(chosen), [])
  for key in [enter(), down(), up(), enter()]
    waiting = App.update(completed.model, key)
    try Test.eq(waiting.model.prompt, "/profile ")
    try Test.eq([waiting.model.side.none?, waiting.cmds.empty?], [true, true])
  end

  try Test.eq(drain(chosen), [])
  listed = App.update(completed.model, run(completed.cmds[0])[0]).model
  picked = App.update(listed, enter())
  try Test.eq(picked.model.profile, "")
  try Test.eq(picked.model.side.none?, true)
  try Test.eq(drain(chosen), ["build"])
  moved = App.update(App.update(listed, down()).model, enter()).model
  try Test.eq(moved.profile, "plan")
  try Test.eq(moved.side.none?, true)
  try Test.eq(drain(chosen), ["plan"])
  # A list that failed does not hold Enter: the line is sent as typed.
  failed = App.update(completed.model, App.Msg.Arguments(completed.model.opened, "/profile", error("down")))
  sent = App.update(failed.model, enter()).model
  Test.eq(sent.side.some?, true)
end

# A server that lists `names` as its profiles (`broken` does not load) and keeps the one chosen.
def profiles_backend(chosen: Channel[String], names: List[String]) -> Client.Backend
  listed = Protocol.ProfileList(profiles: names.map { |name| Protocol.Profile(name: name, source: source_of(name)) })

  current: Channel[String] = Channel.new(1)
  _ = current.send("build", 0)
  Client.unreachable_backend().with(
    list_profiles: ->(_id: String) { ok(listed) },
    update_session: ->(_id: String, change: Protocol.UpdateSession) {
      name = change.profile.unwrap_or("")
      _ = chosen.send(name, 0)
      _ = current.recv(0)
      _ = current.send(name, 0)
      ok()
    },
    session: ->(_id: String) {
      name = current.recv(0).unwrap_or("build")
      _ = current.send(name, 0)
      ok(
        Protocol.Session(
          id: "s1",
          cwd: ".",
          model: "m",
          last_event_id: 0,
          turn_id: none,
          turn_from_event_id: none,
          pending_approvals: [],
          history: [],
          provider: "local",
          profile: some(Protocol.Profile(name: name, source: "built-in")),
        ),
      )
    },
  )
end

def source_of(name: String) -> String
  return "" if name == "broken"

  "user"
end

def drain(chosen: Channel[String]) -> List[String]
  out: List[String] = []
  while true
    case chosen.recv(0)
      ok(name) -> out = out.push(name)
      error(_) -> break
    end
  end

  out
end

def model_of() -> App.Model
  options = Args.Options(
    state_dir: none,
    server_command: none,
    session: none,
    cwd: none,
    model: none,
    api: none,
    thinking: false,
  )

  App.seed(Client.unreachable_backend(), options, Channel.new(1), 80, 20)
end

def back_tab() -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.BackTab, TUI.Mods()))

def f2() -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.F(2), TUI.Mods()))

def enter() -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.Enter, TUI.Mods()))

def down() -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.Down, TUI.Mods()))

def up() -> App.Msg = App.Msg.Key(TUI.Event.Key(TUI.Key.Up, TUI.Mods()))

def run(cmd: TUI.Cmd[App.Msg]) -> List[App.Msg]
  case cmd
    TUI.Cmd.Run(work) -> [work.call()]
    _ -> []
  end
end
