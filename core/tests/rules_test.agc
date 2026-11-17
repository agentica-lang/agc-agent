import Approval from "../src/approval/approval"
import Arity from "../src/approval/arity"
import Permissions from "../src/approval/permissions"
import Shell from "../src/approval/shell"
import Tools from "../src/tools/tools"

# The examples of OpenCode's permissions page (v1.19.5), with Finn's tool names: the last rule that matches wins, and
# each command of a `bash` line is checked (any deny denies, else any ask asks).
def test_the_examples_of_opencode() -> Result[Void]
  root = try Path.real(System.env("TMPDIR").unwrap_or("/tmp"))
  bash = ["ask bash(*)", "allow bash(git *)", "allow bash(npm *)", "deny bash(rm *)", "allow bash(grep *)"]
  git = ["ask bash(*)", "allow bash(git *)", "deny bash(git commit *)", "deny bash(git push *)", "allow bash(grep *)"]
  docs = ["deny edit_file(*)", "allow edit_file(packages/web/src/content/docs/*.mdx)"]
  outside = ["allow bash", "ask external_directory(*)", "allow external_directory(/usr/*)"]
  reads = ["allow read_file(*)", "deny read_file(*.env)", "deny read_file(*.env.*)", "allow read_file(*.env.example)"]
  rows = [
    [["ask *", "allow bash", "deny edit_file"], ["bash", "rm -rf x", "Allow"]],
    [["ask *", "allow bash", "deny edit_file"], ["edit_file", "a.txt", "Deny"]],
    [["ask *", "allow bash", "deny edit_file"], ["read_file", "a.txt", "Ask"]],
    [bash, ["bash", "git status", "Allow"]],
    [bash, ["bash", "npm run build", "Allow"]],
    [bash, ["bash", "rm -rf build", "Deny"]],
    [bash, ["bash", "ls -la", "Ask"]],
    [bash, ["bash", "git log | grep fix", "Allow"]],
    [bash, ["bash", "git status && rm -rf x", "Deny"]],
    [bash, ["bash", "git status; ls", "Ask"]],
    [bash, ["bash", "git status $(rm x)", "Deny"]],
    [bash, ["bash", "git status\nrm x", "Deny"]],
    [bash, ["bash", "(cd sub && rm x)", "Deny"]],
    [git, ["bash", "git push origin main", "Deny"]],
    [git, ["bash", "git push", "Deny"]],
    [git, ["bash", "git commit -m x", "Deny"]],
    [git, ["bash", "git status", "Allow"]],
    [["ask bash(*)", "allow bash(grep)"], ["bash", "grep", "Allow"]],
    [["ask bash(*)", "allow bash(grep)"], ["bash", "grep x f", "Ask"]],
    [docs, ["edit_file", "packages/web/src/content/docs/a.mdx", "Allow"]],
    [docs, ["edit_file", "src/a.ts", "Deny"]],
    [reads, ["read_file", ".env", "Deny"]],
    [reads, ["read_file", "app/.env.local", "Deny"]],
    [reads, ["read_file", ".env.example", "Allow"]],
    [reads, ["read_file", "README.md", "Allow"]],
    [Approval.DEFAULTS, ["read_file", ".env", "Ask"]],
    [Approval.DEFAULTS, ["read_file", ".env.example", "Allow"]],
    [Approval.DEFAULTS, ["read_file", "a.txt", "Allow"]],
    [outside, ["bash", "cat /etc/hostname", "Ask"]],
    [outside, ["bash", "cd /usr/lib", "Allow"]],
    [outside, ["bash", "cat ./a.txt", "Allow"]],
    [["allow bash", "ask external_directory(*)"], ["bash", "cat $HOME/x", "Allow"]],
    [["allow bash", "deny external_directory(/etc/*)"], ["bash", "rm -f ../../../../../../etc/x", "Deny"]],
  ]

  for row in rows
    rules = try Approval.parse_rules(row[0])
    tool = row[1][0]
    verdict = Approval.decide(rules, root, tool, row[1][1], tool != "read_file")
    try Test.eq([row[1][1], verdict.to_s], [row[1][1], "Verdict.#{row[1][2]}"])
  end

  ok()
end

# OpenCode's wildcard: `*` any text, line ends too; `?` one character; a trailing ` *` is optional; the rest
# is literal.
def test_a_glob_matches_the_whole_text() -> Result[Void]
  rows = [
    ["git *", "git", "true"],
    ["git *", "git status", "true"],
    ["git *", "gitk", "false"],
    ["a*c", "abbc", "true"],
    ["a?c", "abc", "true"],
    ["a?c", "ac", "false"],
    ["a.c", "abc", "false"],
    ["*", "a\nb", "true"],
    ["a(b)", "a(b)", "true"],
    ["abc", "abcd", "false"],
    ["mcp__*", "mcp__fs__read", "true"],
  ]

  for row in rows
    try Test.eq([row[0], row[1], Approval.match?(row[1], row[0]).to_s], [row[0], row[1], row[2]])
  end

  ok()
end

# The arity table picks the words an "always" answer keeps; a command that runs another program or an option among
# those words keeps the whole text.
def test_always_keeps_the_words_of_the_arity_table() -> Result[Void]
  rows = [
    [["git", "checkout", "main"], ["git", "checkout"]],
    [["npm", "install"], ["npm", "install"]],
    [["npm", "run", "dev"], ["npm", "run", "dev"]],
    [["python", "script.py"], ["python", "script.py"]],
    [["touch", "foo.txt"], ["touch"]],
    [["docker", "compose", "up", "-d"], ["docker", "compose", "up"]],
    [["unknown", "a", "b"], ["unknown"]],
    [[], []],
  ]

  for row in rows
    try Test.eq(Arity.prefix(row[0]), row[1])
  end

  root = try Path.real(System.env("TMPDIR").unwrap_or("/tmp"))
  always = ->(command: String) { Shell.scan(root, command).always.map { |r| r.pattern } }
  try Test.eq(always.call("git status --short"), ["git status *"])
  try Test.eq(always.call("LANG=C ls -la | wc -l"), ["ls *", "wc *"])
  try Test.eq(always.call("cd sub && make test"), ["make test *"])
  for command in ["git -c a=b log", "sudo rm x", "env A=1 make", "xargs rm", "timeout 5 make", "export A=1"]
    try Test.eq(always.call(command), [command])
  end

  ok()
end

# A line that tree-sitter-bash cannot read or misreads asks, even under an allow rule; a deny rule still denies it.
def test_an_unclear_line_asks() -> Result[Void]
  root = try Path.real(System.env("TMPDIR").unwrap_or("/tmp"))
  rules = try Approval.parse_rules(["allow bash(*)", "deny bash(*rm *)"])
  verdicts = ["echo (", "a `b` `c`", "a `b` `rm x`"].map { |c| Approval.decide(rules, root, "bash", c, true) }
  try Test.eq(verdicts, [Tools.Verdict.Ask, Tools.Verdict.Ask, Tools.Verdict.Deny])
  Test.eq(Permissions.prefix(root, "bash", "a `b` `c`"), none)
end

# An "always" answer allows the command's prefix and nothing else of a later line; a rule that denies still wins.
def test_an_always_answer_allows_the_prefix_of_each_command() -> Result[Void]
  root = try Path.real(System.env("TMPDIR").unwrap_or("/tmp"))
  rules = try Approval.parse_rules(["ask bash(*)", "deny bash(git status --evil*)"])
  allows = Permissions.answered(Permissions.Allows(), "allow_prefix", root, "bash", "git status --short | wc -l")
  allowed = ["git status", "git status -s && wc", "git status; rm x", "git push", "git status --evil"].select do |c|
    Permissions.allows?(allows, rules, root, "bash", c)
  end

  Test.eq(allowed, ["git status", "git status -s && wc"])
end
