## The parser: bash quoting (single quotes, double quotes, backslash) and the operators `|`, `;`, `&&`, `||`, `&`, `>`,
## `>>`, `<`, `N>`, `N>>`, `2>&1` and `<<`. Anything else is an error: an expansion (`$`, backticks, `~`, braces), `<(`
## and `>(`, `N<`, `&>`, `<>`, `>&` to another target, a here-document, a subshell or group, a function, `!`, an assignment, a comment, a line end and any
## character it does not list. A glob (`*`, `?`, `[`) is kept as it is, and its word marked.

enum Join
  Then
  And
  Or
  Background
end

enum Redirect
  ## `N>path` (append for `>>`).
  Out(Int, String, Bool)
  ## `<path`.
  In(String)
  ## `2>&1`.
  ErrToOut
end

struct Word
  text: String
  ## Has an unquoted `*`, `?` or `[`, which bash may expand to file names.
  glob: Bool = false
end

struct Command
  words: List[Word]
  redirects: List[Redirect] = []
end

struct Pipeline
  commands: List[Command]
  ## How it joins the next pipeline; none for the last one.
  join: Optional[Join] = none
end

struct Script
  pipelines: List[Pipeline]
end

def parse(command: String) -> Result[Script]
  list = try tokens(command)
  build(list)
end

## The words of each simple command, without the quotes.
def argv(command: Command) -> List[String] = command.words.map { |word| word.text }

private

## Plain characters outside quotes: bash gives them as they are.
PLAIN = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:=,+@%-^]"
NAME_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"
GLOB = "*?["
## In double quotes a backslash escapes only these.
DOUBLE_ESCAPED = "\"\\$`"

enum Token
  Text(Word)
  Op(String)
end

struct Lexer
  chars: List[String]
  at: Int = 0
  out: List[Token] = []
  word: String = ""
  started: Bool = false
  glob: Bool = false
  ## The word so far is only unquoted digits, so a `>` after it names a file descriptor.
  digits: Bool = true
end

struct Builder
  pipelines: List[Pipeline] = []
  commands: List[Command] = []
  words: List[Word] = []
  redirects: List[Redirect] = []
  ## The redirection whose target is the next word.
  pending: String = ""
end

def tokens(command: String) -> Result[List[Token]]
  lexer = Lexer(chars: command.split(""))
  while lexer.at < lexer.chars.size
    lexer = try step(lexer)
  end

  ok(flush(lexer).out)
end

def step(lexer: Lexer) -> Result[Lexer]
  c = lexer.chars[lexer.at]
  case c
    "'" -> single(lexer)
    "\"" -> double(lexer)
    "\\" -> escaped(lexer)
    " " -> ok(flush(lexer).with(at: lexer.at + 1))
    "\t" -> ok(flush(lexer).with(at: lexer.at + 1))
    "|" -> operator(lexer, ["||", "|"])
    "&" if lexer.chars.drop(lexer.at + 1).take(1) == [">"] -> error("&> is not read")
    "&" -> operator(lexer, ["&&", "&"])
    ";" -> operator(lexer, [";"])
    ">" -> redirect(lexer)
    "<" if lexer.started and lexer.digits -> error("a redirection of a numbered input is not read")
    "<" -> operator(lexer, ["<<", "<"])
    _ if PLAIN.include?(c) -> ok(add(lexer, c, false).with(at: lexer.at + 1))
    "~" if lexer.started and not "=:".include?(last_char(lexer.word)) ->
      ok(add(lexer, c, false).with(at: lexer.at + 1))
    _ if GLOB.include?(c) -> ok(add(lexer, c, false).with(at: lexer.at + 1, glob: true))
    _ -> error("#{c.inspect} is not read as plain text")
  end
end

# A `~` expands at the start of a word and after `=` or `:`; elsewhere it is plain.
def last_char(word: String) -> String
  return "" if word.empty?

  word.slice(word.length - 1, 1)
end

def add(lexer: Lexer, text: String, quoted: Bool) -> Lexer
  digits = lexer.digits and not quoted and text.split("").all? { |ch| "0123456789".include?(ch) }
  lexer.with(word: "#{lexer.word}#{text}", started: true, digits: digits)
end

def flush(lexer: Lexer) -> Lexer
  return lexer if not lexer.started

  token = Token.Text(Word(text: lexer.word, glob: lexer.glob))
  lexer.with(out: lexer.out.push(token), word: "", started: false, glob: false, digits: true)
end

def single(lexer: Lexer) -> Result[Lexer]
  close = find(lexer.chars, lexer.at + 1, "'")
  return error("a single quote is not closed") if close < 0

  text = lexer.chars.drop(lexer.at + 1).take(close - lexer.at - 1).join("")
  return error("a line end in quotes") if text.include?("\n")

  ok(add(lexer, text, true).with(at: close + 1))
end

def double(lexer: Lexer) -> Result[Lexer]
  text = ""
  i = lexer.at + 1
  while i < lexer.chars.size
    c = lexer.chars[i]
    if c == "\""
      return ok(add(lexer, text, true).with(at: i + 1))
    elsif c == "$" or c == "`" or c == "!" or c == "\n"
      return error("#{c.inspect} in double quotes")
    elsif c == "\\" and i + 1 < lexer.chars.size and DOUBLE_ESCAPED.include?(lexer.chars[i + 1])
      text = "#{text}#{lexer.chars[i + 1]}"
      i = i + 2
    else
      text = "#{text}#{c}"
      i = i + 1
    end
  end

  error("a double quote is not closed")
end

def escaped(lexer: Lexer) -> Result[Lexer]
  return error("a backslash at the end") if lexer.at + 1 >= lexer.chars.size

  c = lexer.chars[lexer.at + 1]
  return error("a line end after a backslash") if c == "\n"

  ok(add(lexer, c, true).with(at: lexer.at + 2))
end

def operator(lexer: Lexer, choices: List[String]) -> Result[Lexer]
  for op in choices
    if lexer.chars.drop(lexer.at).take(op.length).join("") == op
      flushed = flush(lexer)
      return ok(flushed.with(out: flushed.out.push(Token.Op(op)), at: lexer.at + op.length))
    end
  end

  error("no operator")
end

# `>`, `>>` and `>&1`, with the file descriptor of the digits just before them (`2>`).
def redirect(lexer: Lexer) -> Result[Lexer]
  fd = "1"
  base = lexer
  if lexer.started and lexer.digits
    fd = lexer.word
    base = lexer.with(word: "", started: false, glob: false, digits: true)
  end

  rest = lexer.chars.drop(lexer.at).take(3).join("")
  op = ">"
  after = lexer.chars.drop(lexer.at + 3).take(1).join("")
  if rest.start_with?(">&1") and (after.empty? or " \t;|&<>".include?(after))
    op = ">&1"
  elsif rest.start_with?(">>")
    op = ">>"
  elsif rest.start_with?(">&") or rest.start_with?(">(") or rest.start_with?(">|")
    return error("#{rest.inspect} is not read")
  end

  flushed = flush(base)
  ok(flushed.with(out: flushed.out.push(Token.Op("#{fd}#{op}")), at: lexer.at + op.length))
end

def find(chars: List[String], from: Int, wanted: String) -> Int
  for j in from...chars.size
    return j if chars[j] == wanted
  end

  -1
end

def build(list: List[Token]) -> Result[Script]
  b = Builder()
  for token in list
    case token
      Token.Text(word) ->
        if b.pending.empty?
          b = b.with(words: b.words.push(word))
        else
          case target(b.pending, word)
            ok(redirect) -> b = b.with(redirects: b.redirects.push(redirect), pending: "")
            error(e) -> return error(e.message)
          end
        end

      Token.Op(op) ->
        case join_op(b, op)
          ok(next_b) -> b = next_b
          error(e) -> return error(e.message)
        end
    end
  end

  return error("a redirection without a target") if not b.pending.empty?
  return error("nothing after the last operator") if b.words.empty?

  command = try finished(b)
  last = Pipeline(commands: b.commands.push(command))
  ok(Script(pipelines: b.pipelines.push(last)))
end

def join_op(b: Builder, op: String) -> Result[Builder]
  return error("#{op} without a target") if not b.pending.empty?

  if op.end_with?(">&1")
    return error("#{op} is not read") if op != "2>&1"

    return ok(b.with(redirects: b.redirects.push(Redirect.ErrToOut)))
  end

  return error("a here-document") if op == "<<"
  return ok(b.with(pending: op)) if op == "<" or op.end_with?(">") or op.end_with?(">>")
  return error("#{op} with no command before it") if b.words.empty?

  command = try finished(b)
  return ok(b.with(commands: b.commands.push(command), words: [], redirects: [])) if op == "|"

  join = case op
    "&&" -> Join.And
    "||" -> Join.Or
    "&" -> Join.Background
    _ -> Join.Then
  end

  pipeline = Pipeline(commands: b.commands.push(command), join: some(join))
  ok(Builder(pipelines: b.pipelines.push(pipeline)))
end

# `NAME=value` before the command is an assignment.
def finished(b: Builder) -> Result[Command]
  first = b.words[0].text
  case first.index_of("=")
    some(at) if (at > 0 and (first.slice(0, at).split("").all? { |c| NAME_CHARS.include?(c) })) ->
      error("an assignment")
    _ -> ok(Command(words: b.words, redirects: b.redirects))
  end
end

def target(op: String, word: Word) -> Result[Redirect]
  return error("a glob as a redirection target") if word.glob
  return ok(Redirect.In(word.text)) if op == "<"

  append = op.end_with?(">>")
  width = 1
  if append
    width = 2
  end

  digits = op.slice(0, op.length - width)
  fd = try digits.to_i
  ok(Redirect.Out(fd, word.text, append))
end
