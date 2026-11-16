import Approval from "../src/approval/approval"
import Diff from "../src/tools/diff"
import Tools from "../src/tools/tools"

struct Setup
  base: String
  root: String
  outside: String
  ctx: Tools.Context
  rules: Approval.Rules
end

def fake_env(name: String) -> Result[String]
  case name
    "PATH" -> System.env("PATH")
    "HOME" -> ok("/home/tester")
    "OPENAI_API_KEY" -> ok("sk-secret-key")
    "FINN_SERVER_JSON" -> ok("/state/server.json")
    _ -> error("not set")
  end
end

def dot_env(name: String) -> Result[String]
  return ok(".:/usr/bin:/bin") if name == "PATH"

  fake_env(name)
end

def link(target: String, path: String) -> Result[Void]
  process = try Process.spawn("ln", ["-s", target, path])
  code = try Process.wait(process, 5000)
  return error("ln failed") if code != 0

  ok()
end

# A session folder `work` with a file, a folder and a .git, next to a folder `outside` with a secret.
def setup() -> Result[Setup] = setup_with([], [])

def setup_with(allow: List[String], deny: List[String]) -> Result[Setup]
  tmp = System.env("TMPDIR").unwrap_or("/tmp")
  base = "#{tmp}/agc-tools-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(base)
  base = try Path.real(base)
  root = "#{base}/work"
  outside = "#{base}/outside"
  try Dir.mkdir("#{root}/sub")
  try Dir.mkdir("#{root}/.git")
  try Dir.mkdir(outside)
  try File.write_text("#{root}/a.txt", "one\ntwo\nthree\nfour\n")
  try File.write_text("#{root}/sub/b.txt", "needle in sub\n")
  try File.write_text("#{root}/.git/config", "needle in git\n")
  try File.write_text("#{outside}/secret.txt", "needle outside\n")
  try File.write_text("#{root}/blob.bin", "needle#{String.from_code(0)}binary")
  try link("#{outside}/secret.txt", "#{root}/secret_link")
  try link(outside, "#{root}/out_dir")
  try link("#{outside}/new.txt", "#{root}/dangling")
  try link("#{root}/a.txt", "#{root}/inside_link")
  rules = try Approval.parse_rules(allow, deny)
  ctx = (try Tools.context(root, &fake_env)).with(
    hidden: some(->(path: String) { Approval.read_denied?(rules, path) }),
  )

  ok(Setup(base: base, root: root, outside: outside, ctx: ctx, rules: rules))
end

def verdict(s: Setup, name: String, input: JSON.Value) -> Tools.Verdict = Approval.verdict(s.rules, s.ctx, name, input)

def call(s: Setup, name: String, fields: Map[String, String]) -> Tools.Output
  Tools.run(s.ctx, name, JSON.from(fields))
end

def raw(s: Setup, name: String, json: String) -> Tools.Output = Tools.run(s.ctx, name, JSON.parse(json).unwrap!)

def refused(out: Tools.Output) -> Result[Void] = Test.assert(out.is_error, "expected an error, got: #{out.text}")

def done(s: Setup) -> Result[Void]
  try Path.remove(s.base)
  ok()
end

def test_read_file_reads_inside_and_refuses_every_way_out() -> Result[Void]
  s = try setup()
  try Test.eq(call(s, "read_file", {"path": "a.txt"}), Tools.Output(text: "one\ntwo\nthree\nfour\n", is_error: false))
  try Test.eq(raw(s, "read_file", "{\"path\": \"a.txt\", \"offset\": 1, \"limit\": 2}").text, "two\nthree")
  try Test.eq(call(s, "read_file", {"path": "inside_link"}).is_error, false)
  try File.write_text("#{s.root}/crlf.txt", "a\r\nb\r\n")
  try Test.eq(call(s, "read_file", {"path": "crlf.txt"}).text, "a\r\nb\r\n")
  nulls = raw(s, "read_file", "{\"path\": \"a.txt\", \"offset\": null, \"limit\": null}")
  try Test.eq(nulls.text, "one\ntwo\nthree\nfour\n")
  try refused(call(s, "read_file", {"path": "../outside/secret.txt"}))
  try refused(call(s, "read_file", {"path": "sub/../../outside/secret.txt"}))
  try refused(call(s, "read_file", {"path": "#{s.outside}/secret.txt"}))
  try refused(call(s, "read_file", {"path": "secret_link"}))
  try refused(call(s, "read_file", {"path": "out_dir/secret.txt"}))
  try refused(call(s, "read_file", {"path": "dangling"}))
  try refused(call(s, "read_file", {"path": "/etc/passwd"}))
  try refused(call(s, "read_file", {"path": "missing.txt"}))
  try refused(call(s, "read_file", {"path": "sub"}))
  done(s)
end

def test_write_file_creates_and_never_writes_outside() -> Result[Void]
  s = try setup()
  made = call(s, "write_file", {"path": "new/deep/c.txt", "content": "hello"})
  try Test.eq(made.is_error, false)
  try Test.eq(File.read_text("#{s.root}/new/deep/c.txt"), ok("hello"))
  try Test.eq(call(s, "write_file", {"path": "new/deep/c.txt", "content": "again"}).is_error, false)
  try Test.eq(File.read_text("#{s.root}/new/deep/c.txt"), ok("again"))

  try refused(call(s, "write_file", {"path": "../outside/w.txt", "content": "x"}))
  try refused(call(s, "write_file", {"path": "fresh/../../outside/w.txt", "content": "x"}))
  try refused(call(s, "write_file", {"path": "out_dir/w.txt", "content": "x"}))
  try refused(call(s, "write_file", {"path": "dangling", "content": "x"}))
  try refused(call(s, "write_file", {"path": "secret_link", "content": "x"}))
  try refused(call(s, "write_file", {"path": "#{s.outside}/w.txt", "content": "x"}))
  try Test.eq(Dir.list(s.outside), ok(["secret.txt"]))
  try Test.eq(File.read_text("#{s.outside}/secret.txt"), ok("needle outside\n"))
  done(s)
end

# The approval of an edit marks every old line `-` and every new line `+`, so a bare "-" in the old text reads as text.
def test_edit_detail_marks_each_line() -> Result[Void]
  input = JSON.from({"path": "a.py", "old_string": "-", "new_string": "  return a + b\n"})
  Test.eq(Tools.detail("edit_file", input), "- -\n+   return a + b\n+ ")
end

def test_edit_file_replaces_exactly() -> Result[Void]
  s = try setup()
  try Test.eq(call(s, "edit_file", {"path": "a.txt", "old_string": "two", "new_string": "2"}).is_error, false)
  try Test.eq(File.read_text("#{s.root}/a.txt"), ok("one\n2\nthree\nfour\n"))
  try refused(call(s, "edit_file", {"path": "a.txt", "old_string": "zzz", "new_string": "y"}))
  try File.write_text("#{s.root}/dup.txt", "x x x")
  try refused(call(s, "edit_file", {"path": "dup.txt", "old_string": "x", "new_string": "y"}))
  try Test.eq(File.read_text("#{s.root}/dup.txt"), ok("x x x"))
  all = raw(
    s,
    "edit_file",
    "{\"path\": \"dup.txt\", \"old_string\": \"x\", \"new_string\": \"y\", \"replace_all\": true}",
  )

  try Test.eq(all.is_error, false)
  try Test.eq(File.read_text("#{s.root}/dup.txt"), ok("y y y"))
  try refused(call(s, "edit_file", {"path": "secret_link", "old_string": "needle", "new_string": "x"}))
  try refused(call(s, "edit_file", {"path": "../outside/secret.txt", "old_string": "needle", "new_string": "x"}))
  try Test.eq(File.read_text("#{s.outside}/secret.txt"), ok("needle outside\n"))
  done(s)
end

def test_glob_and_grep_skip_git_binaries_and_every_link() -> Result[Void]
  s = try setup()
  try Test.eq(call(s, "glob", {"pattern": "**/*.txt"}).text, "a.txt\nsub/b.txt")
  try Test.eq(call(s, "glob", {"pattern": "*.txt"}).text, "a.txt")
  try Test.eq(call(s, "glob", {"pattern": "**/*.txt", "path": "sub"}).text, "sub/b.txt")
  try Test.eq(call(s, "grep", {"pattern": "needle"}).text, "sub/b.txt:1:needle in sub")
  try Test.eq(call(s, "grep", {"pattern": "^t", "glob": "*.txt"}).text, "a.txt:2:two\na.txt:3:three")
  try Test.eq(call(s, "grep", {"pattern": "nothing here"}).text, "no matches")
  try refused(call(s, "grep", {"pattern": "("}))
  try refused(call(s, "glob", {"pattern": "**", "path": "out_dir"}))
  try refused(call(s, "grep", {"pattern": "needle", "path": "../outside"}))
  try refused(call(s, "glob", {"pattern": "*", "path": "a.txt"}))
  done(s)
end

def test_bash_runs_in_the_folder_with_a_clean_environment() -> Result[Void]
  s = try setup()
  try Test.eq(call(s, "bash", {"command": "pwd"}).text, "#{s.root}\n")
  try Test.eq(call(s, "bash", {"command": "echo out; echo err >&2"}).text, "out\n\n[stderr]\nerr\n")
  failed = call(s, "bash", {"command": "echo partial; exit 3"})
  try Test.eq(failed, Tools.Output(text: "exit code 3\npartial\n", is_error: true))

  env = call(s, "bash", {"command": "env"})
  try Test.eq(env.is_error, false)
  try Test.assert(env.text.include?("HOME=/home/tester"), "HOME is kept")
  try Test.assert(not env.text.include?("sk-secret-key"), "the provider key reached bash")
  try Test.assert(not env.text.include?("server.json"), "the path of server.json reached bash")

  # stdin is closed, so `cat` ends at once instead of waiting for input.
  try Test.eq(raw(s, "bash", "{\"command\": \"cat\", \"timeout_ms\": 5000}"), Tools.Output(text: "", is_error: false))
  long = call(s, "bash", {"command": "head -c 40000 /dev/zero | tr '\\0' a"})
  try Test.assert(long.text.include?("[output cut"), "a long output is cut")
  try refused(raw(s, "bash", "{\"command\": \"true\", \"timeout_ms\": 700000}"))
  done(s)
end

def test_bash_gets_only_the_kept_variables_of_the_real_environment() -> Result[Void]
  # `make unit` puts AGC_TEST_SECRET in the environment of the test process; `env -i` keeps it out of bash.
  secret = System.env("AGC_TEST_SECRET").unwrap_or("")
  try Test.assert(secret != "", "run the tests through make unit, which sets AGC_TEST_SECRET")
  s = try setup()
  env = call(s, "bash", {"command": "env"})
  try Test.eq(env.is_error, false)
  try Test.assert(not env.text.include?(secret), "a variable of the server reached bash")
  kept = ["PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TMPDIR", "TZ", "SHELL"]
  allowed = kept + ["PWD", "SHLVL", "_", "OLDPWD"]
  lines = env.text.split("\n").select { |text| text.include?("=") }
  for line in lines
    name = line.split("=").first
    try Test.assert(allowed.include?(name), "bash got the variable #{name}")
  end

  done(s)
end

# A read-only command, which may run without asking, finds its programs in /usr/bin:/bin, never in a `.` of the
# user's PATH; another command keeps the user's PATH.
def test_a_read_only_command_runs_with_a_fixed_path() -> Result[Void]
  s = try setup()
  try File.write_text("#{s.root}/cat", "#!/bin/sh\necho PWNED\n")
  process = try Process.spawn("chmod", ["+x", "#{s.root}/cat"])
  _ = try Process.wait(process, 5000)
  ctx = s.ctx.with(env: &dot_env)
  try Test.eq(Tools.run(ctx, "bash", JSON.from({"command": "cat a.txt"})).text, "one\ntwo\nthree\nfour\n")
  try Test.eq(Tools.run(ctx, "bash", JSON.from({"command": "echo $PATH"})).text, ".:/usr/bin:/bin\n")
  done(s)
end

def test_bash_timeout_kills_the_whole_process_group() -> Result[Void]
  s = try setup()
  started = Time.monotonic_ms()
  out = raw(s, "bash", "{\"command\": \"sleep 60 & echo $!; wait\", \"timeout_ms\": 500}")
  try Test.assert(Time.monotonic_ms() - started < 10000, "the timeout did not end the command")
  try refused(out)
  try Test.assert(out.text.include?("timed out"), "the error says it timed out")
  pid = out.text.split("\n").select { |line| line.to_i.ok? }.first
  probe = try Process.spawn("sh", ["-c", "sleep 0.3; kill -0 #{pid}"])
  try Test.eq(Process.wait(probe, 5000), ok(1))
  done(s)
end

def decide(rules: Approval.Rules, command: String) -> Tools.Verdict = Approval.decide(rules, "bash", command, true)

def test_a_bash_rule_matches_only_a_plain_command_and_whole_words() -> Result[Void]
  rules = try Approval.parse_rules(
    ["bash(git status*)", "bash(ls)", "write_file(src/*)"],
    ["bash(git status --evil*)"],
  )

  try Test.eq(decide(rules, "git status"), Tools.Verdict.Allow)
  try Test.eq(decide(rules, "git status --short"), Tools.Verdict.Allow)
  try Test.eq(decide(rules, "git status\t-s"), Tools.Verdict.Allow)
  try Test.eq(decide(rules, "git status --evil"), Tools.Verdict.Deny)
  try Test.eq(decide(rules, "git log"), Tools.Verdict.Ask)
  try Test.eq(decide(rules, "ls"), Tools.Verdict.Allow)
  # A `*` after a word does not cross into the next word: `statusx` can be a git alias.
  try Test.eq(decide(rules, "git statusx"), Tools.Verdict.Ask)
  try Test.eq(decide(rules, "git status-x"), Tools.Verdict.Ask)
  for command in [
    "git status; rm x",
    "git status && rm x",
    "git status || rm x",
    "git status | sh",
    "git status & rm x",
    "git status $(rm x)",
    "git status `rm x`",
    "git status > out",
    "git status < in",
    "git status\nrm x",
    "git status\r\nrm x",
    "git status <(id)",
    "git status >(id)",
    "git status <<EOF",
    "git status $((1+1))",
    "git status ${PATH:0:1}",
    "git status${IFS}--short",
    "git status \"a;b\"",
    "git status 'a'",
    "git status \\;",
    "git status *",
    "git status ?",
    "git status ~",
    "git status !x",
    "git status {a,b}",
    "git status #{String.from_code(65307)}touch x",
    "FOO=1 git status",
    "exec git status",
    "eval git status",
  ]
    try Test.eq(decide(rules, command), Tools.Verdict.Ask)
  end

  # A bash prompt expansion turns octal escapes into `$(...)`: it asks, because `$` and `\` are not plain.
  prompt = "git status '\\044(touch pwned\\073 kill -9 \\044\\044)' ${BASH_EXECUTION_STRING@P}"
  try Test.eq(decide(rules, prompt), Tools.Verdict.Ask)
  try Test.eq(Approval.decide(rules, "write_file", "src/a.agc", true), Tools.Verdict.Allow)
  try Test.eq(Approval.decide(rules, "edit_file", "src/a.agc", true), Tools.Verdict.Ask)
  # A rule allows every argument of the program: this is what the security model says, so the test keeps it true.
  cat = try Approval.parse_rules(["bash(cat src/*)"], [])
  try Test.eq(decide(cat, "cat src/../../outside/secret"), Tools.Verdict.Allow)
  try Test.error?(Approval.parse_rule("bash"))
  try Test.error?(Approval.parse_rule("bash()"))
  Test.error?(Approval.parse_rule("(x)"))
end

def test_a_change_under_git_always_asks() -> Result[Void]
  rules = try Approval.parse_rules(["write_file(*)", "edit_file(*)"], ["write_file(.git/hooks/*)"])
  try Test.eq(Approval.decide(rules, "write_file", "a.txt", true), Tools.Verdict.Allow)
  try Test.eq(Approval.decide(rules, "write_file", ".git/config", true), Tools.Verdict.Ask)
  try Test.eq(Approval.decide(rules, "edit_file", "sub/.git/config", true), Tools.Verdict.Ask)
  try Test.eq(Approval.decide(rules, "write_file", ".GIT/config", true), Tools.Verdict.Ask)
  try Test.eq(Approval.decide(rules, "write_file", ".git./config", true), Tools.Verdict.Ask)
  try Test.eq(Approval.decide(rules, "edit_file", "sub/.Git../hooks/x", true), Tools.Verdict.Ask)
  try Test.eq(Approval.decide(rules, "write_file", ".git/hooks/pre-commit", true), Tools.Verdict.Deny)
  Test.eq(Approval.decide(rules, "write_file", ".github/ci.yml", true), Tools.Verdict.Allow)
end

def write(path: String) -> JSON.Value = JSON.from({"path": path, "content": ""})

def edit(path: String) -> JSON.Value = JSON.from({"path": path, "old_string": "a", "new_string": "b"})

def test_verdicts_follow_the_defaults_and_judge_the_real_path() -> Result[Void]
  s = try setup_with(["write_file(sub/*)", "bash(git status*)"], [])
  try Test.eq(verdict(s, "read_file", JSON.from({"path": "a.txt"})), Tools.Verdict.Allow)
  try Test.eq(verdict(s, "glob", JSON.from({"pattern": "*"})), Tools.Verdict.Allow)
  try Test.eq(verdict(s, "grep", JSON.from({"pattern": "x"})), Tools.Verdict.Allow)
  try Test.eq(verdict(s, "write_file", write("a.txt")), Tools.Verdict.Ask)
  try Test.eq(verdict(s, "edit_file", edit("a.txt")), Tools.Verdict.Ask)
  try Test.eq(verdict(s, "bash", JSON.from({"command": "ls"})), Tools.Verdict.Allow)
  try Test.eq(verdict(s, "bash", JSON.from({"command": "ls > out"})), Tools.Verdict.Ask)
  # Read-only commands resolve their paths: a symlink out of the folder asks; a deny rule of read_file turns it off.
  for command in ["cat a.txt", "cat inside_link", "grep -n one a.txt sub/b.txt"]
    try Test.eq([command, verdict(s, "bash", JSON.from({"command": command})).inspect], [command, "Verdict.Allow"])
  end

  for command in ["cat secret_link", "cat out_dir/secret.txt", "ls out_dir", "cat #{s.outside}/secret.txt"]
    try Test.eq([command, verdict(s, "bash", JSON.from({"command": command})).inspect], [command, "Verdict.Ask"])
  end

  guarded = try setup_with([], ["read_file(secret.txt)"])
  for command in ["cat ./secret.txt", "head -n 99 secret.txt", "grep '' secret.txt", "cat -- secret.txt"]
    try Test.eq(verdict(guarded, "bash", JSON.from({"command": command})), Tools.Verdict.Ask)
  end

  try done(guarded)
  try Test.eq(verdict(s, "nope", JSON.from({"path": "a.txt"})), Tools.Verdict.Deny)

  try Test.eq(verdict(s, "write_file", write("sub/x.txt")), Tools.Verdict.Allow)

  try Test.eq(verdict(s, "write_file", write("sub/../a.txt")), Tools.Verdict.Ask)

  try Test.eq(verdict(s, "write_file", write("inside_link")), Tools.Verdict.Ask)

  try Test.eq(verdict(s, "bash", JSON.from({"command": "git status; rm x"})), Tools.Verdict.Ask)
  try Test.eq(verdict(s, "bash", JSON.from({"command": " git status "})), Tools.Verdict.Allow)
  done(s)
end

# A call whose target cannot be worked out is never allowed, with or without rules for the tool.
def test_a_call_with_a_bad_target_is_denied_and_fails() -> Result[Void]
  s = try setup_with(["write_file(*)", "bash(*)"], ["grep(*)"])
  for json in [
    "{\"path\": \"../outside/x\", \"content\": \"\"}",
    "{\"path\": \"dangling/x\", \"content\": \"\"}",
    "{\"path\": 3, \"content\": \"\"}",
    "{\"path\": null, \"content\": \"\"}",
    "{\"content\": \"\"}",
    "{\"path\": \"a.txt\", \"content\": \"\", \"paht\": \"x\"}",
    "[]",
    "null",
  ]
    input = JSON.parse(json).unwrap!
    try Test.eq(verdict(s, "write_file", input), Tools.Verdict.Deny)
    try refused(Tools.run(s.ctx, "write_file", input))
  end

  for json in ["{}", "{\"command\": null}", "{\"command\": 3}", "{\"command\": \"ls\", \"x\": 1}"]
    try Test.eq(verdict(s, "bash", JSON.parse(json).unwrap!), Tools.Verdict.Deny)
    try refused(Tools.run(s.ctx, "bash", JSON.parse(json).unwrap!))
  end

  # A `null` path is not "no path": it is refused, and it cannot dodge a rule by being read as `.`.
  null_path = JSON.parse("{\"pattern\": \"needle\", \"path\": null}").unwrap!
  try Test.eq(verdict(s, "grep", null_path), Tools.Verdict.Deny)
  try refused(Tools.run(s.ctx, "grep", null_path))
  try Test.eq(verdict(s, "grep", JSON.from({"pattern": "needle"})), Tools.Verdict.Deny)
  try refused(raw(s, "read_file", "{\"path\": null}"))
  done(s)
end

def test_a_deny_rule_of_read_file_hides_the_file_from_glob_and_grep() -> Result[Void]
  s = try setup_with([], ["read_file(.env)", "read_file(*/.env)", "read_file(*.pem)"])
  try File.write_text("#{s.root}/.env", "API_KEY=hunter2\nneedle\n")
  try File.write_text("#{s.root}/sub/.env", "needle\n")
  try File.write_text("#{s.root}/k.pem", "needle\n")
  try Test.eq(verdict(s, "read_file", JSON.from({"path": ".env"})), Tools.Verdict.Deny)
  grep = call(s, "grep", {"pattern": "needle|KEY"})
  try Test.eq(grep.text, "sub/b.txt:1:needle in sub")
  all = call(s, "glob", {"pattern": "**"})
  try Test.eq(all.text, "a.txt\nblob.bin\nsub/b.txt")
  try Test.eq(call(s, "grep", {"pattern": "needle", "path": "sub"}).text, "sub/b.txt:1:needle in sub")
  done(s)
end

def test_a_deny_rule_of_read_file_also_denies_edit_file() -> Result[Void]
  s = try setup_with(["edit_file(*)"], ["read_file(.env)"])
  try File.write_text("#{s.root}/.env", "API_KEY=hunter2\n")
  try Test.eq(verdict(s, "edit_file", edit(".env")), Tools.Verdict.Deny)
  try Test.eq(verdict(s, "edit_file", edit("a.txt")), Tools.Verdict.Allow)
  done(s)
end

def test_read_file_reads_a_range_of_a_file_over_1_mib() -> Result[Void]
  s = try setup()
  line = "y" * 100000
  big = "#{s.root}/big.txt"
  try File.write_text(big, "first\n")
  for _i in 1..12
    try File.append_text(big, "#{line}\n")
  end

  try File.append_text(big, "last\n")
  try Test.eq(raw(s, "read_file", "{\"path\": \"big.txt\", \"limit\": 1}").text, "first")
  try Test.eq(raw(s, "read_file", "{\"path\": \"big.txt\", \"offset\": 13, \"limit\": 5}").text, "last")
  done(s)
end

def test_read_file_keeps_the_lines_before_a_line_over_1_mib() -> Result[Void]
  s = try setup()
  long = "#{s.root}/long.txt"
  try File.write_text(long, "first\n")
  for _i in 1..3
    try File.append_text(long, "#{"y" * 1000000}")
  end

  try File.append_text(long, "\nafter1\nafter2\n")
  out = raw(s, "read_file", "{\"path\": \"long.txt\"}")
  try Test.eq(out.is_error, false)
  try Test.assert(out.text.start_with?("first\n[line 2 is longer than"), "got: #{out.text}")
  past = raw(s, "read_file", "{\"path\": \"long.txt\", \"offset\": 2}")
  try Test.eq(past.is_error, false)
  try Test.assert(past.text.include?("[line 2 is longer than"), "got: #{past.text}")
  done(s)
end

# Whatever the size of the file and the limit, the text stays under the output cap, quickly.
def test_read_file_never_builds_more_than_the_output_cap() -> Result[Void]
  s = try setup()
  big = "#{s.root}/big3.txt"
  for _i in 1..30
    try File.append_text(big, "#{"y" * 100000}\n")
  end

  small = "#{s.root}/small.txt"
  for _i in 1..900
    try File.append_text(small, "#{"z" * 999}\n")
  end

  started = Time.monotonic_ms()
  for name in ["big3.txt", "small.txt"]
    out = raw(s, "read_file", "{\"path\": \"#{name}\", \"limit\": 1000000000}")
    try Test.eq(out.is_error, false)
    try Test.assert(out.text.length <= 30000, "#{name} gave #{out.text.length} characters")
    try Test.assert(out.text.include?("[output cut at"), "#{name} has no cut note")
    try Test.assert(out.text.include?("continue with offset"), "#{name} does not say where to continue")
  end

  try File.write_text("#{s.root}/tiny.txt", "x\n" * 10000)
  tiny = raw(s, "read_file", "{\"path\": \"tiny.txt\", \"limit\": 1000000000}")
  try Test.assert(tiny.text.include?("[output limited to 5000 lines: continue with offset 5000]"), "no limit note")
  try Test.eq(tiny.text.split("\n").size, 5001)
  few = raw(s, "read_file", "{\"path\": \"tiny.txt\", \"offset\": 9000, \"limit\": 1000000000}")
  try Test.assert(not few.text.include?("continue"), "a note on the last lines")
  try Test.assert(Time.monotonic_ms() - started < 10000, "read_file is slow on a big limit")
  done(s)
end

def test_glob_and_grep_say_when_the_walk_stops_early() -> Result[Void]
  s = try setup()
  deep = (1..40).map { |_i| "d" }.join("/")
  try Dir.mkdir("#{s.root}/#{deep}")
  try File.write_text("#{s.root}/#{deep}/deep.txt", "needle deep\n")
  glob = call(s, "glob", {"pattern": "**/deep.txt"})
  try Test.assert(glob.text.include?("the walk stopped"), "glob does not say that it stopped: #{glob.text}")
  grep = call(s, "grep", {"pattern": "needle deep"})
  try Test.assert(grep.text.include?("the walk stopped"), "grep does not say that it stopped: #{grep.text}")
  try Test.assert(not call(s, "glob", {"pattern": "*.txt", "path": "sub"}).text.include?("stopped"), "no cut here")
  done(s)
end

def test_write_file_refuses_control_characters_in_a_name() -> Result[Void]
  s = try setup()
  try refused(call(s, "write_file", {"path": "new\nline.txt", "content": "x"}))
  try refused(call(s, "write_file", {"path": "sub/tab\there", "content": "x"}))
  try refused(call(s, "write_file", {"path": "a#{String.from_code(127)}b", "content": "x"}))
  try Test.eq(Dir.list(s.root).unwrap!.select { |name| name.include?("line") }, [])
  done(s)
end

def test_bad_input_is_an_error_for_the_model() -> Result[Void]
  s = try setup()
  try refused(raw(s, "read_file", "{}"))
  try refused(raw(s, "write_file", "{\"path\": 3}"))
  try refused(call(s, "no_such_tool", {"path": "a.txt"}))
  try refused(call(s, "read_file", {"path": ""}))
  try refused(call(s, "read_file", {"path": "a.txt", "paht": "b.txt"}))
  done(s)
end

def test_wildcards() -> Result[Void]
  try Test.assert(Approval.wildcard?("a*c", "abbc"), "middle")
  try Test.assert(Approval.wildcard?("*b*", "abc"), "both ends")
  try Test.assert(Approval.wildcard?("a*b*c", "a--b--c"), "two stars")
  try Test.assert(not Approval.wildcard?("a*b*c", "a--c--b"), "order")
  try Test.assert(not Approval.wildcard?("ab*ba", "aba"), "no overlap")
  try Test.assert(Approval.wildcard?("abc", "abc"), "exact")
  Test.assert(not Approval.wildcard?("abc", "abcd"), "exact is whole")
end

# An edit shows its lines numbered, two lines of context around them and `...` for the lines skipped.
def test_an_edit_is_shown_as_numbered_lines() -> Result[Void]
  text = "a\nb\nc\nd\ne\nf\ng\n"
  try Test.eq(
    Diff.edit(text, "d", "D\nD2").split("\n"),
    ["...", "  2 b", "  3 c", "- 4 d", "+ 4 D", "+ 5 D2", "  6 e", "  7 f", "..."],
  )

  try Test.eq(Diff.edit("one\ntwo", "one", "1"), "- 1 one\n+ 1 1\n  2 two")
  try Test.eq(Diff.edit("x", "y", "z"), "")
  Test.eq(Diff.written("a\nb"), "+ 1 a\n+ 2 b")
end
