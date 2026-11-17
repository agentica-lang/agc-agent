import Bash from "../bash"

# The words of each command of a line, as `kind text`.
def words(line: String) -> Result[List[List[String]]]
  parsed = try Bash.parse(line)
  ok(parsed.commands.map { |c| c.words.map { |w| "#{w.kind} #{w.text}" } })
end

# Pipes, lists, subshells, groups, substitutions and loops: each simple command, in the order it starts, with its words
# as written; assignments before the name are not words.
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

  Test.eq(
    try words("{ a; b; } || for f in x; do rm \"$f\"; done"),
    [["command_name a"], ["command_name b"], ["command_name rm", "string \"$f\""]],
  )
end

# Words written after a redirection belong to the command.
def test_words_after_a_redirection_are_words() -> Result[Void]
  try Test.eq(try words("zqa >/dev/null push --force"), [["command_name zqa", "word push", "word --force"]])

  try Test.eq(try words("git <in push --force"), [["command_name git", "word push", "word --force"]])
  try Test.eq(try words("cat <<EOF x y\nbody\nEOF"), [["command_name cat", "word x", "word y"]])
  try Test.eq(try words("cat <<< w x"), [["command_name cat", "word x"]])
  try Test.eq(try words("a | zq 2>/dev/null x"), [["command_name a"], ["command_name zq", "word x"]])
  Test.eq(try words("git <<EOF 2>/dev/null push --force\nb\nEOF"), [["command_name git", "word push", "word --force"]])
end

# A statement that runs no program by name is a command of one word, its node type.
def test_other_statements_are_commands_named_by_their_type() -> Result[Void]
  kinds: List[List[String]] = []
  for line in ["export A=$(curl x)", "unset A", "[[ -f x ]]", "x=1", "a=1 b=2"]
    kinds = kinds.push((try words(line)).map { |c| c.first.split(" ").first })
  end

  Test.eq(
    kinds,
    [
      ["declaration_command", "command_name"],
      ["unset_command"],
      ["test_command"],
      ["variable_assignment"],
      ["variable_assignments"],
    ],
  )
end

# A command's text is that of its statement, redirections included.
def test_a_command_keeps_its_text() -> Result[Void]
  parsed = try Bash.parse("cat a > b && ls")
  Test.eq(parsed.commands.map { |c| c.text }, ["cat a > b", "ls"])
end

# A syntax error is flagged; a known misread (a stray backtick, a dropped `-`, two commands merged across a line end,
# a line continuation inside a word) makes the line unclear; a line over MAX_LINE bytes is not read.
def test_a_broken_unclear_or_long_line() -> Result[Void]
  try Test.eq([(try Bash.parse("echo (")).error, (try Bash.parse("echo ok")).error], [true, false])
  for line in [
    "a `b` `c`", "cat <<EOF\n`id`\nEOF", "echo \"`b` `c`\"", "a - 2>x", "a | b | c x\nd <<EOF\nEOF", "a\\\nb",
    "V=1 <<EOF rm -rf x\nb\nEOF", "a | V=1 <<E rm x\nE", "( V=1 <<E rm x\nE\n)",
    "a | b | export V\nrm -rf x <<EOF\nEOF", "a `V=`b` c`|d",
  ]
    try Test.eq([line, (try Bash.parse(line)).unclear.to_s], [line, "true"])
  end

  for line in ["a `b`", "echo \"`b`\" '`x`'", "cat <<'EOF'\nplain\nEOF"]
    try Test.eq([line, (try Bash.parse(line)).unclear.to_s], [line, "false"])
  end

  Test.error?(Bash.parse("x" * (Bash.MAX_LINE + 1)))
end

# A parse over LIMIT_MS gives an error, and so does a nesting whose commands would hold too much text; both end soon.
def test_a_slow_or_deep_line_ends_with_an_error() -> Result[Void]
  for line in ["a|" * 32000, "#{"$(" * 10000}x#{")" * 10000}"]
    started = Time.monotonic_ms
    try Test.error?(Bash.parse(line))
    elapsed = Time.monotonic_ms - started
    try Test.assert(elapsed < Bash.LIMIT_MS + 800, "the parse took #{elapsed} ms")
  end

  ok()
end
