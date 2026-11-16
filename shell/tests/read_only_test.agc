import Shell from "../shell"

ROOT = "/work/project"

# The read-only commands of a real session (s111) are safe, but the `cd` out of the folder and the one through `$PWD`.
def test_the_commands_of_a_real_session_are_safe() -> Result[Void]
  commands: List[String] = try JSON.decode(try File.read_text("tests/fixtures/s111.json"), List[String])
  safe = commands.map { |c| Shell.verdict(c, ROOT) == Shell.Verdict.Safe }
  Test.eq(safe, [true, true, false, false, false, true, true, true, true, true])
end

def test_reading_commands_are_safe() -> Result[Void]
  texts = [
    "ls -la src", "cat a.txt | head -n 5", "grep -rn \"foo\\|bar\" --include=*.agc . 2>/dev/null | sort | uniq -c",
    "rg -n 'x' src", "find . -name '*.agc' -type f", "sed -n '1,20p' f", "sed -nE '/a/,/b/p' f", "wc -l *.agc",
    "git status --short", "git log --oneline -5 main..HEAD", "git diff HEAD~1 -- src", "git show HEAD:README.md",
    "git branch --show-current", "git rev-parse HEAD", "cd src && ls", "cat /work/project/a", "diff a b", "tr a b < f",
    "awk -F: '{print $1}' f", "echo done; pwd", "stat f; file f", "which ls", "cut -d, -f1 f", "tail -f log",
  ]

  for text in texts
    try Test.eq([text, Shell.verdict(text, ROOT).inspect], [text, "Verdict.Safe"])
  end

  ok()
end

# Commands that write, run something or reach outside the folder, however they hide it, are never safe.
def test_injections_are_never_safe() -> Result[Void]
  texts = [
    "ls > out", "cat a >> b", "ls; rm -rf .", "ls && touch x", "cat f | sh", "cat f | bash", "echo x | xargs rm",
    "env rm x", "eval ls", "exec ls", "sudo ls", "time ls", "find . -delete", "find . -exec rm {} ;",
    "find . -execdir sh -c x ;", "find . -fprint out", "find . -ok rm ;", "sed -i s/a/b/ f", "sed -n '1w out' f",
    "sed -n '1e id' f", "sed -n '1r /etc/passwd' f", "sed 's/a/b/' f", "sed -n -e 1p f", "sed -n -f s f",
    "sed --in-place -n 1p f", "sort -o out f", "sort -ro out f", "sort --output=out f", "uniq in out",
    "rg --pre ./x foo", "rg --search-zip foo", "rg -z foo", "file -C -m x", "git -c core.pager=sh log",
    "git -C /tmp log", "git log --output=x", "git diff --ext-diff", "git diff --no-index /etc/passwd x",
    "git branch new", "git branch -D main", "git push", "git checkout x", "git config x y", "cat /etc/passwd",
    "cat ../x", "cat src/../../x", "grep -f/etc/passwd x", "grep --file=/etc/passwd x", "cd /tmp && ls", "cd ..", "cd",
    "cat ~/.ssh/id_rsa", "find * -name x", "sort *", "uniq * ", "cat .*/x", "ls &", "awk '{print > \"x\"}' f",
    "awk '{system(\"id\")}' f", "awk '{print | \"sh\"}' f", "awk -f prog f", "ls $(id)", "ls `id`", "tee x", "cp a b",
    "rm x", "python3 -c x", "./script.sh", "/bin/ls", "l* x", "cat < /etc/passwd", "ls 2>err",
  ]

  for text in texts
    try Test.assert(Shell.verdict(text, ROOT) != Shell.Verdict.Safe, "safe: #{text.inspect}")
  end

  ok()
end

def test_what_writes_is_told_apart_from_what_is_not_known() -> Result[Void]
  try Test.eq(kind(Shell.verdict("ls > out", ROOT)), "writes")
  try Test.eq(kind(Shell.verdict("find . -delete", ROOT)), "writes")
  try Test.eq(kind(Shell.verdict("python3 x.py", ROOT)), "unknown")
  Test.eq(kind(Shell.verdict("echo $x", ROOT)), "unknown")
end

private

def kind(verdict: Shell.Verdict) -> String
  case verdict
    Shell.Verdict.Safe -> "safe"
    Shell.Verdict.Unknown(_) -> "unknown"
    Shell.Verdict.Writes(_) -> "writes"
  end
end
