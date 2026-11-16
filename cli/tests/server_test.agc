# `finn server` against the real core: start, status, logs, restart and stop of the server of a state folder.

import Protocol from "pkg/protocol/protocol"
import Args from "../src/args"
import Driver from "support/driver"

def test_the_server_is_started_asked_restarted_and_stopped() -> Result[Void] = Driver.within_dir(&lifecycle)

def lifecycle(dir: String) -> Result[Void]
  command = try Driver.core_command()
  result = steps(dir, command)
  # A server that is left after a failed step goes with the test.
  case File.read_text("#{dir}/server.json")
    ok(text) ->
      case Protocol.decode_server_info(text)
        ok(info) -> _ = System.signal(info.pid, System.Signal.Term, "agentica")
        error(_) -> nil
      end

    error(_) -> nil
  end

  result
end

def steps(dir: String, command: List[String]) -> Result[Void]
  none_yet = try run(dir, ["status"])
  try Test.eq(none_yet.code, 1)
  try Test.assert(none_yet.lines[0].start_with?("no server runs"), "status says none: #{none_yet.lines}")

  started = try run(dir, ["start"], command)
  try Test.assert(started.code == 0, "start: #{started.errors}")
  try Test.assert(started.lines[0].start_with?("server running at http://127.0.0.1:"), "start: #{started.lines}")
  first = try pid_of(try run(dir, ["status"]))

  logs = try run(dir, ["logs"])
  try Test.assert(logs.lines.any? { |line| line.include?("listening on 127.0.0.1") }, "the log: #{logs.lines}")

  restarted = try run(dir, ["restart"], command)
  try Test.assert(restarted.code == 0, "restart: #{restarted.errors}")
  try Test.assert(restarted.lines[0].start_with?("server restarted at"), "restart: #{restarted.lines}")
  status = try run(dir, ["status"])
  try Test.assert(status.lines.include?("  sessions 0"), "status: #{status.lines}")
  try Test.assert(status.lines.include?("  running turns 0"), "status: #{status.lines}")
  try Test.assert(try pid_of(status) != first, "restart started another process")

  stopped = try run(dir, ["stop"])
  try Test.assert(stopped.code == 0, "stop: #{stopped.errors}")
  try Test.eq(stopped.lines, ["server stopped"])
  try Test.assert(not File.stat("#{dir}/server.json").ok?, "server.json is removed")
  again = try run(dir, ["stop"])
  try Test.eq(again.code, 0)
  try Test.eq(again.lines, ["no server runs"])
  gone = try run(dir, ["status"])
  Test.eq(gone.code, 1)
end

def test_the_server_action_and_its_options_are_parsed() -> Result[Void]
  for bad in [["server"], ["server", "nope"], ["server", "stop", "restart"]]
    try Test.eq(Args.parse(bad).ok?, false)
  end

  case try Args.parse(["server", "stop", "--now", "--state-dir", "/s", "--", "agentica", "core.agc"])
    Args.Command.Server(options) ->
      try Test.assert(options.now and not options.follow, "flags")
      try Test.eq(options.state_dir, some("/s"))
      try Test.eq(options.server_command, some(["agentica", "core.agc"]))
      Test.eq(options.action == Args.Action.Stop, true)
    _ -> error("not a server command")
  end
end

private

def run(dir: String, action: List[String], command: List[String] = []) -> Result[Driver.Done]
  Driver.finish(try Driver.start_server(dir, action, command))
end

def pid_of(status: Driver.Done) -> Result[Int]
  for line in status.lines
    return ok(try line.strip.replace("pid ", "").to_i) if line.strip.start_with?("pid ")
  end

  error("no pid in #{status.lines}")
end
