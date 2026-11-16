import Protocol from "pkg/protocol/protocol"
import H from "support/harness"

EVENTS = 1000
CHUNK = 500
WAIT_MS = 30_000

# Session files load in tasks, which the test holds at a gate, so no timing decides the outcome. While "big" waits,
# the list and a new session answer, and "gone" starts its own load: loads do not wait for each other. Two requests for
# "big" make one load and get one session, whose cut turn ends once. A session deleted while it loads stays deleted,
# its file too, once its load has ended.
def test_a_big_session_loads_without_blocking_the_others() -> Result[Void]
  entered: Channel[String] = Channel.new(4)
  gate: Channel[Bool] = Channel.new(4)
  ended: Channel[String] = Channel.new(4)
  hold = ->(id: String) {
    _ = entered.send(id, WAIT_MS)
    _ = gate.recv(WAIT_MS)
  }

  setup = H.Setup(
    replies: [],
    before_load: some(hold),
    after_load: some(->(id: String) { _ = ended.send(id, WAIT_MS) }),
  )

  H.using(setup) do |h|
    try write_session(H.session_file(h, "big"), "big", h.work, "\n")
    try write_session(H.session_file(h, "gone"), "gone", h.work, "")
    H.restarted(h, setup, "") do |r|
      try held(r, entered, gate)
      try ended_once(r, ended)
      Test.eq(entered.recv(0).ok?, false)
    end
  end
end

private

def held(r: H.Harness, entered: Channel[String], gate: Channel[Bool]) -> Result[Void]
  big = Protocol.session_path("big")
  first = Task.spawn do status(H.get(r, big)) end
  second = Task.spawn do status(H.get(r, big)) end
  try Test.eq(entered.recv(WAIT_MS), ok("big"))
  listed = try H.get(r, Protocol.SESSIONS_PATH)
  created = try H.new_session(r)
  try Test.eq([listed.status.to_s, created.empty?.to_s], ["200", "false"])
  gone = Protocol.session_path("gone")
  loading = Task.spawn do status(H.get(r, gone)) end
  try Test.eq(entered.recv(WAIT_MS), ok("gone"))
  try Test.eq(waiting?(first) and waiting?(second), true)
  deleted = try H.call(r, "DELETE", gone, "", H.auth(r))
  try Test.eq(deleted.status, 200)
  try Test.eq(Task.await(loading), 404)
  try gate.send(true, 0)
  try gate.send(true, 0)
  Test.eq([Task.await(first), Task.await(second)], [200, 200])
end

# After both loads ended and the registry took what they read (a list goes after it), "gone" is still deleted.
def ended_once(r: H.Harness, ended: Channel[String]) -> Result[Void]
  done = [try ended.recv(WAIT_MS), try ended.recv(WAIT_MS)]
  try Test.eq(done.sort, ["big", "gone"])
  _ = try H.get(r, Protocol.SESSIONS_PATH)
  try Test.eq(File.stat(H.session_file(r, "gone")).ok?, false)
  try Test.eq(status(H.get(r, Protocol.session_path("gone"))), 404)
  turns = try File.foreach(H.session_file(r, "big")).select { |line| line.include?("turn_finished") }.to_a
  Test.eq(turns.size, 1)
end

def waiting?(request: Task[Int]) -> Bool
  case Task.await(request, 1)
    Await.TimedOut -> true
    Await.Done(_) -> false
  end
end

def status(answer: Result[H.Answer]) -> Int
  case answer
    ok(got) -> got.status
    error(_) -> 0
  end
end

# A turn that a restart cut, with many saved events, and a last line that a crash cut, then `tail`.
def write_session(path: String, id: String, cwd: String, tail: String) -> Result[Void]
  head = "{\"type\":\"session\",\"id\":\"#{id}\",\"cwd\":\"#{cwd}\",\"model\":\"m\",\"created_ms\":1}\n"
  user = "{\"type\":\"user\",\"text\":\"go\"}\n"
  started = "{\"type\":\"event\",\"id\":1,\"name\":\"turn_started\",\"data\":{\"turn_id\":\"turn-1\"}}\n"
  data = "{\"call_id\":\"c\",\"name\":\"bash\",\"summary\":\"make test\"}"
  tool = "{\"type\":\"event\",\"id\":2,\"name\":\"tool_started\",\"data\":#{data}}\n"
  try File.write_text(path, "#{head}#{user}#{started}")
  for _ in 1..(EVENTS / CHUNK)
    try File.append_text(path, tool * CHUNK)
  end

  File.append_text(path, "{\"type\":\"event\",\"id\":3#{tail}")
end
