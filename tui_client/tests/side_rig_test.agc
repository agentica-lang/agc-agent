# The side panel on a fake terminal (TUI.Testing): it opens and closes at a wide and at a narrow width, and the
# open log
# shows a line the server writes after it. In a file of its own: `terminal_test` is near its step budget.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import App from "../src/app"
import Args from "../src/args"
import Transcript from "../src/transcript"

LOG = ["10:00:00 INFO started", "10:00:01 WARNING bad skill"]
LATER = "10:00:02 INFO a line that came later"

type Log = ATS[String, List[String]]

# Runs the app at `width` by `height` with a transcript of one answer and a server whose log is in `cell`.
def within(width: Int, height: Int, body: Fn[TUI.Testing.Fake, Log, Result[Void]]) -> Result[Void]
  cell: Log = ATS.new()
  cell.put("log", LOG)
  options = Args.Options(
    state_dir: none,
    server_command: none,
    session: none,
    cwd: none,
    model: none,
    api: none,
    thinking: false,
  )

  log_of = ->(_count: Int) {
    ok(Protocol.ServerLog(lines: cell.get("log").unwrap_or([]), warnings: [], warning_count: 0))
  }

  said = [
    Protocol.Message(role: Protocol.Role.User, text: "question"),
    Protocol.Message(role: Protocol.Role.Assistant, text: "the answer"),
  ]

  backend = Client.unreachable_backend().with(server_log: log_of)
  model = App.seed(backend, options, Channel.new(1), width, height).with(
    id: "s1",
    entries: Transcript.from_history(said),
  )

  fake = TUI.Testing.fake(width, height)
  runner = Task.spawn(-> { App.drive(TUI.Testing.backend(fake), model) })
  result = body.call(fake, cell)
  _ = fake.events.send(TUI.Event.Key(TUI.Key.Ctrl("c"), TUI.Mods()), 1000)
  _ = Task.await(runner)
  result
end

def shows(fake: TUI.Testing.Fake, text: String) -> Result[List[String]]
  TUI.Testing.wait_for(fake, ->(rows: List[String]) { rows.any? { |row| row.include?(text) } })
end

def gone(fake: TUI.Testing.Fake, text: String) -> Result[List[String]]
  TUI.Testing.wait_for(fake, ->(rows: List[String]) { not rows.any? { |row| row.include?(text) } })
end

def typed(fake: TUI.Testing.Fake, text: String) -> Result[Void]
  for char in text.split("")
    try fake.events.send(TUI.Event.Char(char, TUI.Mods()), 1000)
  end

  fake.events.send(TUI.Event.Key(TUI.Key.Enter, TUI.Mods()), 1000)
end

def escape(fake: TUI.Testing.Fake) -> Result[Void] = fake.events.send(TUI.Event.Key(TUI.Key.Escape, TUI.Mods()), 1000)

# At 120 columns `/logs` opens the panel beside the transcript, which keeps its place; a line the server writes later
# comes into the panel (the log is read again every second: that wait is the behavior under test); Esc closes it.
def test_the_log_opens_beside_the_transcript_follows_the_server_and_closes() -> Result[Void] = within(100, 9, &wide)

def wide(fake: TUI.Testing.Fake, cell: Log) -> Result[Void]
  try shows(fake, "the answer")
  try typed(fake, "/logs")
  rows = try shows(fake, "WARNING bad skill")
  answer = rows.find { |row| row.include?("the answer") }.unwrap!
  try Test.assert(answer.index_of("the answer").unwrap! < answer.index_of("│").unwrap!, answer)
  cell.put("log", LOG + [LATER])
  try shows(fake, "a line that came later")
  try escape(fake)
  _ = try gone(fake, "WARNING bad skill")
  try shows(fake, "the answer")
  ok()
end

# At 80 columns the panel takes the transcript's place, and Esc gives the transcript back.
def test_the_log_covers_the_transcript_on_a_narrow_screen_until_esc() -> Result[Void] = within(60, 9, &narrow)

def narrow(fake: TUI.Testing.Fake, _cell: Log) -> Result[Void]
  try shows(fake, "the answer")
  try typed(fake, "/logs")
  rows = try shows(fake, "WARNING bad skill")
  try Test.assert(not rows.any? { |row| row.include?("the answer") }, rows.join("\n"))
  try escape(fake)
  _ = try gone(fake, "WARNING bad skill")
  try shows(fake, "the answer")
  ok()
end
