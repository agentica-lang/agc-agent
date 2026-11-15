import Approval from "../src/approval"
import Tools from "../src/tools"

struct Setup
  base: String
  root: String
  outside: String
  ctx: Tools.Context
end

def fake_env(name: String) -> Result[String]
  case name
    "PATH" -> System.env("PATH")
    "HOME" -> ok("/home/tester")
    "OPENAI_API_KEY" -> ok("sk-secret-key")
    "AGC_AGENT_SERVER_JSON" -> ok("/state/server.json")
    _ -> error("not set")
  end
end

def link(target: String, path: String) -> Result[Void]
  process = try Process.spawn("ln", ["-s", target, path])
  code = try Process.wait(process, 5000)
  return error("ln failed") if code != 0

  ok()
end

# A session folder `work` with a file, a folder and a .git, next to a folder `outside` with a secret.
def setup() -> Result[Setup]
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
  ctx = try Tools.context(root, &fake_env)
  ok(Setup(base: base, root: root, outside: outside, ctx: ctx))
end

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
  try Test.assert(not env.text.include?("OPENAI_API_KEY"), "the provider key name reached bash")
  try Test.assert(not env.text.include?("server.json"), "the path of server.json reached bash")

  # stdin is closed, so `cat` ends at once instead of waiting for input.
  try Test.eq(raw(s, "bash", "{\"command\": \"cat\", \"timeout_ms\": 5000}"), Tools.Output(text: "", is_error: false))
  long = call(s, "bash", {"command": "head -c 40000 /dev/zero | tr '\\0' a"})
  try Test.assert(long.text.include?("[output cut"), "a long output is cut")
  try refused(raw(s, "bash", "{\"command\": \"true\", \"timeout_ms\": 700000}"))
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

def test_approval_rules_match_only_simple_commands() -> Result[Void]
  rules = try Approval.parse_rules(
    ["bash(git status*)", "write_file(src/*)"],
    ["bash(git status --evil*)", "read_file(*.pem)"],
  )

  try Test.eq(Approval.decide(rules, "bash", "git status", true), Approval.Verdict.Allow)
  try Test.eq(Approval.decide(rules, "bash", "git status --short", true), Approval.Verdict.Allow)
  try Test.eq(Approval.decide(rules, "bash", "git status --evil", true), Approval.Verdict.Deny)
  try Test.eq(Approval.decide(rules, "bash", "git log", true), Approval.Verdict.Ask)
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
  ]
    try Test.eq(Approval.decide(rules, "bash", command, true), Approval.Verdict.Ask)
  end

  try Test.eq(Approval.decide(rules, "read_file", "key.pem", false), Approval.Verdict.Deny)
  try Test.eq(Approval.decide(rules, "read_file", "a.txt", false), Approval.Verdict.Allow)
  try Test.eq(Approval.decide(rules, "write_file", "src/a.agc", true), Approval.Verdict.Allow)
  try Test.eq(Approval.decide(rules, "edit_file", "src/a.agc", true), Approval.Verdict.Ask)
  try Test.error?(Approval.parse_rule("bash"))
  try Test.error?(Approval.parse_rule("bash()"))
  Test.error?(Approval.parse_rule("(x)"))
end

def test_verdicts_follow_the_defaults_and_judge_the_real_path() -> Result[Void]
  s = try setup()
  defaults = try Approval.parse_rules([], [])
  rules = try Approval.parse_rules(["write_file(sub/*)", "bash(git status*)"], [])
  try Test.eq(Tools.verdict(s.ctx, defaults, "read_file", JSON.from({"path": "a.txt"})), Approval.Verdict.Allow)
  try Test.eq(Tools.verdict(s.ctx, defaults, "glob", JSON.from({"pattern": "*"})), Approval.Verdict.Allow)
  try Test.eq(Tools.verdict(s.ctx, defaults, "grep", JSON.from({"pattern": "x"})), Approval.Verdict.Allow)
  try Test.eq(Tools.verdict(s.ctx, defaults, "write_file", JSON.from({"path": "a.txt"})), Approval.Verdict.Ask)
  try Test.eq(Tools.verdict(s.ctx, defaults, "edit_file", JSON.from({"path": "a.txt"})), Approval.Verdict.Ask)
  try Test.eq(Tools.verdict(s.ctx, defaults, "bash", JSON.from({"command": "ls"})), Approval.Verdict.Ask)
  try Test.eq(Tools.verdict(s.ctx, defaults, "nope", JSON.from({"path": "a.txt"})), Approval.Verdict.Deny)

  try Test.eq(Tools.verdict(s.ctx, rules, "write_file", JSON.from({"path": "sub/x.txt"})), Approval.Verdict.Allow)
  try Test.eq(Tools.verdict(s.ctx, rules, "write_file", JSON.from({"path": "sub/../a.txt"})), Approval.Verdict.Ask)
  try Test.eq(Tools.verdict(s.ctx, rules, "write_file", JSON.from({"path": "inside_link"})), Approval.Verdict.Ask)
  try Test.eq(Tools.verdict(s.ctx, rules, "bash", JSON.from({"command": "git status; rm x"})), Approval.Verdict.Ask)
  try Test.eq(Tools.verdict(s.ctx, rules, "bash", JSON.from({"command": " git status "})), Approval.Verdict.Allow)
  done(s)
end

def test_bad_input_is_an_error_for_the_model() -> Result[Void]
  s = try setup()
  try refused(raw(s, "read_file", "{}"))
  try refused(raw(s, "write_file", "{\"path\": 3}"))
  try refused(call(s, "no_such_tool", {"path": "a.txt"}))
  try refused(call(s, "read_file", {"path": ""}))
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
