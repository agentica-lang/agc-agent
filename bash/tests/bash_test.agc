import Bash from "../bash"

# The words of each command of a line, as `kind text`.
def words(line: String) -> Result[List[List[String]]]
  parsed = try Bash.parse(line)
  ok(parsed.commands.map { |c| c.words.map { |w| "#{w.kind} #{w.text}" } })
end

# Pipes, lists, subshells, groups, substitutions and loops: each simple command, in the order it starts, with its words
# as written; assignments and redirections are not words.
def test_a_line_gives_its_simple_commands() -> Result[Void]
  try Test.eq(
    try words("ls -la | grep x && (cd /tmp; rm -rf \"a b\") > out"),
    [
      ["command_name ls", "word -la"],
      ["command_name grep", "word x"],
      ["command_name cd", "word /tmp"],
      ["command_name rm", "word -rf", "string \"a b\""],
    ],
  )

  try Test.eq(
    try words("FOO=1 git log `id` 2>&1; echo $(cat .env) 'q'"),
    [
      ["command_name git", "word log", "command_substitution `id`"],
      ["command_name id"],
      ["command_name echo", "command_substitution $(cat .env)", "raw_string 'q'"],
      ["command_name cat", "word .env"],
    ],
  )

  try Test.eq(
    try words("{ a; b; } || for f in x; do rm \"$f\"; done"),
    [["command_name a"], ["command_name b"], ["command_name rm", "string \"$f\""]],
  )

  Test.eq(try words("export A=$(curl x)"), [["command_name curl", "word x"]])
end

# A command's text is that of its statement, redirections included.
def test_a_command_keeps_its_text() -> Result[Void]
  parsed = try Bash.parse("cat a > b && ls")
  Test.eq(parsed.commands.map { |c| c.text }, ["cat a > b", "ls"])
end

# A syntax error is flagged; a line over MAX_LINE bytes is not read.
def test_a_broken_or_long_line() -> Result[Void]
  try Test.eq([(try Bash.parse("echo (")).error, (try Bash.parse("echo ok")).error], [true, false])
  Test.error?(Bash.parse("x" * (Bash.MAX_LINE + 1)))
end
