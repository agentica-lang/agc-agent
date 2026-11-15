# Finding the server of the state folder, starting one, and refusing the ones that are not safe to use.

import Client from "../src/client"
import Protocol from "pkg/protocol/protocol"
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

def test_without_a_server_command_the_client_starts_nothing() -> Result[Void] = Driver.within_dir(&no_command)

def no_command(dir: String) -> Result[Void]
  cli = try Driver.start(dir, [])
  done = try Driver.finish(cli)
  try Test.eq(done.code, 1)
  Test.assert(done.errors.include?("no server command"), "the reason: #{done.errors}")
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
