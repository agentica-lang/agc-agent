import Shell from "../shell"

def test_words_lose_their_quotes_as_in_bash() -> Result[Void]
  try Test.eq(argv("grep -rn \"a\\\"b\\\\c\\|d\" 'x y' z\\ w"), [["grep", "-rn", "a\"b\\c\\|d", "x y", "z w"]])
  try Test.eq(argv("echo 'it''s' \"\\$HOME\" a\\*b"), [["echo", "its", "$HOME", "a*b"]])
  Test.eq(
    argv("ls -a; cat f | head -5 && pwd || echo no"),
    [["ls", "-a"], ["cat", "f"], ["head", "-5"], ["pwd"], ["echo", "no"]],
  )
end

def test_operators_and_redirections_make_the_tree() -> Result[Void]
  script = try Shell.parse("cat a 2>/dev/null | sort 2>&1 >> out < in & ls")
  try Test.eq(script.pipelines.size, 2)
  first = script.pipelines[0]
  try Test.eq(first.join, some(Shell.Join.Background))
  try Test.eq(first.commands[0].redirects, [Shell.Redirect.Out(2, "/dev/null", false)])
  try Test.eq(
    first.commands[1].redirects,
    [Shell.Redirect.ErrToOut, Shell.Redirect.Out(1, "out", true), Shell.Redirect.In("in")],
  )

  globs = (try Shell.parse("ls *.txt 'a*' b\\?")).pipelines[0].commands[0].words.map { |w| w.glob }
  Test.eq(globs, [false, true, false, false])
end

# Everything outside the small part of bash it reads is an error, so its words are never guessed.
def test_anything_else_does_not_parse() -> Result[Void]
  texts = [
    "echo $HOME", "echo ${x}", "echo $(id)", "echo `id`", "echo \"$x\"", "echo \"`id`\"", "cat <(ls)", "tee >(cat)",
    "cat <<EOF", "cat <<<x", "(ls)", "{ ls; }", "f() { ls; }", "! ls", "A=1 ls", "ls # c", "ls\nrm x", "echo ~",
    "ls ~/x", "echo {a,b}", "echo 'open", "echo \"open", "ls |", "| ls", "ls ;;", "ls &> f", "ls >& f", "ls 1>&2",
    "ls >| f", "ls \\", "echo é", "ls\tx\r", ";", "",
  ]

  for text in texts
    try Test.assert(Shell.parse(text).ok? == false, "parsed: #{text.inspect}")
  end

  ok()
end

private

def argv(text: String) -> List[List[String]]
  case Shell.parse(text)
    ok(script) -> script.pipelines.flat_map { |p| p.commands.map { |c| Shell.argv(c) } }
    error(e) -> [["error", e.message]]
  end
end
