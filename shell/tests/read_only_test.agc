import Shell from "../shell"

ROOT = "/work/project"

# The read-only commands of a real session (s111) are safe, but the `cd` out of the folder, the one through `$PWD`, and
# those that use awk or git, which are not on the allow-list.
def test_the_commands_of_a_real_session_are_safe() -> Result[Void]
  commands: List[String] = try JSON.decode(try File.read_text("tests/fixtures/s111.json"), List[String])
  safe = commands.map { |c| safe?(c) }
  Test.eq(safe, [true, true, false, false, false, false, true, true, true, true])
end

def test_reading_commands_are_safe() -> Result[Void]
  texts = [
    "ls -la src", "cat a.txt | head -n 5", "grep -rn \"foo\\|bar\" --include=*.agc . 2>/dev/null | sort | uniq -c",
    "rg -n 'x' src", "rg --files src", "find . -name '*.agc' -type f", "sed -n '1,20p' f", "sed -nE '/a/,/b/p' f",
    "cat /work/project/a", "diff a b", "tr a b < f", "echo done; pwd", "stat f; file f", "which ls", "cut -d, -f1 f",
    "head -5 f", "tail -n 20 f", "grep -e x -A3 f", "sort -k2 -t, f", "grep -c x -- -f",
  ]

  for text in texts
    try Test.eq([text, Shell.verdict(text, &inside).inspect], [text, "Verdict.Safe"])
  end

  ok()
end

# Commands that write, run something or reach outside the folder, however they hide it, are never safe.
def test_injections_are_never_safe() -> Result[Void]
  texts = [
    # Writes and other programs.
    "ls > out",
    "cat a >> b",
    "ls; rm -rf .",
    "ls && touch x",
    "cat f | sh",
    "cat f | bash",
    "echo x | xargs rm",
    "env rm x",
    "eval ls",
    "exec ls",
    "sudo ls",
    "time ls",
    "ls & ls",
    "ls 2>err",
    "tee x",
    "cp a b",
    "rm x",
    "python3 -c x",
    "./script.sh",
    "/bin/ls",
    "l* x",
    # find, sed, sort, uniq, rg, file.
    "find . -delete",
    "find . -exec rm {} ;",
    "find . -execdir sh -c x ;",
    "find . -fprint out",
    "find . -fprint0 out",
    "find . -fls out",
    "find . -ok rm ;",
    "find . -okdir rm ;",
    "find -L .",
    "find . -newer f",
    "find . -name *",
    "sed -i s/a/b/ f",
    "sed -n '1w out' f",
    "sed -n '1W out' f",
    "sed -n '1e id' f",
    "sed -n '1r /etc/passwd' f",
    "sed -n '1R x' f",
    "sed 's/a/b/' f",
    "sed -n -e 1p f",
    "sed -n -f s f",
    "sed --in-place -n 1p f",
    "sort -o out f",
    "sort -ro out f",
    "sort --output=out f",
    "sort --outp=x f",
    "sort --ou=x f",
    "sort --comp=sh -S 1k - f",
    "sort -T /tmp f",
    "uniq in out",
    "rg --pre ./x foo",
    "rg --search-zip foo",
    "rg -z foo",
    "rg --hostname-bin=x --hyperlink-format=default foo",
    "rg -L foo",
    "file -C -m x",
    "file --comp -m magic",
    "file -z f",
    # Reads outside the folder, and options the allow-lists do not have.
    "cat /etc/passwd",
    "cat ../x",
    "cat src/../../x",
    "cat lnk/secret",
    "cat lnk",
    "grep -f/etc/passwd x",
    "grep --file=/etc/passwd x",
    "grep -R x .",
    "grep -r x lnk",
    "cat < /etc/passwd",
    "cat ~/.ssh/id_rsa",
    "tail -f log",
    "tail --follow log",
    "wc --files0-from=list",
    "head --l=3 f",
    "cat .*",
    "cat */x",
    "sort *",
    "sort -- *",
    "uniq *",
    "grep x *",
    "grep -e * f",
    "ls -L lnk",
    "ls -R .",
    "wc -l *.agc",
    "cat x*",
    "ls a*",
    "cat -- *.txt",
    "diff -r a b",
    # Not on the allow-list.
    "git status",
    "git log",
    "git diff ../outside/secret f",
    "awk '{print $1}' f",
    "awk 'BEGIN{ARGV[1]=\"/abs/secret\";ARGC=2}' f",
    "cd src",
    "cd /tmp && ls",
  ]

  for text in texts
    try Test.assert(Shell.verdict(text, &inside) != Shell.Verdict.Safe, "safe: #{text.inspect}")
  end

  ok()
end

def test_what_writes_is_told_apart_from_what_is_not_known() -> Result[Void]
  try Test.eq(kind(Shell.verdict("ls > out", &inside)), "writes")
  try Test.eq(kind(Shell.verdict("sort f | sh", &inside)), "writes")
  try Test.eq(kind(Shell.verdict("make x", &inside)), "unknown")
  Test.eq(kind(Shell.verdict("echo $x", &inside)), "unknown")
end

private

# The folder of the tests: `lnk` is a symlink to a folder outside, `..` leaves, absolute paths count below ROOT.
def inside(path: String) -> Bool
  full = path
  if not path.start_with?("/")
    full = "#{ROOT}/#{path}"
  end

  parts = full.split("/")
  return false if parts.include?("..") or parts.include?("lnk")

  full == ROOT or full.start_with?("#{ROOT}/")
end

def safe?(text: String) -> Bool = Shell.verdict(text, &inside) == Shell.Verdict.Safe

def kind(verdict: Shell.Verdict) -> String
  case verdict
    Shell.Verdict.Safe -> "safe"
    Shell.Verdict.Unknown(_) -> "unknown"
    Shell.Verdict.Writes(_) -> "writes"
  end
end
