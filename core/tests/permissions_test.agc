import Protocol from "pkg/protocol/protocol"
import Approval from "../src/approval/approval"
import Config from "../src/config/config"
import Permissions from "../src/approval/permissions"
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

# Without the approval extension there is no mode to turn on: the update is refused.
def test_accept_edits_is_refused_without_the_extension() -> Result[Void]
  H.using(H.Setup(replies: [], approvals: false)) do |h|
    id = try H.new_session(h)
    patched = try H.call(h, "PATCH", Protocol.session_path(id), "{\"accept_edits\": true}", H.auth(h))
    try Test.eq(patched.status, 400)
    Test.eq((try H.session(h, id)).accept_edits, false)
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
    try Test.eq([trusted.allow.size, trusted.deny.size], [1, 1])
    try File.write_text("#{h.work}/.finn/config.json", "{\"allow\": [\"npm test\"]}")
    try Test.eq(Permissions.with_project(base, h.work, false), ok(base))
    Test.eq(Permissions.with_project(base, h.work, true).ok?, false)
  end
end

# A `read_file` deny rule of the extension hides its files from `glob` in a session; without the extension, nothing
# is hidden.
def test_a_read_deny_rule_hides_files_from_glob_only_with_the_extension() -> Result[Void]
  for on in [true, false]
    try H.using(H.Setup(replies: ["glob.sse", "text.sse"], approvals: on, deny: ["read_file(secret*)"])) do |h|
      try File.write_text("#{h.work}/secret.txt", "s")
      try File.write_text("#{h.work}/open.txt", "o")
      id = try H.new_session(h)
      a = try H.subscribe(h, id)
      _ = try H.send(h, id, "List the files.")
      a = try H.until(a, Protocol.EventKind.TurnFinished)
      H.close(a)
      text = try File.read_text(H.session_file(h, id))
      Test.eq([on, text.include?("open.txt"), text.include?("secret.txt")], [on, true, not on])
    end
  end

  ok()
end

# A session allow keeps the bash deny rules: each simple command and every tail of its words is checked (a wrapper in
# front hides nothing), and one whose words are not plain (quoted, expanded) is not allowed through a prefix or the
# whole tool. With a bash deny rule a command that only reads needs a prefix too; git's --output writes.
def test_session_allows_keep_the_bash_deny_rules() -> Result[Void]
  rules = try Approval.parse_rules([], ["bash(rm -rf *)", "bash(git push*)"])
  prefixes = Permissions.Allows(prefixes: [["rm"], ["git", "push"], ["git", "status"], ["git", "log"], ["echo"]])
  whole = Permissions.Allows(tools: ["bash"])
  denied = [
    "rm -rf 'x'", "git push '--force' origin", "ls; git push --force", "FOO=1 git push", "echo \"$(git push)\"",
    "env rm -rf x", "timeout 5 rm -rf x", "echo x | xargs rm -rf", "sudo -u root git push",
  ]

  for command in denied
    try Test.eq([command, Permissions.allows?(prefixes, rules, "bash", command, "/tmp").to_s], [command, "false"])
    try Test.eq([command, Permissions.allows?(whole, rules, "bash", command, "/tmp").to_s], [command, "false"])
  end

  try Test.eq(Permissions.allows?(prefixes, rules, "bash", "git status --short && echo done", "/tmp"), true)
  try Test.eq(Permissions.allows?(prefixes, rules, "bash", "git log --output=x", "/tmp"), false)
  Test.eq(Permissions.allows?(whole, rules, "bash", "ls -la", "/tmp"), true)
end

# While a read_file deny rule exists any command may read the file: only the same call is allowed again for bash.
def test_a_read_deny_rule_leaves_bash_only_the_exact_allow() -> Result[Void]
  rules = try Approval.parse_rules([], ["read_file(.env)"])
  try Test.eq(Permissions.allows?(Permissions.Allows(prefixes: [["cat"]]), rules, "bash", "cat .env", "/tmp"), false)
  whole = Permissions.Allows(tools: ["bash"])
  try Test.eq(Permissions.allows?(whole, rules, "bash", "cat .env | wc -l", "/tmp"), false)
  exact = Permissions.answered(Permissions.Allows(), "allow_session", "bash", "cat .env")
  Test.eq(Permissions.allows?(exact, rules, "bash", "cat .env", "/tmp"), true)
end

# An edit of two files, one under .git/, is protected: neither accept edits nor allow_tool runs it.
def test_a_patch_that_touches_git_is_never_allowed_by_the_session() -> Result[Void]
  target = "a.txt, .git/hooks/pre-commit"
  edits = Permissions.Allows(accept_edits: true, tools: ["apply_patch"])
  try Test.eq(Approval.protected?("apply_patch", target), true)
  try Test.eq(Approval.protected?("apply_patch", "a.txt, b/.gitignore"), false)
  Test.eq(Permissions.allows?(edits, Approval.Rules(allow: [], deny: []), "apply_patch", target, "/tmp"), false)
end

# The prefix of a program of two words is its first two; with an option second, an answer allows the same call only.
def test_the_prefix_of_a_command() -> Result[Void]
  try Test.eq(Permissions.prefix("bash", "git log -n 3"), some(["git", "log"]))
  try Test.eq(Permissions.prefix("bash", "git -c a=b log"), none)
  try Test.eq(Permissions.prefix("bash", "ls -la"), some(["ls"]))
  try Test.eq([Permissions.prefix("bash", "env A=1 make"), Permissions.prefix("bash", "python3 x.py")], [none, none])
  Test.eq(Permissions.prefix("bash", "ls | wc"), none)
end

# The extension is off unless the user's config file (FINN_CONFIG, else the default file when it is there) or
# FINN_APPROVALS turns it on; a broken file stops the start either way.
def test_the_user_config_turns_approvals_on_with_its_rules() -> Result[Void]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/core-perm-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  rules = "\"allow\": [\"bash(npm test*)\"], \"deny\": [\"read_file(.env)\"]"
  try File.write_text("#{dir}/on.json", "{\"approvals\": true, #{rules}}")
  try File.write_text("#{dir}/off.json", "{#{rules}}")
  try File.write_text("#{dir}/bad.json", "{\"allow\": [\"npm test\"]}")
  sizes = ->(config: String, switch: String) { rule_sizes(dir, config, switch) }
  results = [
    sizes.call("#{dir}/on.json", ""),
    sizes.call("#{dir}/off.json", ""),
    sizes.call("#{dir}/off.json", "1"),
    sizes.call("#{dir}/on.json", "0"),
    sizes.call("", ""),
    sizes.call("", "1"),
  ]

  failed = [sizes.call("#{dir}/bad.json", "0").ok?, sizes.call("#{dir}/none.json", "").ok?, sizes.call("", "2").ok?]
  _ = Path.remove(dir)
  try Test.eq(results, [ok(some([1, 1])), ok(none), ok(some([1, 1])), ok(none), ok(none), ok(some([0, 0]))])
  Test.eq(failed, [false, false, false])
end

private

def rule_sizes(dir: String, config: String, switch: String) -> Result[Optional[List[Int]]]
  options = try Config.from_env(->(n) { env(dir, n, config, switch) })
  ok(options.approvals.map { |r| [r.allow.size, r.deny.size] })
end

def env(dir: String, name: String, config: String, switch: String) -> Result[String]
  case name
    "FINN_CONFIG" -> ok(config)
    "FINN_APPROVALS" -> ok(switch)
    "HOME" -> ok(dir)
    _ -> error("not set")
  end
end
