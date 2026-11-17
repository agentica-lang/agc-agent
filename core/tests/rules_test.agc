import Approval from "../src/approval/approval"
import Extension from "../src/approval/extension"
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

# An "always" answer keeps `NAME *` only for a short list of plain programs. Any other program, a command that does
# not start with its name, has a redirection, or has a word with `$` or a substitution keeps its exact text.
def test_always_keeps_the_name_of_a_plain_program_only() -> Result[Void]
  root = try Path.real(System.env("TMPDIR").unwrap_or("/tmp"))
  always = ->(command: String) { Shell.scan(root, command).always.map { |r| shown(r) } }
  try Test.eq(always.call("ls -la"), ["ls *"])
  try Test.eq(always.call("ls 'foo' \"bar\""), ["ls *"])
  try Test.eq(always.call("{ ls x; } > f"), ["exact ls x"])
  try Test.eq(always.call("head ~/.ssh/x"), ["#{System.env("HOME").unwrap_or("")}/.ssh/*", "exact head ~/.ssh/x"])
  try Test.eq(always.call("LANG=C ls -la | du -s"), ["exact LANG=C ls -la", "du *"])
  try Test.eq(always.call("cd sub && ls x"), ["ls *"])
  try Test.eq(always.call("ls $(pwd)"), ["exact ls $(pwd)", "pwd *"])
  for command in [
    "git", "make", "make all", "npm install", "docker run x", "git grep x", "poetry run x", "git status --short",
    "echo hi > f", "cat <<EOF\nx\nEOF", "git $X", "echo \"$HOME\"", "sudo rm x", "env A=1 make", "xargs rm",
    "export A=1", "FOO=1 rm x", ">log rm x", "rm=1 rm x", "ls*", "exec ls", ". x.sh", "find . -exec rm {} +",
    "awk 1 x", "python x.py", "tree -o f", "ps eww", "grep x y", "grep -r foo", "cat x", "wc -l x", "unknown x",
  ]
    try Test.eq(always.call(command), ["exact #{command}"])
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

# An "always" answer allows the command's prefix and nothing else of a later line, nor a later command with a
# redirection or a substitution; a rule that denies still wins.
def test_an_always_answer_allows_the_prefix_of_each_command() -> Result[Void]
  root = try Path.real(System.env("TMPDIR").unwrap_or("/tmp"))
  rules = try Approval.parse_rules(["ask bash(*)", "deny bash(ls --evil*)"])
  allows = Permissions.answered(Permissions.Allows(), "allow_prefix", root, "bash", "ls -la | du -s")
  tried = [
    "ls x", "ls -a && du", "ls \"x\" y", "ls x; rm x", "git push", "ls --evil", "echo hi", "ls x >> ~/.bashrc",
    "du $(rm x)", "ls `x`", "ls \"$x\"", "{ ls x; } >> f", "(ls x) > f", "ls x | du > f",
    "for i in 1; do ls x; done > f",
  ]

  allowed = tried.select { |c| Permissions.allows?(allows, rules, root, "bash", c) }
  try Test.eq(allowed, ["ls x", "ls -a && du", "ls \"x\" y"])
  # An exact command is kept as it is, not as a glob: its `*` matches only itself.
  exact = Permissions.answered(Permissions.Allows(), "allow_prefix", root, "bash", "sudo rm -rf ./build/*")
  tried = ["sudo rm -rf ./build/*", "sudo rm -rf ./build/ /", "sudo rm -rf ./build/x"]
  try Test.eq(tried.select { |c| Permissions.allows?(exact, rules, root, "bash", c) }, ["sudo rm -rf ./build/*"])
  # A command after an assignment is kept whole too: `rm *` would never match the line it came from.
  assigned = Permissions.answered(Permissions.Allows(), "allow_prefix", root, "bash", "FOO=1 rm x")
  lines = ["FOO=1 rm x", "rm y", "FOO=2 rm x", "FOO=1 rm x; rm y"]
  Test.eq(lines.select { |c| Permissions.allows?(assigned, rules, root, "bash", c) }, ["FOO=1 rm x"])
end

# The files that `cat`, `head`, `grep` and the like name are `read_file` targets too, best effort: a `.env` file asks,
# but not the pattern of `grep` or the count of `head -n`.
def test_the_files_a_bash_command_reads_meet_the_read_rules() -> Result[Void]
  root = try Path.real(System.env("TMPDIR").unwrap_or("/tmp"))
  rules = try Approval.parse_rules(Approval.DEFAULTS + ["allow bash(*)", "allow external_directory(*)"])
  denied = try Approval.parse_rules(["allow bash(*)", "deny read_file(*.env)"])
  verdict = ->(r: Approval.Rules, command: String) { Approval.decide(r, root, "bash", command, true).to_s }
  try Test.eq(
    ["cat .env", "head ../x/.env", "cat .env.example", "cp .env.local x"].map { |c| verdict.call(rules, c) },
    ["Verdict.Ask", "Verdict.Ask", "Verdict.Allow", "Verdict.Ask"],
  )

  try Test.eq(
    ["grep -rn process.env src", "grep -e a.env x", "cp x .env", "grep x .env"].map { |c| verdict.call(denied, c) },
    ["Verdict.Allow", "Verdict.Allow", "Verdict.Allow", "Verdict.Deny"],
  )

  reads = ->(command: String) {
    Shell.scan(root, command).asked.select { |r| r.tool == "read_file" }.map { |r| r.pattern }
  }

  try Test.eq(reads.call("head -n 5 f"), ["f"])
  try Test.eq(reads.call("tail -c 10 -f log 2"), ["log"])
  Test.eq(reads.call("head ../x/.env"), [try Path.resolve("#{root}/../x/.env")])
end

# A rule is `ACTION TOOL(PATTERN)`: a space in the tool or a pattern over MAX_PATTERN characters is refused.
def test_a_rule_that_would_never_match_is_refused() -> Result[Void]
  long = "x" * Approval.MAX_PATTERN
  for text in [
    "allow bash (git *)",
    "allow bash git",
    "bash(x)",
    "maybe bash(x)",
    "allow bash()",
    "allow bash(#{long}x)",
  ]
    try Test.eq([text, Approval.parse_rule(text).ok?.to_s], [text, "false"])
  end

  Test.eq(Approval.parse_rule("allow bash(#{long})").ok?, true)
end

# An untrusted project keeps only its deny rules: an `ask` of its own cannot win over a deny of the user's, which with
# the approvals off would run the command.
def test_an_untrusted_project_ask_cannot_weaken_a_user_deny() -> Result[Void]
  root = try Path.real(System.env("TMPDIR").unwrap_or("/tmp"))
  dir = "#{root}/core-rules-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  try Dir.mkdir("#{dir}/.finn")
  try File.write_text("#{dir}/.finn/config.json", "{\"permission\": [\"ask bash\", \"ask *\"]}")
  user = try Approval.parse_rules(["deny bash(rm *)", "deny read_file(*.pem)"])
  ctx = try Tools.context(dir, ->(_name: String) { error("unset") })
  a = try Extension.open(user, dir, false, false)
  rm = Extension.verdict(a, ctx, "bash", JSON.object({"command": JSON.from("rm -rf x")}))
  hidden = Extension.hidden?(a, "key.pem")
  _ = Path.remove(dir)
  Test.eq([rm.to_s, hidden.to_s], ["Verdict.Deny", "true"])
end

private

def shown(r: Shell.Resource) -> String
  return "exact #{r.pattern}" if r.literal

  r.pattern
end
