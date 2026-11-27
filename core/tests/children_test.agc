## Child sessions (`Core.Host`): an extension tool starts sessions of its own on any provider, sends to them, watches
## them, and stops and deletes them. The server's list hides them, and their files live in memory, so none stays.
## Each turn here runs alone, so the fake's replies go in order.

import Protocol from "pkg/protocol/protocol"
import Core from "../core"
import Fake from "support/fake_llm"
import H from "support/harness"

## The answer of `text.sse`.
ANSWER = "Hello! It's a pleasure to meet you."

# A child on `other` answers, and `watch` sees its `turn_finished` with its parent. Its answer wakes the parent, and
# the child's handle starts nothing.
def test_a_child_on_another_provider_answers_and_wakes_its_parent() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "spawn.sse", "text.sse", "text.sse"]
  setup = H.Setup(replies: replies, providers: ["other"], registry: some(with_spawn(calls)), approvals: false)
  H.using(setup) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    host = try host_of(calls)
    seen: Channel[Core.Seen] = Channel.new(4)
    child = try host.create.call(Core.NewChild(provider: some("other"), model: some("m1")))
    try host.watch.call(child, ["turn_finished"], ->(event: Core.Seen) { _ = seen.send(event, 0) })
    b = try H.subscribe(h, parent)
    _ = try host.send.call(child, "Say hi.")
    finished = try seen.recv(5000)
    try Test.eq([finished.session, finished.name], [child, "turn_finished"])
    try Test.eq(finished.parent, some(parent))
    _ = try host.send.call(parent, "#{child} said: #{ANSWER}")
    b = try H.until(b, Protocol.EventKind.TurnFinished)
    H.close(b)
    paths: List[String] = []
    for _i in 1..5
      paths = paths.push(path_of(H.next_request(h)))
    end

    try Test.eq(paths.map { |path| path.start_with?("/other/") }, [false, false, true, true, false])
    texts = H.said((try H.session(h, parent)).history).map { |m| m.text }
    try Test.assert(texts.include?("#{child} said: #{ANSWER}"), "the parent was not woken")
    child_call = try calls.recv(0)
    try Test.eq(child_call.session, some(child))
    refused = (try host_of_call(child_call)).create.call(Core.NewChild())
    try Test.eq(kind_of(refused), Protocol.KIND_INVALID)
    listed = (try H.get(h, Protocol.SESSIONS_PATH)).text
    Test.assert(listed.include?(parent) and not listed.include?(child), "the list: #{listed}")
  end
end

# A stranger's sessions are not found on every function that names one, and a host whose session is gone starts
# nothing.
def test_a_stranger_is_not_found_on_every_function() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "spawn.sse", "text.sse"]
  H.using(H.Setup(replies: replies, registry: some(with_spawn(calls)), approvals: false)) do |h|
    parent = try H.new_session(h)
    stranger = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    b = try H.subscribe(h, stranger)
    _ = try H.send(h, stranger, "Go.")
    b = try H.until(b, Protocol.EventKind.TurnFinished)
    H.close(b)
    host = try host_of(calls)
    other = try host_of(calls)
    child = try other.create.call(Core.NewChild())
    for id in [stranger, child]
      try Test.eq(kind_of(host.send.call(id, "Hi.")), Protocol.KIND_SESSION_NOT_FOUND)
      try Test.eq(kind_of(host.stop.call(id)), Protocol.KIND_SESSION_NOT_FOUND)
      try Test.eq(kind_of(host.delete.call(id)), Protocol.KIND_SESSION_NOT_FOUND)
      try Test.eq(kind_of(host.snapshot.call(id)), Protocol.KIND_SESSION_NOT_FOUND)
      try Test.eq(
        kind_of(host.watch.call(id, ["turn_finished"], ->(_seen: Core.Seen) { nil })),
        Protocol.KIND_SESSION_NOT_FOUND,
      )
    end

    gone = try other.create.call(Core.NewChild())
    try Test.eq((try H.call(h, "DELETE", Protocol.session_path(parent), "", H.auth(h))).status, 200)
    try Test.eq(kind_of(host.create.call(Core.NewChild())), Protocol.KIND_SESSION_NOT_FOUND)
    Test.eq(kind_of(host.snapshot.call(gone)), Protocol.KIND_SESSION_NOT_FOUND)
  end
end

# A child takes its parent's profile when it names none, and its profile never widens it past its parent.
def test_a_child_never_shows_more_than_its_parent() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "spawn.sse", "text.sse", "text.sse"]
  setup = H.Setup(replies: replies, registry: some(with_spawn(calls)), approvals: false, profiles: true)
  H.using(setup) do |h|
    dir = "#{h.base}/config/finn/profiles"
    try write("#{dir}/reader.md", "---\ntools_deny: [write_file]\n---\n")
    try write("#{dir}/writer.md", "---\ntools_allow: [write_file, spawn]\n---\n")
    parent = try H.new_session_in(h, h.work, profile: some("reader"))
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    host = try host_of(calls)
    child = try host.create.call(Core.NewChild())
    _ = try host.send.call(child, "Go.")
    _ = try calls.recv(5000)
    first = names(try H.next_request(h))
    try Test.eq([first.include?("spawn"), first.include?("write_file")], [true, false])
    try Test.eq((try host.snapshot.call(child)).profile.map { |p| p.name }, some("reader"))
    wider = try host.create.call(Core.NewChild(profile: some("writer")))
    _ = try host.send.call(wider, "Go.")
    second = names(try H.next_request(h))
    Test.eq([second.include?("spawn"), second.include?("write_file")], [true, false])
  end
end

# `NewChild(profile:)` runs the profile's model, on its provider; without one the child takes its parent's.
def test_a_child_runs_its_profile_model() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "spawn.sse", "text.sse", "text.sse", "text.sse"]
  setup = H.Setup(
    replies: replies,
    providers: ["other"],
    registry: some(with_spawn(calls)),
    approvals: false,
    profiles: true,
  )

  H.using(setup) do |h|
    dir = "#{h.base}/config/finn/profiles"
    try write("#{dir}/fast.md", "---\ndescription: quick\nmodel: other/small\n---\n")
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    host = try host_of(calls)
    reference = try H.session(h, parent)
    child = try host.create.call(Core.NewChild(profile: some("fast")))
    started = try host.snapshot.call(child)
    try Test.eq([started.provider, started.model], ["other", "small"])
    plain = try host.create.call(Core.NewChild())
    same = try host.snapshot.call(plain)
    try Test.eq([same.provider, same.model], [reference.provider, reference.model])
    c = try H.subscribe(h, child)
    _ = try host.send.call(child, "Go.")
    c = try H.until(c, Protocol.EventKind.TurnFinished)
    H.close(c)
    paths: List[String] = []
    for _i in 1..4
      paths = paths.push(path_of(H.next_request(h)))
    end

    try Test.eq(paths.map { |path| path.start_with?("/other/") }, [false, false, true, true])
    _ = try host.send.call(plain, "Go.")
    _ = try H.next_request(h)
    Test.eq(path_of(H.next_request(h)).start_with?("/other/"), false)
  end
end

# A delete of the parent removes a child mid-turn first, and the child's watchers hear `parent_ended`.
def test_a_parent_delete_removes_a_child_mid_turn_first() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  ended: Channel[Core.Seen] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "text.sse@hold"]
  H.using(H.Setup(replies: replies, registry: some(with_watched(calls, ended)), approvals: false)) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    host = try host_of(calls)
    child = try host.create.call(Core.NewChild())
    c = try H.subscribe(h, child)
    _ = try host.send.call(child, "More.")
    c = try H.until(c, Protocol.EventKind.TurnStarted)
    try Test.eq((try H.call(h, "DELETE", Protocol.session_path(parent), "", H.auth(h))).status, 200)
    H.close(c)
    try Test.eq((try H.get(h, Protocol.session_path(child))).status, 404)
    try Test.eq((try H.get(h, Protocol.session_path(parent))).status, 404)
    try Test.assert(not File.read_text(H.session_file(h, child)).ok?, "the child's file stays")
    try Test.assert(not File.read_text(H.session_file(h, parent)).ok?, "the parent's file stays")
    first = try ended.recv(5000)
    second = try ended.recv(5000)
    try Test.eq(
      [first.session, reason_of(first), second.session, reason_of(second)],
      [parent, "deleted", child, "parent_ended"],
    )

    Test.eq([first.parent, second.parent], [none, some(parent)])
  end
end

# After a restart no child is listed, and a delete of its parent still works: the child is simply gone.
def test_a_restart_leaves_no_child() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse"]
  setup = H.Setup(replies: replies, registry: some(with_spawn(calls)), approvals: false)
  H.using(setup) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    host = try host_of(calls)
    child = try host.create.call(Core.NewChild())
    H.restarted(h, setup, "") do |r|
      listed = (try H.get(r, Protocol.SESSIONS_PATH)).text
      try Test.assert(listed.include?(parent) and not listed.include?(child), "the list: #{listed}")
      try Test.eq((try H.get(r, Protocol.session_path(child))).status, 404)
      Test.eq((try H.call(r, "DELETE", Protocol.session_path(parent), "", H.auth(r))).status, 200)
    end
  end
end

# A stop for a turn that is not running stops nothing: the child's turn runs on.
def test_a_stale_turn_id_stop_leaves_the_child_running() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "text.sse@hold"]
  H.using(H.Setup(replies: replies, registry: some(with_spawn(calls)), approvals: false)) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    host = try host_of(calls)
    child = try host.create.call(Core.NewChild())
    c = try H.subscribe(h, child)
    _ = try host.send.call(child, "More.")
    c = try H.until(c, Protocol.EventKind.TurnStarted)
    stopped = try Protocol.decode_stopped((try H.post(h, Protocol.stop_path(parent), "{\"turn_id\": \"stale\"}")).text)

    try Test.eq(stopped.stopped, false)
    try Test.assert((try H.session(h, child)).turn_id.some?, "the child's turn stopped")
    H.release(h)
    c = try H.until(c, Protocol.EventKind.TurnFinished)
    H.close(c)
    try Test.eq(H.stop_reason(c), "end_turn")
    Test.assert(
      H.said((try H.session(h, child)).history).map { |m| m.text }.include?(ANSWER),
      "the child did not answer",
    )
  end
end

# An answer of the child's own watcher deletes it at once: closing the watcher never waits for its task.
def test_answer_then_delete_from_the_child_watcher_returns_at_once() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "spawn.sse", "text.sse", "text.sse"]
  H.using(H.Setup(replies: replies, registry: some(with_spawn(calls)), approvals: false)) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    host = try host_of(calls)
    done: Channel[Bool] = Channel.new(1)
    child = try host.create.call(Core.NewChild())
    try host.watch.call(
      child,
      ["turn_finished"],
      ->(seen: Core.Seen) {
        text = case host.snapshot.call(seen.session)
          ok(session) -> H.said(session.history).map { |m| m.text }.last
          error(_) -> ""
        end

        _ = host.send.call(parent, "#{seen.session} said: #{text}")
        _ = host.delete.call(seen.session)
        _ = done.send(true, 0)
      },
    )

    b = try H.subscribe(h, parent)
    _ = try host.send.call(child, "Say hi.")
    try Test.eq(done.recv(5000), ok(true))
    b = try H.until(b, Protocol.EventKind.TurnFinished)
    H.close(b)
    try Test.eq((try H.get(h, Protocol.session_path(child))).status, 404)
    texts = H.said((try H.session(h, parent)).history).map { |m| m.text }
    Test.assert(texts.include?("#{child} said: #{ANSWER}"), "no wake")
  end
end

private

def with_spawn(calls: Channel[Core.Call]) -> Core.Registry = Core.registry() |> Core.add_tool(spawn_tool(calls))

def with_watched(calls: Channel[Core.Call], ended: Channel[Core.Seen]) -> Core.Registry
  (
    Core.registry()
    |> Core.add_tool(spawn_tool(calls))
    |> Core.on(Core.Event.Seen(["session_ended"], ->(seen: Core.Seen) { _ = ended.send(seen, 0) }))
  )
end

# A tool that gives the test the call, with its handle.
def spawn_tool(calls: Channel[Core.Call]) -> Core.Tool
  Core.Tool(
    name: "spawn",
    description: "Gives the test its call.",
    input_schema: JSON.object({"type": JSON.from("object")}),
    asks: false,
    run: ->(call: Core.Call) {
      _ = calls.send(call, 1000)
      ok("ok")
    },
    target: ->(_call: Core.Call) { ok("") },
  )
end

def host_of(calls: Channel[Core.Call]) -> Result[Core.Host] = host_of_call(try calls.recv(5000))

def host_of_call(call: Core.Call) -> Result[Core.Host] = call.host.to_result("the call has no host")

def reason_of(seen: Core.Seen) -> String
  JSON.string(JSON.get(seen.data, "reason").unwrap_or(JSON.from(""))).unwrap_or("")
end

def names(request: Fake.Seen) -> List[String]
  json = JSON.parse(request.body).unwrap_or(JSON.object({}))
  listed: List[JSON.Value] = JSON.list(JSON.get(json, "tools").unwrap_or(JSON.array([]))).unwrap_or([])
  listed.map { |tool| name_of(tool) }
end

def name_of(tool: JSON.Value) -> String
  case JSON.get(tool, "name")
    ok(name) -> return JSON.string(name).unwrap_or("")
    error(_) -> nil
  end

  case JSON.get(tool, "function")
    ok(function) -> JSON.string(JSON.get(function, "name").unwrap_or(JSON.from(""))).unwrap_or("")
    error(_) -> ""
  end
end

def path_of(seen: Result[Fake.Seen]) -> String
  case seen
    ok(request) -> request.path
    error(_) -> ""
  end
end

def kind_of[T](result: Result[T]) -> String
  case result
    ok(_) -> "ok"
    error(e) -> e.kind
  end
end

def write(path: String, text: String) -> Result[Void]
  try mkdirs(path.slice(0, path.length - path.split("/").last.length - 1))
  File.write_text(path, text)
end

def mkdirs(dir: String) -> Result[Void]
  return ok() if File.stat(dir).ok?

  try mkdirs(dir.slice(0, dir.length - dir.split("/").last.length - 1))
  Dir.mkdir(dir)
end
