# Finding the server of the state folder, starting one, and refusing the ones that are not safe to use.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import Args from "../src/args"
import Driver from "support/driver"
import Fake from "support/fake_server"
import Routes from "support/routes"

SETTLE_MS = 1500

def test_clients_that_start_together_start_one_server_that_outlives_them() -> Result[Void]
  Driver.within_dir(&started_together)
end

def started_together(dir: String) -> Result[Void]
  command = (try Driver.fake_command()).join(" ")
  args = ["--session", "s1", "--server-command", command]
  first = try Driver.start(dir, args)
  second = try Driver.start(dir, args)
  one = try Driver.finish(first)
  two = try Driver.finish(second)
  Task.sleep(SETTLE_MS)
  starts = try File.read_text("#{dir}/starts.log")
  info = try JSON.parse(try File.read_text("#{dir}/server.json"))
  port = try JSON.int(try JSON.get(info, "port"))
  alive = Client.health(Client.Server(url: "http://127.0.0.1:#{port}", token: Fake.TOKEN))
  try Test.eq([one.lines, two.lines], [["[session s1]"], ["[session s1]"]])
  try Test.eq([one.code, two.code], [0, 0])
  try Test.eq(starts, "started\n")
  try Test.ok?(alive)
  try Path.remove(dir)
  Test.assert(gone?(port), "the server stopped with its state folder")
end

def test_a_server_that_appears_while_the_lock_is_held_is_used_not_started_again() -> Result[Void]
  routes = [Routes.session([Fake.Reply(session: "session_idle.json")]), Routes.held_events()]
  Driver.within(routes, &waited_for_the_lock, Fake.TOKEN, false)
end

def waited_for_the_lock(rig: Driver.Rig) -> Result[Void]
  lock_path = "#{rig.dir}/server.lock"
  lock = try File.open(lock_path, "create_private")
  try Test.assert(try File.try_lock(lock), "the test holds the lock")
  command = try Driver.fake_command()
  cli = try Driver.start(rig.dir, ["--session", "s1", "--"] + command)
  Task.sleep(SETTLE_MS)
  try Driver.publish(rig)
  try File.close(lock)
  done = try Driver.finish(cli)
  try Test.eq(done.lines, ["[session s1]"])
  try Test.eq(done.code, 0)
  Test.assert(not File.stat("#{rig.dir}/starts.log").ok?, "no second server was started")
end

def test_a_server_that_refuses_the_token_is_reported_not_started_over() -> Result[Void]
  Driver.within([], &refused, "wrong")
end

def refused(rig: Driver.Rig) -> Result[Void]
  command = try Driver.fake_command()
  cli = try Driver.start(rig.dir, ["--"] + command)
  done = try Driver.finish(cli)
  health = try Fake.request(rig.fake, "GET", Protocol.HEALTH_PATH)
  try Test.eq(Driver.header(health, "authorization"), ["Bearer wrong"])
  try Test.eq(done.code, 1)
  try Test.eq(done.lines, [])
  try Test.assert(done.errors.include?("the token is missing or wrong"), "the 401 is the reason: #{done.errors}")
  try Test.assert(done.errors.include?("not starting another"), "nothing is started: #{done.errors}")
  Test.assert(not File.stat("#{rig.dir}/starts.log").ok?, "no server was started")
end

def test_a_server_that_does_not_answer_in_time_is_reported_not_started_over() -> Result[Void]
  Driver.within([Fake.Route(method: "GET", path: Protocol.HEALTH_PATH, replies: [slow()])], &hung)
end

def slow() -> Fake.Reply = Fake.Reply(delay_ms: 5000, body: "{\"version\": \"0.0.1\"}")

def hung(rig: Driver.Rig) -> Result[Void]
  command = try Driver.fake_command()
  cli = try Driver.start(rig.dir, ["--"] + command)
  done = try Driver.finish(cli)
  try Test.eq(done.code, 1)
  try Test.assert(done.errors.include?("timed out"), "the timeout is the reason: #{done.errors}")
  Test.assert(not File.stat("#{rig.dir}/starts.log").ok?, "no server was started")
end

def test_a_server_of_another_version_is_reported_with_how_to_stop_it() -> Result[Void]
  old = Fake.Reply(body: "{\"version\": \"0.0.1\"}")
  Driver.within([Fake.Route(method: "GET", path: Protocol.HEALTH_PATH, replies: [old])], &other_version)
end

def other_version(rig: Driver.Rig) -> Result[Void]
  command = try Driver.fake_command()
  cli = try Driver.start(rig.dir, ["--"] + command)
  done = try Driver.finish(cli)
  info = try Protocol.decode_server_info(try File.read_text("#{rig.dir}/server.json"))
  try Test.eq(done.code, 1)
  try Test.assert(done.errors.include?("runs another version"), "the version is the reason: #{done.errors}")
  try Test.assert(done.errors.include?("`kill #{info.pid}`"), "it says how to stop it: #{done.errors}")
  Test.assert(not File.stat("#{rig.dir}/starts.log").ok?, "no server was started")
end

def test_the_state_folder_is_made_private_and_an_open_one_is_refused() -> Result[Void]
  Driver.within_dir(&state_folders)
end

def state_folders(dir: String) -> Result[Void]
  fresh = "#{dir}/missing/state"
  cli = try Driver.start(fresh, ["--", "no-such-agc-server"])
  done = try Driver.finish(cli)
  try Test.eq(done.code, 1)
  try Test.assert(done.errors.include?("was not found"), "the command is not found: #{done.errors}")
  try Test.eq((try File.stat(fresh)).mode, 448)
  try Test.eq((try File.stat("#{fresh}/server.lock")).mode, 384)
  try Test.eq((try File.stat("#{fresh}/server.log")).mode, 384)
  open = "#{dir}/open"
  try Dir.mkdir(open)
  refused_cli = try Driver.start(open, ["--", "no-such-agc-server"])
  refused_done = try Driver.finish(refused_cli)
  try Test.eq(refused_done.code, 1)
  Test.assert(refused_done.errors.include?("chmod 700"), "the fix is named: #{refused_done.errors}")
end

def test_a_server_file_open_to_others_is_not_trusted() -> Result[Void] = Driver.within([], &open_server_file)

def open_server_file(rig: Driver.Rig) -> Result[Void]
  path = "#{rig.dir}/server.json"
  text = try File.read_text(path)
  try Path.remove(path)
  try File.write_text(path, text)
  cli = try Driver.start(rig.dir, [])
  done = try Driver.finish(cli)
  try Test.eq(done.code, 1)
  Test.assert(done.errors.include?("chmod 600"), "the fix is named: #{done.errors}")
end

def test_connect_refuses_an_open_folder_and_says_how_to_fix_it() -> Result[Void] = Driver.within_dir(&open_folder)

def open_folder(dir: String) -> Result[Void]
  open = "#{dir}/open"
  try Dir.mkdir(open)
  options = Args.Options(
    state_dir: some(open),
    server_command: none,
    session: none,
    cwd: none,
    model: none,
    thinking: false,
  )

  case Client.connect(Args.launch(options), open)
    ok(_) -> error("an open folder was accepted")
    error(e) ->
      try Test.eq(e.kind, Client.KIND_STATE)
      Test.assert(e.message.include?("chmod 700 #{open}"), "the fix is named: #{e.message}")
  end
end

def test_a_state_folder_of_someone_else_is_refused() -> Result[Void] = Driver.within_dir(&someone_elses_folder)

def someone_elses_folder(dir: String) -> Result[Void]
  mine = (try File.stat(dir)).user_id
  return ok() if (try File.stat("/")).user_id == mine

  cli = try Driver.start("/", [])
  done = try Driver.finish(cli)
  try Test.eq(done.code, 1)
  Test.assert(done.errors.include?("is not owned by you"), "the owner is the reason: #{done.errors}")
end

def test_a_symlink_of_someone_else_is_refused_and_one_of_yours_is_followed() -> Result[Void]
  Driver.within([Routes.session([Fake.Reply(session: "session_idle.json")]), Routes.held_events()], &links)
end

def links(rig: Driver.Rig) -> Result[Void]
  mine = (try File.stat(rig.dir)).user_id
  foreign = File.lstat("/bin")
  if foreign.ok? and foreign.unwrap!.kind == "link" and foreign.unwrap!.user_id != mine
    cli = try Driver.start("/bin", [])
    refused = try Driver.finish(cli)
    try Test.eq(refused.code, 1)
    try Test.assert(refused.errors.include?("symlink you do not own"), "the link is the reason: #{refused.errors}")
  end

  link = "#{rig.dir}-link"
  try symlink(rig.dir, link)
  cli = try Driver.start(link, ["--session", "s1"])
  done = try Driver.finish(cli)
  try Path.remove(link)
  try Test.eq(done.lines, ["[session s1]"])
  Test.eq(done.code, 0)
end

def symlink(target: String, path: String) -> Result[Void]
  process = try Process.spawn("ln", ["-s", target, path])
  code = try Process.wait(process, 5000)
  Test.eq(code, 0)
end

def test_a_server_file_with_a_dead_pid_is_not_used_and_a_new_server_is_started() -> Result[Void]
  Driver.within([], &dead_pid, Fake.TOKEN, false)
end

def dead_pid(rig: Driver.Rig) -> Result[Void]
  return ok() if not File.stat("/proc/self").ok?

  info = Protocol.ServerInfo(port: rig.fake.port, token: Fake.TOKEN, pid: 2_000_000_000)
  try Fake.write_private("#{rig.dir}/server.json", Protocol.encode_server_info(info))
  command = try Driver.fake_command()
  cli = try Driver.start(rig.dir, ["--session", "s1", "--"] + command)
  done = try Driver.finish(cli)
  Task.sleep(SETTLE_MS)
  started = try Protocol.decode_server_info(try File.read_text("#{rig.dir}/server.json"))
  try System.signal(started.pid, System.Signal.Term, "agentica")
  try Test.eq(done.lines, ["[session s1]"])
  try Test.eq(done.code, 0)
  try Test.eq(try File.read_text("#{rig.dir}/starts.log"), "started\n")
  Test.assert(started.port != rig.fake.port, "the new server is not the old one")
end

def test_the_server_it_starts_leads_a_process_group_of_its_own() -> Result[Void] = Driver.within_dir(&server_group)

def server_group(dir: String) -> Result[Void]
  command = try Driver.fake_command()
  cli = try Driver.start(dir, ["--session", "s1", "--"] + command)
  done = try Driver.finish(cli)
  info = try Protocol.decode_server_info(try File.read_text("#{dir}/server.json"))
  mine = try process_group(System.pid())
  theirs = try process_group(info.pid)
  try System.signal(info.pid, System.Signal.Term, "agentica")
  try Test.eq(done.code, 0)
  Test.assert(mine != theirs, "the server shares the process group #{mine} of its client")
end

def process_group(pid: Int) -> Result[String]
  ps = try Process.spawn_captured("ps", ["-o", "pgid=", "-p", pid.to_s])
  line = try Process.read_line(ps, 5000)
  _ = Process.wait(ps, 5000)
  Process.close(ps)
  ok(line.strip)
end

def test_the_default_server_is_the_cores_entry_point_never_the_one_of_the_current_folder() -> Result[Void]
  Driver.within_dir(&default_server)
end

def default_server(dir: String) -> Result[Void]
  state = "#{dir}/state"
  checked = default_server_checks(dir, state)
  stopped = stop_server(state)
  try checked
  port = try stopped
  Test.assert(gone?(port), "the server is stopped")
end

def default_server_checks(dir: String, state: String) -> Result[Void]
  evil = "#{dir}/evil"
  try Dir.mkdir("#{evil}/core")
  try File.write_text("#{evil}/core/main.agc", "def main() -> Void\n  puts(\"pwned\")\nend\n")
  cli = try Driver.start(state, ["--cwd", dir], "1", evil)
  done = try Driver.finish(cli)
  info = try Protocol.decode_server_info(try File.read_text("#{state}/server.json"))
  alive = Client.health(Client.Server(url: "http://127.0.0.1:#{info.port}", token: info.token))
  logged = try File.read_text("#{state}/server.log")
  try Test.eq(done.code, 0)
  try Test.assert(done.lines[0].start_with?("[session "), "a session was made: #{done.lines}")
  try Test.ok?(alive)
  Test.assert(not logged.include?("pwned"), "the folder's core did not run: #{logged}")
end

# Stops the server of the folder, whether the checks passed or not: gives its port.
def stop_server(state: String) -> Result[Int]
  info = try Protocol.decode_server_info(try File.read_text("#{state}/server.json"))
  try System.signal(info.pid, System.Signal.Term, "agentica")
  ok(info.port)
end

private

# True once nothing answers on the port.
def gone?(port: Int) -> Bool
  for _ in 1..50
    return true if not Client.health(Client.Server(url: "http://127.0.0.1:#{port}", token: Fake.TOKEN)).ok?

    Task.sleep(100)
  end

  false
end
