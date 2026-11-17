import Protocol from "pkg/protocol/protocol"
import Approval from "../src/approval/approval"
import Config from "../src/config/config"
import Extension from "../src/approval/extension"
import Permissions from "../src/approval/permissions"
import Tools from "../src/tools/tools"
import H from "support/harness"

# `allow_prefix` allows the next `git add`, `allow_tool` every bash call after it; the request says what each
# command's "always" allows, and after the first answer only the `cat | tee` asks.
def test_session_answers_allow_a_prefix_or_the_whole_tool() -> Result[Void]
  replies = ["git_add_a.sse", "git_add_b.sse", "bash.sse", "bash_echo.sse", "text.sse"]
  H.using(H.Setup(replies: replies)) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Add both, then show and echo.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    add = try H.approval(a)
    try Test.eq([add.preview, add.prefix.unwrap_or("")], ["git add a.txt", "git add *"])
    _ = try H.approve(h, id, add.approval_id, Protocol.Decision.AllowPrefix)
    a = try H.until(a.with(seen: []), Protocol.EventKind.ApprovalRequested)
    cat = try H.approval(a)
    try Test.eq([cat.preview, cat.prefix.unwrap_or("none")], ["cat hello.txt | tee copy.txt", "cat *, tee copy.txt"])
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

# A project file adds its rules after the user's: all of them in a trusted folder, else only its deny rules.
def test_a_project_file_denies_anywhere_and_allows_only_when_trusted() -> Result[Void]
  H.using(H.Setup(replies: ["bash_read.sse", "text.sse"])) do |h|
    try Dir.mkdir("#{h.work}/.finn")
    rules = "{\"permission\": [\"allow write_file(*)\", \"ask bash\", \"deny bash(cat *)\"]}"
    try File.write_text("#{h.work}/.finn/config.json", rules)
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Show hello.txt.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.assert(H.kinds(a.seen).include?("tool_finished"), "no tool ran")
    try Test.eq(H.kinds(a.seen).select { |k| k == "approval_requested" }.size, 0)

    base = Approval.Rules(all: [])
    untrusted = try Permissions.with_project(base, h.work, false)
    trusted = try Permissions.with_project(base, h.work, true)
    try Test.eq([untrusted.all.size, trusted.all.size], [1, 3])
    try File.write_text("#{h.work}/.finn/config.json", "{\"permission\": [\"npm test\"]}")
    try Test.eq(Permissions.with_project(base, h.work, false), ok(base))
    Test.eq(Permissions.with_project(base, h.work, true).ok?, false)
  end
end

# The deny rules count with the approvals on and off: a `read_file` rule hides its files from `glob` and `grep`, and a
# `bash` rule refuses a command of the model and a `!` command, without asking.
def test_the_deny_rules_count_with_the_approvals_on_or_off() -> Result[Void]
  for on in [true, false]
    replies = ["glob.sse", "grep.sse", "bash_rm.sse", "text.sse"]
    try H.using(H.Setup(replies: replies, approvals: on, deny: ["read_file(secret*)", "bash(rm *)"])) do |h|
      try File.write_text("#{h.work}/secret.txt", "x")
      try File.write_text("#{h.work}/open.txt", "x")
      id = try H.new_session(h)
      a = try H.subscribe(h, id)
      _ = try H.send(h, id, "List the files, find x, then remove one.")
      a = try H.until(a, Protocol.EventKind.TurnFinished)
      H.close(a)
      text = try File.read_text(H.session_file(h, id))
      shell = try H.post(
        h,
        Protocol.shell_path(id),
        Protocol.encode_run_shell(Protocol.RunShell(command: "rm open.txt", context: true)),
      )

      seen = [
        text.include?("open.txt:1:x"),
        text.include?("secret.txt"),
        File.stat("#{h.work}/open.txt").ok?,
        H.kinds(a.seen).include?("approval_requested"),
        shell.status == 403,
      ]

      Test.eq([on] + seen, [on, true, false, true, false, true])
    end
  end

  ok()
end

# With the approvals off nobody can be asked: a bash command a `bash` deny rule matches is refused from the model and
# as a `!` command, and a `write_file` rule refuses a write. A `read_file` rule covers the file tools only:
# `cat secret.txt` runs.
def test_with_the_approvals_off_a_bash_deny_rule_refuses_and_a_read_rule_does_not() -> Result[Void]
  replies = ["bash_rm_then_true.sse", "bash_rm_quoted.sse", "bash_cat_secret.sse", "write_open.sse", "text.sse"]
  deny = ["read_file(secret*)", "bash(rm *)", "write_file(open*)"]
  H.using(H.Setup(replies: replies, approvals: false, deny: deny)) do |h|
    try File.write_text("#{h.work}/secret.txt", "s3cr3t")
    try File.write_text("#{h.work}/open.txt", "x")
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Remove open.txt, show secret.txt, then change open.txt.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    text = try File.read_text(H.session_file(h, id))
    statuses: List[Int] = []
    for command in ["rm open.txt; true", "rm \"open.txt\"", "cat secret.txt"]
      run = Protocol.RunShell(command: command, context: true)
      statuses = statuses.push((try H.post(h, Protocol.shell_path(id), Protocol.encode_run_shell(run))).status)
    end

    try Test.eq(File.read_text("#{h.work}/open.txt"), ok("x"))
    try Test.eq([text.include?("s3cr3t"), H.kinds(a.seen).include?("approval_requested")], [true, false])
    Test.eq(statuses, [403, 403, 202])
  end
end

# The verdict of a `bash` call, in both modes: each command of the line is checked, so `bash(rm *)` after
# `bash(*)` denies `ls && rm x`. A `read_file` rule does not refuse `cat .env`. With the asking on, what no rule allows
# asks.
def test_a_deny_rule_after_an_allow_rule_wins_for_bash() -> Result[Void]
  deny = ["deny read_file(.env*)", "deny bash(rm *)"]
  allowed = try Approval.parse_rules(["allow bash(*)"] + deny)
  bare = try Approval.parse_rules(deny)
  root = try Path.real(System.env("TMPDIR").unwrap_or("/tmp"))
  ctx = try Tools.context(root, ->(_name: String) { error("unset") })
  commands = ["rm -rf x", "ls && rm x", "cat .env", "git status"]
  shown = [allowed, bare].flat_map do |rules|
    [false, true].map do |asking|
      a = Extension.open(rules, root, false, asking).unwrap!
      commands.map { |c| Extension.verdict(a, ctx, "bash", JSON.object({"command": JSON.from(c)})).to_s }
    end
  end

  try Test.eq(
    shown,
    [
      ["Verdict.Deny", "Verdict.Deny", "Verdict.Allow", "Verdict.Allow"],
      ["Verdict.Deny", "Verdict.Deny", "Verdict.Allow", "Verdict.Allow"],
      ["Verdict.Deny", "Verdict.Deny", "Verdict.Allow", "Verdict.Allow"],
      ["Verdict.Deny", "Verdict.Deny", "Verdict.Ask", "Verdict.Ask"],
    ],
  )

  # A `*` matches across a line end: a command of two lines is refused in both modes.
  everything = try Approval.parse_rules(["deny bash(*)"])
  for asking in [false, true]
    a = Extension.open(everything, root, false, asking).unwrap!
    b = Extension.open(bare, root, false, asking).unwrap!
    found = [bash_verdict(a, ctx, "echo a\necho b"), bash_verdict(b, ctx, "rm -rf x\ntrue")]

    try Test.eq([asking] + found.map { |v| v == Tools.Verdict.Deny }, [asking, true, true])
  end

  ok()
end

# A `!` command follows the rules of a `bash` call: one that a deny rule matches is refused in both modes; one the
# rules let through runs.
def test_a_deny_rule_refuses_a_shell_command_in_both_modes() -> Result[Void]
  for asking in [false, true]
    try H.using(H.Setup(replies: ["text.sse"], approvals: asking, deny: ["bash(rm *)"])) do |h|
      try File.write_text("#{h.work}/open.txt", "x")
      id = try H.new_session(h)
      statuses: List[Int] = []
      for command in ["rm open.txt", "rm -f open.txt", "true"]
        run = Protocol.RunShell(command: command, context: false)
        statuses = statuses.push((try H.post(h, Protocol.shell_path(id), Protocol.encode_run_shell(run))).status)
      end

      try Test.eq(File.read_text("#{h.work}/open.txt"), ok("x"))
      Test.eq([asking.to_s] + statuses.map { |s| s.to_s }, [asking.to_s, "403", "403", "202"])
    end
  end

  ok()
end

# With the approvals off a `read_file` rule refuses no bash command: `ls` and `git status` run.
def test_with_the_approvals_off_a_read_rule_leaves_other_commands_running() -> Result[Void]
  replies = ["bash_ls.sse", "bash_git_status.sse", "text.sse"]
  H.using(H.Setup(replies: replies, approvals: false, deny: ["read_file(secret*)"])) do |h|
    try File.write_text("#{h.work}/secret.txt", "s3cr3t")
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "List the files, then show the git status.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    text = try File.read_text(H.session_file(h, id))
    try Test.eq(H.kinds(a.seen).select { |k| k == "tool_finished" }.size, 2)
    Test.eq([text.include?("denied by a rule"), text.include?("secret.txt")], [false, true])
  end
end

# The default, from an environment with no switch and no config file: a call runs without asking, and a project file
# cannot turn the approvals on.
def test_by_default_tools_run_without_asking_and_a_project_cannot_ask() -> Result[Void]
  read = ->(name: String) { env("/nonexistent-finn-home", name, "", "") }
  H.using(H.Setup(replies: ["write_file.sse", "text.sse"], approvals_env: some(read))) do |h|
    try Dir.mkdir("#{h.work}/.finn")
    try File.write_text("#{h.work}/.finn/config.json", "{\"approvals\": true}")
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Write hello.txt.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(H.kinds(a.seen).include?("approval_requested"), false)
    try Test.eq(File.read_text("#{h.work}/hello.txt"), ok("hi\n"))
    Test.eq((try H.session(h, id)).accept_edits, false)
  end
end

# A session allow keeps the deny rules: a command one matches is not allowed through an "always" answer or the whole
# tool, nor a line with a command no answer allows. A `read_file` rule does not touch bash: `cat *` allows `cat .env`.
def test_session_allows_keep_the_deny_rules() -> Result[Void]
  root = try Path.real(System.env("TMPDIR").unwrap_or("/tmp"))
  rules = try Approval.parse_rules(["deny bash(rm -rf *)", "deny bash(git push*)", "deny read_file(.env)"])
  always = ["rm *", "git push *", "git status *", "cat *"].map { |p|
    Approval.Rule(action: Tools.Verdict.Allow, tool: "bash", pattern: p)
  }

  answers = Permissions.Allows(rules: always)
  whole = Permissions.Allows(tools: ["bash"])
  for command in ["rm -rf 'x'", "git push '--force' origin", "git push"]
    try Test.eq([command, Permissions.allows?(answers, rules, root, "bash", command).to_s], [command, "false"])
    try Test.eq([command, Permissions.allows?(whole, rules, root, "bash", command).to_s], [command, "false"])
  end

  refused = ["git status; ls", "git status $(id)", "git status && rm -rf x"]
  try Test.eq(refused.select { |c| Permissions.allows?(answers, rules, root, "bash", c) }, [])
  try Test.eq(Permissions.allows?(answers, rules, root, "bash", "git status --short | cat"), true)
  try Test.eq(Permissions.allows?(answers, rules, root, "bash", "cat .env"), true)
  Test.eq(Permissions.allows?(whole, rules, root, "bash", "ls -la"), true)
end

# An edit of two files, one under .git/, is protected: neither accept edits nor allow_tool runs it.
def test_a_patch_that_touches_git_is_never_allowed_by_the_session() -> Result[Void]
  target = "a.txt, .git/hooks/pre-commit"
  edits = Permissions.Allows(accept_edits: true, tools: ["apply_patch"])
  try Test.eq(Approval.protected?("apply_patch", target), true)
  try Test.eq(Approval.protected?("apply_patch", "a.txt, b/.gitignore"), false)
  Test.eq(Permissions.allows?(edits, Approval.Rules(all: []), "/", "apply_patch", target), false)
end

# A deny rule of `read_file` does not touch bash: the request still offers a prefix.
def test_a_read_deny_rule_keeps_the_prefix_of_the_request() -> Result[Void]
  H.using(H.Setup(replies: ["git_add_a.sse", "text.sse"], deny: ["read_file(secret*)"])) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Add it.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    add = try H.approval(a)
    _ = try H.approve(h, id, add.approval_id, Protocol.Decision.Deny)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    Test.eq([add.preview, add.prefix.unwrap_or("none")], ["git add a.txt", "git add *"])
  end
end

# The rules of the user's config file (FINN_CONFIG, else the default file when it is there) always load; the asking is
# off unless the file or FINN_APPROVALS turns it on, and FINN_APPROVALS wins. A broken file stops the start either way.
def test_the_user_config_turns_approvals_on_with_its_rules() -> Result[Void]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/core-perm-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  rules = "\"permission\": [\"allow bash(npm test *)\", \"deny read_file(.env)\"]"
  try File.write_text("#{dir}/on.json", "{\"approvals\": true, #{rules}}")
  try File.write_text("#{dir}/off.json", "{#{rules}}")
  try File.write_text("#{dir}/bad.json", "{\"permission\": [\"npm test\"]}")
  try File.write_text("#{dir}/old.json", "{\"allow\": [\"bash(npm test*)\"], \"deny\": [\"bash(rm *)\"]}")
  sizes = ->(config: String, switch: String) { rule_sizes(dir, config, switch) }
  results = [
    sizes.call("#{dir}/on.json", ""),
    sizes.call("#{dir}/off.json", ""),
    sizes.call("#{dir}/off.json", "1"),
    sizes.call("#{dir}/on.json", "0"),
    sizes.call("", ""),
    sizes.call("", "1"),
  ]

  failed = ["bad", "old", "none"].map { |name| sizes.call("#{dir}/#{name}.json", "0").ok? } + [sizes.call("", "2").ok?]
  moved = ""
  case sizes.call("#{dir}/old.json", "")
    error(e) -> moved = e.message
    ok(_) -> nil
  end

  _ = Path.remove(dir)
  try Test.assert(moved.include?("[\"allow bash(npm test*)\",\"deny bash(rm *)\"]"), "it names the rules: #{moved}")
  try Test.eq(results, [ok([2, 1]), ok([2, 0]), ok([2, 1]), ok([2, 0]), ok([0, 0]), ok([0, 1])])
  Test.eq(failed, [false, false, false, false])
end

private

# How many rules, and 1 when calls ask.
def rule_sizes(dir: String, config: String, switch: String) -> Result[List[Int]]
  options = try Config.from_env(->(n) { env(dir, n, config, switch) })
  rules = try options.approvals.to_result("no rules")
  asking = 0
  if options.asking
    asking = 1
  end

  ok([rules.all.size, asking])
end

def env(dir: String, name: String, config: String, switch: String) -> Result[String]
  case name
    "FINN_CONFIG" -> ok(config)
    "FINN_APPROVALS" -> ok(switch)
    "HOME" -> ok(dir)
    _ -> error("not set")
  end
end

def bash_verdict(a: Extension.Approvals, ctx: Tools.Context, command: String) -> Tools.Verdict
  Extension.verdict(a, ctx, "bash", JSON.object({"command": JSON.from(command)}))
end
