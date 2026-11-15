## A server for the tests of the start path: `--server-command` runs this program. It serves the idle session `s1`,
## writes `server.json` in the state folder, notes each start in `starts.log` there, and exits when `server.json` is
## removed (or after a minute, if a test died).

import Protocol from "pkg/protocol/protocol"
import Fake from "fake_server"

STATE_DIR_ENV = "AGC_AGENT_STATE_DIR"
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
  fake = try Fake.start([
    Fake.Route(method: "GET", path: Protocol.session_path("s1"), replies: [idle, idle]),
    Fake.Route(method: "GET", path: Protocol.events_path("s1"), replies: [stream, stream]),
  ])

  file = try Path.join([dir, "server.json"])
  try File.append_text(try Path.join([dir, "starts.log"]), "started\n")
  try Fake.write_private(file, Fake.server_file(fake, Fake.TOKEN))
  waited = 0
  while waited < DEADLINE_MS and File.stat(file).ok?
    Task.sleep(POLL_MS)
    waited = waited + POLL_MS
  end

  Fake.stop(fake)
end
