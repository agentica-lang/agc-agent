# `finn server` against the real core: start, status, logs, restart and stop of the server of a state folder.

import HTTP from "std/http"
import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import Args from "../src/args"
import Driver from "support/driver"

# A model that never answers: a turn that runs until the server cancels it. `entered` has a message when the model
# got the request.
struct Model
  server: HTTP.Server
  entered: Channel[Bool]
  gate: Channel[Bool]
end

def test_the_server_is_started_asked_restarted_and_stopped() -> Result[Void] = Driver.within_dir(&lifecycle)

def lifecycle(dir: String) -> Result[Void]
  command = try Driver.core_command()
  result = steps(dir, command)
  stop_leftover(dir)
  result
end

def cleaned(dir: String, steps: Fn[String, Result[Void]]) -> Result[Void]
  result = steps.call(dir)
  stop_leftover(dir)
  result
end

# A server that is left after a failed step goes with the test.
def stop_leftover(dir: String) -> Void
  case File.read_text("#{dir}/server.json")
    ok(text) ->
      case Protocol.decode_server_info(text)
        ok(info) -> _ = System.signal(info.pid, System.Signal.Term, "agentica")
        error(_) -> nil
      end

    error(_) -> nil
  end
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
  try Test.assert(logs.lines.any? { |line| line.start_with?("approvals are off") }, "the log: #{logs.lines}")

  restarted = try run(dir, ["restart"], command)
  try Test.assert(restarted.code == 0, "restart: #{restarted.errors}")
  try Test.assert(restarted.lines[0].start_with?("server restarted at"), "restart: #{restarted.lines}")
  status = try run(dir, ["status"])
  try Test.assert(status.lines.include?("  sessions 0"), "status: #{status.lines}")
  try Test.assert(status.lines.include?("  running turns 0"), "status: #{status.lines}")
  try Test.assert(status.lines.include?("  approvals off (tools run without asking)"), "status: #{status.lines}")
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

# A server started with --no-codemode has no code mode: the status, which `GET /v1/server` gives, says so.
def test_a_server_started_without_code_mode_says_so() -> Result[Void] = Driver.within_dir(&without_code_mode)

def without_code_mode(dir: String) -> Result[Void]
  command = try Driver.core_command()
  result = started_without_code_mode(dir, command)
  stop_leftover(dir)
  result
end

def started_without_code_mode(dir: String, command: List[String]) -> Result[Void]
  started = try run(dir, ["start", "--no-codemode"], command)
  try Test.assert(started.code == 0, "start: #{started.errors}")
  status = try run(dir, ["status"])
  try Test.assert(status.lines.include?("  code mode off"), "status: #{status.lines}")
  # Without the flag, a restart has code mode, unless this machine has no worker.
  restarted = try run(dir, ["restart"], command)
  try Test.assert(restarted.code == 0, "restart: #{restarted.errors}")
  again = try run(dir, ["status"])
  try Test.assert(not again.lines.include?("  code mode off"), "status: #{again.lines}")
  stopped = try run(dir, ["stop"])
  Test.eq(stopped.code, 0)
end

# A signal that ends a container stops the server cleanly: its file goes and its log says it stopped.
def test_a_term_signal_stops_the_server_cleanly() -> Result[Void]
  Driver.within_dir(->(dir) { cleaned(dir, &signalled) })
end

def signalled(dir: String) -> Result[Void]
  command = try Driver.core_command()
  started = try run(dir, ["start"], command)
  try Test.assert(started.code == 0, "start: #{started.errors}")
  pid = try Client.server_pid(dir)
  try System.signal(pid, System.Signal.Term, "agentica")
  # server.json goes before the last line of the log, which the server writes once its shutdown returns: wait for both.
  said = -> { File.read_text("#{dir}/server.log").unwrap_or("").include?("Finn Agent core stopped") }
  waited = 0
  while waited < 10_000 and not (Client.exited?(dir, pid) and said.call())
    Task.sleep(100)
    waited = waited + 100
  end

  try Test.assert(Client.exited?(dir, pid), "the server did not stop")
  try Test.assert(not File.stat("#{dir}/server.json").ok?, "server.json is removed")
  Test.assert(said.call(), "the log says it stopped")
end

def model_that_waits() -> Result[Model]
  entered: Channel[Bool] = Channel.new(8)
  gate: Channel[Bool] = Channel.new(1)
  handler = ->(request: HTTP.Request, _body: HTTP.RequestBody) {
    if request.path.end_with?("/chat/completions")
      _ = entered.send(true, 0)
      _ = gate.recv(60_000)
    end

    ok(HTTP.Answer.Whole(HTTP.Response(status: 404, headers: [], body: "{}".bytes)))
  }

  server = try HTTP.serve("127.0.0.1", 0, handler)
  ok(Model(server: server, entered: entered, gate: gate))
end

def free(model: Model) -> Void
  model.gate.close
  HTTP.close_server(model.server)
  _ = HTTP.wait(model.server)
end

def model_env(model: Model, drain_ms: String) -> Map[String, String]
  {
    "FINN_BASE_URL": "http://127.0.0.1:#{HTTP.local_port(model.server)}/v1",
    "FINN_API": "openai",
    "FINN_MODEL": "m",
    "FINN_DRAIN_MS": drain_ms,
  }
end

# A restart during a turn waits for the old server (its turn is cancelled when the wait ends), and the new one starts.
def test_a_restart_during_a_turn_waits_for_the_old_server() -> Result[Void] = Driver.within_dir(&restarted_in_a_turn)

def restarted_in_a_turn(dir: String) -> Result[Void]
  model = try model_that_waits()
  result = restart_steps(dir, model)
  free(model)
  stop_leftover(dir)
  result
end

def restart_steps(dir: String, model: Model) -> Result[Void]
  command = try Driver.core_command()
  env = model_env(model, "1500")
  started = try Driver.finish(try Driver.start_server(dir, ["start"], command, env))
  try Test.assert(started.code == 0, "start: #{started.errors}")
  first = try Client.server_pid(dir)
  turn = try Driver.start(dir, ["-p", "go"])
  try model.entered.recv(15_000)
  restarted = try Driver.finish(try Driver.start_server(dir, ["restart"], command, env))
  try Test.assert(restarted.code == 0, "restart: #{restarted.errors}")
  try Test.assert(try Client.server_pid(dir) != first, "another server runs")
  try Test.assert(Client.exited?(dir, first), "the old server is gone")
  _ = try Driver.finish(turn)
  ok()
end

# A stop waits for the turn while the server answers its status; a second stop with `--now` cancels the turn.
def test_a_stop_waits_for_a_turn_and_is_escalated_by_now() -> Result[Void] = Driver.within_dir(&escalated)

def escalated(dir: String) -> Result[Void]
  model = try model_that_waits()
  result = escalation_steps(dir, model)
  free(model)
  stop_leftover(dir)
  result
end

def escalation_steps(dir: String, model: Model) -> Result[Void]
  command = try Driver.core_command()
  env = model_env(model, "60000")
  started = try Driver.finish(try Driver.start_server(dir, ["start"], command, env))
  try Test.assert(started.code == 0, "start: #{started.errors}")
  pid = try Client.server_pid(dir)
  turn = try Driver.start(dir, ["-p", "go"])
  try model.entered.recv(15_000)
  waiting = try Driver.start_server(dir, ["stop"])
  try stopping_shown(dir)
  try Test.assert(not Client.exited?(dir, pid), "the server waits for its turn")
  now = try run(dir, ["stop", "--now"])
  try Test.assert(now.code == 0, "stop --now: #{now.errors}")
  first = try Driver.finish(waiting)
  try Test.eq(first.lines, ["server stopped"])
  try Test.assert(Client.exited?(dir, pid), "the server is gone")
  cancelled = try Driver.finish(turn)
  Test.eq(cancelled.code, 130)
end

# `status` shows the stop that waits: its line says so once the stop request arrived.
def stopping_shown(dir: String) -> Result[Void]
  waited = 0
  while waited < 10_000
    status = try run(dir, ["status"])
    shown = status.lines.any? { |line| line.strip.start_with?("stopping yes") }
    return ok() if shown

    waited = waited + 300
  end

  error("status never showed the stop")
end

# The tail of a log over 1 MiB, a log that is gone, and a log that is rotated when a server starts.
def test_the_logs_of_a_big_file_show_its_tail_and_a_start_rotates_a_log_over_10_mib() -> Result[Void]
  Driver.within_dir(->(dir) { cleaned(dir, &big_log) })
end

# A log of `head`, `count` lines of 100 bytes, and `tail`, which is over 1 MiB (the limit of `File.read_text`).
def write_log(path: String, head: String, count: Int, tail: String) -> Result[Void]
  _ = Path.remove(path)
  File.open(path, "create_private") do |file|
    try File.write(file, head)
    line = "x" * 99 + "\n"
    block = line * 1000
    for _ in 0..(count / 1000)
      try File.write(file, block)
    end

    File.write(file, tail)
  end
end

def big_log(dir: String) -> Result[Void]
  missing = try run(dir, ["logs"])
  try Test.eq(missing.code, 1)
  try Test.assert(missing.errors.include?("no server log"), "the message: #{missing.errors}")
  path = "#{dir}/server.log"
  try write_log(path, "first\n", 120_000, "last-but-one\nlast\n")
  tail = try run(dir, ["logs"])
  try Test.eq(tail.lines.size, 100)
  try Test.eq(tail.lines[99], "last")
  command = try Driver.core_command()
  try write_log(path, "old\n", 110_000, "end\n")
  started = try run(dir, ["start"], command)
  try Test.assert(started.code == 0, "start: #{started.errors}")
  try Test.assert(File.stat("#{path}.1").ok?, "the big log became server.log.1")
  try Test.assert((try File.stat(path)).size_bytes < 1_000_000, "a new log started")
  try Test.eq((try File.stat(path)).mode % 512, 384)
  stopped = try run(dir, ["stop"])
  Test.eq(stopped.code, 0)
end

# `logs -f` ends by itself when the server goes away.
def test_following_the_logs_ends_when_the_server_stops() -> Result[Void]
  Driver.within_dir(->(dir) { cleaned(dir, &followed) })
end

def followed(dir: String) -> Result[Void]
  command = try Driver.core_command()
  started = try run(dir, ["start"], command)
  try Test.assert(started.code == 0, "start: #{started.errors}")
  following = try Driver.start_server(dir, ["logs", "-f"])
  try shows(following, "listening")
  stopped = try run(dir, ["stop"])
  try Test.eq(stopped.code, 0)
  ended = try Driver.finish(following)
  Test.eq(ended.code, 0)
end

# Reads the output of a client until a line has `word`: it shows the log it follows, so it follows now.
def shows(cli: Process, word: String) -> Result[Void]
  while true
    line = try Process.read_line(cli, 10_000)
    return ok() if line.include?(word)
  end

  ok()
end

# A server that does not take the stop request is stopped by the pid of its `server.json`: one of another protocol, and
# one that holds the lock of its folder but answers badly.
def test_a_server_that_does_not_take_the_stop_request_is_stopped_by_its_pid() -> Result[Void]
  for health in [{"FAKE_HEALTH_VERSION": "20260101000000"}, {"FAKE_HEALTH_STATUS": "500"}]
    try Driver.within_dir(->(dir) { stopped_by_pid(dir, health) })
  end

  ok()
end

def stopped_by_pid(dir: String, health: Map[String, String]) -> Result[Void]
  words = try Driver.fake_command()
  server = try Process.spawn_captured(words[0], words.drop(1), Process.Options(env: health.put("FINN_STATE_DIR", dir)))
  result = stop_steps(dir, server)
  Process.close(server)
  result
end

def stop_steps(dir: String, server: Process) -> Result[Void]
  try Test.eq(try Process.read_line(server, 15_000), "ready")
  stopped = try run(dir, ["stop"])
  try Test.assert(stopped.code == 0, "stop: #{stopped.errors}")
  try Test.eq(stopped.lines, ["server stopped"])
  Test.eq(try Process.wait(server, 5000), 143)
end

# `finn server stop` signals only a process that proves to be the folder's server. A `server.json` that names an
# Agentica program while no server holds the folder's lock, an Agentica program of another folder, a program that is
# not Agentica, or the folder's own program when it started after `server.json` was written gets nothing: the stop says
# no server runs, and the program goes on. The folder's own program, with the lock held, is stopped.
def test_a_stop_signals_only_a_process_that_proves_to_be_the_folders_server() -> Result[Void]
  Driver.within_dir(&only_the_server)
end

def only_the_server(dir: String) -> Result[Void]
  words = try Driver.sleeper_command()
  mine = try Process.spawn_captured(words[0], words.drop(1), Process.Options(env: {"FINN_STATE_DIR": dir}))
  other = try Process.spawn_captured(words[0], words.drop(1), Process.Options(env: {"FINN_STATE_DIR": "#{dir}/home"}))
  script = "echo \"ready $$\"; exec sleep 60"
  sleep = try Process.spawn_captured("sh", ["-c", script], Process.Options(env: {"FINN_STATE_DIR": dir}))
  result = signalled_once(dir, mine, other, sleep)
  for program in [mine, other, sleep]
    Process.close(program)
  end

  result
end

def signalled_once(dir: String, mine: Process, other: Process, sleep: Process) -> Result[Void]
  pids = [try ready_pid(mine), try ready_pid(other), try ready_pid(sleep)]
  try name_in_server_json(dir, pids[0])
  try untouched(dir, mine, "no server holds the lock")
  File.open("#{dir}/core.lock", "append") do |lock|
    try Test.eq(File.try_lock(lock, 1000), ok(true))
    try name_in_server_json(dir, pids[1])
    try untouched(dir, other, "another folder's program")
    try name_in_server_json(dir, pids[2])
    try untouched(dir, sleep, "a program that is not Agentica")
    try name_in_server_json(dir, pids[0])
    # A minute before: the program started during this test, which has 30 s.
    try written_at(dir, Time.now_ms / 1000 - 60)
    try untouched(dir, mine, "a program that started after server.json was written")
    try name_in_server_json(dir, pids[0])
    stopped = try run(dir, ["stop"])
    try Test.eq(stopped.lines, ["server stopped"])
    Test.eq(try Process.wait(mine, 5000), 143)
  end
end

def untouched(dir: String, program: Process, what: String) -> Result[Void]
  stopped = try run(dir, ["stop"])
  try Test.eq(stopped.lines, ["no server runs"])
  Test.assert(not Process.wait(program, 10).ok?, "#{what} goes on")
end

def ready_pid(program: Process) -> Result[Int]
  line = try Process.read_line(program, 15_000)
  line.replace("ready ", "").strip.to_i
end

# Sets the time `server.json` was written, to before the program it names started.
def written_at(dir: String, seconds: Int) -> Result[Void]
  touch = try Process.spawn("touch", ["-d", "@#{seconds}", "#{dir}/server.json"])
  code = Process.wait(touch, 5000)
  Process.close(touch)
  Test.eq(try code, 0)
end

# After the program it names started, as a server writes it.
def name_in_server_json(dir: String, pid: Int) -> Result[Void]
  path = "#{dir}/server.json"
  try Path.remove(path)
  text = Protocol.encode_server_info(Protocol.ServerInfo(port: 9, token: "t", pid: pid))
  File.open(path, "create_private") do |file| File.write(file, text) end
end

# A server that drops SIGTERM: a stop that waits names `stop --now` (here after 1 s, not 30), and `--now` forces it.
def test_a_server_that_does_not_stop_is_named_for_stop_now_which_forces_it() -> Result[Void]
  Driver.within_dir(&forced)
end

def forced(dir: String) -> Result[Void]
  command = try Driver.fake_command()
  started = try Driver.finish(try Driver.start_server(dir, ["start"], command, {"FAKE_IGNORE_TERM": "1"}))
  try Test.assert(started.code == 0, "start: #{started.errors}")
  pid = try Client.server_pid(dir)
  late = Client.stop_and_wait(dir, false, 1000)
  try Test.assert(not late.ok?, "it did not stop")
  want = "(pid #{pid}) did not stop in 1 s: `finn server stop --now --state-dir #{dir}` ends it at once"
  try Test.assert(late.message.include?(want), late.message)
  try Test.eq(Client.stop_and_wait(dir, true, 1000), ok(true))
  Test.assert(Client.exited?(dir, pid), "it is gone")
end

# A server started with a server command of its own may be other code: it does not get the client's version.
def test_a_server_command_of_its_own_gets_no_version() -> Result[Void] = Driver.within_dir(&no_version)

def no_version(dir: String) -> Result[Void]
  command = try Driver.fake_command()
  started = try Driver.finish(try Driver.start_server(dir, ["start"], command, {"FINN_VERSION": "20261118000000"}))
  try Test.assert(started.code == 0, "start: #{started.errors}")
  try Test.eq(File.read_text("#{dir}/version.log"), ok(""))
  stopped = try run(dir, ["stop"])
  Test.eq(stopped.lines, ["server stopped"])
end

# A restart that cannot start a server says whether an old one was stopped.
def test_a_restart_that_fails_to_start_says_no_server_ran() -> Result[Void] = Driver.within_dir(&failed_restart)

def failed_restart(dir: String) -> Result[Void]
  result = try run(dir, ["restart"], ["/nonexistent/finn-core"])
  try Test.eq(result.code, 1)
  Test.assert(result.errors.include?("no server ran and no new one started"), "the message: #{result.errors}")
end

# A byte that is not UTF-8 shows as U+FFFD and the rest of the log still shows, in the tail and when it is followed.
def test_a_byte_that_is_not_utf_8_does_not_hide_the_rest_of_the_log() -> Result[Void] = Driver.within_dir(&bad_byte)

def bad_byte(dir: String) -> Result[Void]
  path = "#{dir}/server.log"
  bytes = Bytes.concat(["a\n".bytes, Bytes.from_list([255]).unwrap!, "\nb after bad byte\nc\n".bytes])
  try File.open(path, "create_private") do |file| File.write_bytes(file, bytes) end
  shown = try run(dir, ["logs"])
  try Test.eq(shown.code, 0)
  try Test.eq(shown.lines, ["a", String.from_code(65533), "b after bad byte", "c"])
  # A character that a piece of the read ends in the middle of is whole.
  _ = Path.remove(path)
  long = "x" + "é" * 40_000 + "\n"
  try File.open(path, "create_private") do |file| File.write(file, long) end
  split = try run(dir, ["logs"])
  Test.eq(split.lines, [long.slice(0, long.length - 1)])
end

def test_the_server_action_and_its_options_are_parsed() -> Result[Void]
  for bad in [["server"], ["server", "nope"], ["server", "stop", "restart"]]
    try Test.eq(Args.parse(bad).ok?, false)
  end

  leading = try Args.parse(["--state-dir", "/s", "server", "stop"])
  case leading
    Args.Command.Server(options) -> try Test.eq(options.state_dir, some("/s"))
    _ -> return error("not a server command")
  end

  case try Args.parse(["server", "stop", "--now", "--state-dir", "/s", "--", "agentica", "core.agc"])
    Args.Command.Server(options) ->
      try Test.assert(options.now and not options.follow, "flags")
      try Test.eq(options.state_dir, some("/s"))
      try Test.eq(options.server_command, some(["agentica", "core.agc"]))
      try Test.eq(options.action == Args.Action.Stop, true)
    _ -> return error("not a server command")
  end

  case try Args.parse(["server", "restart", "--no-codemode"])
    Args.Command.Server(options) -> try Test.eq(options.code_mode, some(false))
    _ -> return error("not a server command")
  end

  case try Args.parse(["--no-codemode", "-p", "hi"])
    Args.Command.Run(options) -> Test.eq(Args.launch(options).code_mode, false)
    _ -> error("not a run")
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
