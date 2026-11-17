# Code mode: the model's script calls the tools through the fake Monty worker, which replays frames recorded from the
# real one (record again with `MONTY_RECORD=path/to/monty make unit`). A call from the script is a tool call of its
# own: the same events, the same approval, and a denial raises PermissionError in the script.

import Protocol from "pkg/protocol/protocol"
import Config from "../src/config/config"
import H from "support/harness"

def test_a_script_calls_tools_and_a_denied_call_raises_in_it() -> Result[Void]
  H.using(H.Setup(replies: ["run_script.sse", "text.sse"], monty: "script.json")) do |h|
    try File.write_text("#{h.work}/hello.txt", "hi\n")
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Read hello.txt with a script.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    bash = try H.approval(a)
    try Test.eq([bash.tool, bash.preview], ["bash", "rm hello.txt"])
    _ = try H.approve(h, id, bash.approval_id, Protocol.Decision.Deny)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(H.stop_reason(a), "end_turn")
    try Test.eq(File.read_text("#{h.work}/hello.txt"), ok("hi\n"))
    started = a.seen.map { |s| started_name(s.event) }.select { |name| name != "" }
    try Test.eq(started, ["run_script", "read_file", "bash"])
    second = try H.request_messages(h, 2)
    try Test.eq(JSON.get(second.last, "role"), ok(JSON.from("tool")))
    Test.eq(JSON.get(second.last, "content"), ok(JSON.from("denied: the user denied this call\nhi\n3")))
  end
end

def started_name(event: Protocol.Event) -> String
  case event
    Protocol.Event.ToolStarted(tool) -> tool.name
    _ -> ""
  end
end

# A call that a config rule denies raises PermissionError without asking, and positional arguments a TypeError.
def test_a_rule_denies_a_call_of_a_script_and_arguments_go_by_keyword() -> Result[Void]
  setup = H.Setup(replies: ["run_script_refused.sse", "text.sse"], monty: "refused.json", deny: ["bash(*)"])
  H.using(setup) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Clean up with a script.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(H.kinds(a.seen).include?("approval_requested"), false)
    second = try H.request_messages(h, 2)
    content = (
      "type: read_file() takes keyword arguments only, as read_file(path='a.txt')\n" +
      "rule: denied by a rule of the config\n"
    )

    Test.eq(JSON.get(second.last, "content"), ok(JSON.from(content)))
  end
end

# Code mode is on by default where a Monty worker exists (a pinned wheel for the platform, or FINN_MONTY), off with
# FINN_CODE_MODE=0 and where there is none; a worker that cannot be fetched says how to turn code mode off.
def test_code_mode_is_on_by_default_where_a_worker_exists() -> Result[Void]
  base = "#{System.env("TMPDIR").unwrap_or("/tmp")}/agc-code-mode-#{Random.int(0, 999_999_999)}"
  try Dir.mkdir_private(base)
  try Dir.mkdir("#{base}/finn")
  result = defaults_in(base)
  _ = Path.remove(base)
  result
end

# A failed fetch of the worker is given again without a new try until its time is up, so a script cannot start a
# download on each call.
def test_a_failed_fetch_is_not_tried_again_for_a_while() -> Result[Void]
  tries: ATS[String, Int] = ATS.new()
  clock: ATS[String, Int] = ATS.new()
  clock.put("now", 0)
  worker = Config.remembered(-> { failing(tries) }, 1000, -> { clock.get("now").unwrap_or(0) })
  first = worker.call()
  again = worker.call()
  clock.put("now", 1000)
  later = worker.call()
  try Test.eq([first.message, again.message, later.message], ["no worker", "no worker", "no worker"])
  Test.eq(tries.get("n"), ok(2))
end

private

def failing(tries: ATS[String, Int]) -> Result[List[String]]
  tries.put("n", tries.get("n").unwrap_or(0) + 1)
  error("no worker", kind: "monty.install")
end

def defaults_in(base: String) -> Result[Void]
  env = {"XDG_CACHE_HOME": base}
  on = try Config.code_mode_on(->(n) { env.get(n).to_result("not set") }, &linux)
  off = env.put("FINN_CODE_MODE", "0")
  monty = env.put("FINN_MONTY", "/opt/monty")
  bad = env.put("FINN_CODE_MODE", "2")
  try Test.eq(
    [
      on.some?,
      (try Config.code_mode_on(->(n) { off.get(n).to_result("not set") }, &linux)).some?,
      (try Config.code_mode_on(->(n) { env.get(n).to_result("not set") }, &elsewhere)).some?,
      (try Config.code_mode_on(->(n) { monty.get(n).to_result("not set") }, &elsewhere)).some?,
      Config.code_mode_on(->(n) { bad.get(n).to_result("not set") }, &linux).ok?,
    ],
    [true, false, false, true, false],
  )

  read_env = ->(n: String) { env.get(n).to_result("not set") }
  try Test.eq(
    [
      Config.no_worker?(read_env, &elsewhere),
      Config.no_worker?(read_env, &linux),
      Config.no_worker?(->(n: String) { off.get(n).to_result("not set") }, &elsewhere),
    ],
    [true, false, false],
  )

  # The cache folder is open to others, so the fetch stops before any download.
  try Test.eq(try H.run("chmod", ["755", "#{base}/finn"]), 0)
  case on.unwrap!.worker.call()
    ok(_) -> error("expected the worker to be refused")
    error(e) -> Test.eq(e.message.include?("finn --no-codemode (or FINN_CODE_MODE=0) turns code mode off"), true)
  end
end

def linux() -> Result[String] = ok("linux x86_64")

def elsewhere() -> Result[String] = ok("plan9 mips")
