import Protocol from "pkg/protocol/protocol"
import Approval from "../src/approval"
import Config from "../src/config"
import Permissions from "../src/permissions"
import H from "support/harness"

# `allow_prefix` allows the next `git add`, `allow_tool` every bash call after it; the request says the prefix, and
# after the first answer only the `cat | tee`, which writes, asks.
def test_session_answers_allow_a_prefix_or_the_whole_tool() -> Result[Void]
  replies = ["git_add_a.sse", "git_add_b.sse", "bash.sse", "bash_echo.sse", "text.sse"]
  H.using(H.Setup(replies: replies)) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Add both, then show and echo.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    add = try H.approval(a)
    try Test.eq([add.preview, add.prefix.unwrap_or("")], ["git add a.txt", "git add"])
    _ = try H.approve(h, id, add.approval_id, Protocol.Decision.AllowPrefix)
    a = try H.until(a.with(seen: []), Protocol.EventKind.ApprovalRequested)
    cat = try H.approval(a)
    try Test.eq([cat.preview, cat.prefix.unwrap_or("none")], ["cat hello.txt | tee copy.txt", "none"])
    _ = try H.approve(h, id, cat.approval_id, Protocol.Decision.AllowTool)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(H.kinds(a.seen).select { |k| k == "approval_requested" }.size, 1)
    Test.eq(H.kinds(a.seen).select { |k| k == "tool_finished" }.size, 4)
  end
end

# With accept edits on (PATCH), a write runs without asking; the snapshot shows the mode.
def test_accept_edits_runs_writes_without_asking() -> Result[Void]
  H.using(H.Setup(replies: ["write_file.sse", "text.sse"])) do |h|
    id = try H.new_session(h)
    patched = try H.call(h, "PATCH", Protocol.session_path(id), "{\"accept_edits\": true}", H.auth(h))
    try Test.eq(patched.status, 200)
    try Test.eq((try H.session(h, id)).accept_edits, true)
    bad = try H.call(h, "PATCH", Protocol.session_path(id), "{\"accept\": true}", H.auth(h))
    try Test.eq(bad.status, 400)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(H.kinds(a.seen).select { |k| k == "approval_requested" }.size, 0)
    Test.eq(File.read_text("#{h.work}/hello.txt"), ok("hi\n"))
  end
end

# A project file adds its deny rules; its allow rules count only in a trusted folder.
def test_a_project_file_denies_anywhere_and_allows_only_when_trusted() -> Result[Void]
  H.using(H.Setup(replies: ["bash_read.sse", "text.sse"])) do |h|
    try Dir.mkdir("#{h.work}/.finn")
    rules = "{\"allow\": [\"write_file(*)\"], \"deny\": [\"bash(cat *)\"]}"
    try File.write_text("#{h.work}/.finn/config.json", rules)
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Show hello.txt.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.assert(H.kinds(a.seen).include?("tool_finished"), "no tool ran")
    try Test.eq(H.kinds(a.seen).select { |k| k == "approval_requested" }.size, 0)

    base = Approval.Rules(allow: [], deny: [])
    untrusted = try Permissions.with_project(base, h.work, false)
    trusted = try Permissions.with_project(base, h.work, true)
    try Test.eq([untrusted.allow.size, untrusted.deny.size], [0, 1])
    Test.eq([trusted.allow.size, trusted.deny.size], [1, 1])
  end
end

# The user's rules come from FINN_CONFIG, else the default file when it is there; a broken file stops the start.
def test_the_user_config_gives_the_rules() -> Result[Void]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/core-perm-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  try File.write_text("#{dir}/ok.json", "{\"allow\": [\"bash(npm test*)\"], \"deny\": [\"read_file(.env)\"]}")
  try File.write_text("#{dir}/bad.json", "{\"allow\": [\"npm test\"]}")
  given = Config.from_env(->(n) { env(dir, n, "#{dir}/ok.json") })
  broken = Config.from_env(->(n) { env(dir, n, "#{dir}/bad.json") })
  missing = Config.from_env(->(n) { env(dir, n, "#{dir}/none.json") })
  none_set = Config.from_env(->(n) { env(dir, n, "") })
  _ = Path.remove(dir)
  rules = (try given).rules
  try Test.eq([rules.allow.size, rules.deny.size], [1, 1])
  try Test.eq([broken.ok?, missing.ok?], [false, false])
  Test.eq((try none_set).rules.allow.size, 0)
end

private

def env(dir: String, name: String, config: String) -> Result[String]
  case name
    "FINN_CONFIG" -> ok(config)
    "HOME" -> ok(dir)
    _ -> error("not set")
  end
end
