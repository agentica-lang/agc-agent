## A server for the tests of the start path: `--server-command` runs this program. It serves the idle session `s1`,
## holds `core.lock` of the state folder as the core does, writes `server.json` there, notes each start in `starts.log`,
## prints `ready`, and exits when `server.json` is removed (or after a minute, if a test died). `FAKE_HEALTH_VERSION`
## makes its health check say that version and no wire digest (a server of another protocol); `FAKE_HEALTH_STATUS`
## makes it fail with that status.

import Protocol from "pkg/protocol/protocol"
import Fake from "fake_server"

STATE_DIR_ENV = "FINN_STATE_DIR"
HEALTH_ANSWERS = 16
DEADLINE_MS = 60_000
POLL_MS = 200

def main() -> Void
  dir = System.env(STATE_DIR_ENV).unwrap!
  serve(dir).unwrap!
end

private

def serve(dir: String) -> Result[Void]
  idle = Fake.Reply(session: "session_idle.json")
  stream = Fake.Reply(hold: true)
  fake = try Fake.start(
    [
      Fake.Route(method: "GET", path: Protocol.session_path("s1"), replies: [idle, idle]),
      Fake.Route(method: "GET", path: Protocol.events_path("s1"), replies: [stream, stream]),
    ] +
    health_routes(),
  )

  # Held until the program ends; a second fake in the folder goes on without it.
  lock = try File.open(try Path.join([dir, "core.lock"]), "append")
  _ = File.try_lock(lock, POLL_MS)
  file = try Path.join([dir, "server.json"])
  try File.append_text(try Path.join([dir, "starts.log"]), "started\n")
  _ = Path.remove(file)
  try Fake.write_private(file, Fake.server_file(fake, Fake.TOKEN))
  puts("ready")
  IO.flush()
  waited = 0
  while waited < DEADLINE_MS and File.stat(file).ok?
    Task.sleep(POLL_MS)
    waited = waited + POLL_MS
  end

  _ = File.close(lock)
  Fake.stop(fake)
end

def health_routes() -> List[Fake.Route]
  replies: List[Fake.Reply] = []
  for _ in 1..HEALTH_ANSWERS
    for reply in option_list(health_reply())
      replies = replies.push(reply)
    end
  end

  return [] if replies.empty?

  [Fake.Route(method: "GET", path: Protocol.HEALTH_PATH, replies: replies)]
end

def health_reply() -> Optional[Fake.Reply]
  case System.env("FAKE_HEALTH_STATUS")
    ok(status) -> return some(Fake.Reply(status: status.to_i.unwrap_or(500), body: "{}"))
    error(_) -> nil
  end

  case System.env("FAKE_HEALTH_VERSION")
    ok(version) -> some(Fake.Reply(body: "{\"version\": \"#{version}\"}"))
    error(_) -> none
  end
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
