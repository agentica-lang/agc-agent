## Whether a parsed command only reads inside the session folder. It is an allow-list: each command in `spec` with
## the options it lists (short ones by letter, long ones by their exact full name, never a GNU abbreviation), and each
## path it names checked by `inside`, which the caller gives (it resolves symlinks). Anything else is `Unknown`.

import Parse from "parse"

enum Verdict
  ## It only reads, inside the session folder.
  Safe
  ## It cannot be told: a command, an option or a path it does not check. Ask.
  Unknown(String)
  ## It writes a file or runs a program.
  Writes(String)
end

## `inside` tells whether a path as written (relative to the session folder, or absolute) resolves inside it.
def read_only?(script: Parse.Script, inside: Fn[String, Bool]) -> Verdict
  for pipeline in script.pipelines
    return Verdict.Unknown("a command in the background") if pipeline.join == some(Parse.Join.Background)

    for command in pipeline.commands
      verdict = command_verdict(command, inside)
      return verdict if verdict != Verdict.Safe
    end
  end

  Verdict.Safe
end

private

NULL = "/dev/null"
## Programs that run what they are given.
RUNNERS = [
  "xargs", "env", "sh", "bash", "zsh", "dash", "eval", "exec", "sudo", "doas", "time", "nohup", "timeout", "nice",
  "command", "builtin", "source", ".", "awk", "gawk", "perl", "python", "python3", "node", "ruby",
]

FIND_TESTS = ["-name", "-iname", "-path", "-ipath", "-type", "-maxdepth", "-mindepth", "-size", "-mtime", "-mmin"]
FIND_FLAGS = ["-print", "-print0", "-empty", "-not", "-o", "-a", "-or", "-and", "-prune", "!", "(", ")"]

## How a command reads its words: `flags` and `values` are short options (a value option takes the rest of its word
## or the next one), `long` and `long_values` exact long names; `patterns` is how many leading arguments are not paths
## (a pattern, a script), and `paths` whether the others are.
struct Spec
  flags: String = ""
  values: String = ""
  long: List[String] = []
  long_values: List[String] = []
  patterns: Int = 0
  paths: Bool = true
  ## `-5` means `-n 5`.
  counts: Bool = false
end

struct Args
  positionals: List[Parse.Word] = []
  shorts: String = ""
  longs: List[String] = []
  ## The positionals from this index came after `--`.
  ended_at: Int = -1
end

def spec(name: String) -> Optional[Spec]
  case name
    "ls" -> some(Spec(flags: "aAlhrtSdF1sinpgGo", long: ["--all", "--almost-all", "--human-readable", "--reverse"]))
    "cat" -> some(Spec(flags: "nbsAvET", long: ["--number"]))
    "head" -> some(Spec(flags: "qv", values: "nc", long_values: ["--lines", "--bytes"], counts: true))
    "tail" -> some(Spec(flags: "qv", values: "nc", long_values: ["--lines", "--bytes"], counts: true))
    "wc" -> some(Spec(flags: "lwcmL", long: ["--lines", "--words", "--bytes", "--chars"]))
    "grep" ->
      some(
        Spec(
          flags: "inrvwxclLoHhqsEFPzZ",
          values: "eABCm",
          long: ["--ignore-case", "--line-number", "--recursive", "--invert-match", "--count"],
          long_values: ["--include", "--exclude", "--exclude-dir", "--color", "--max-count", "--regexp"],
          patterns: 1,
        ),
      )
    "rg" ->
      some(
        Spec(
          flags: "inNwvlcFoHIuS",
          values: "gteABCm",
          long: ["--files", "--hidden", "--no-ignore", "--fixed-strings", "--ignore-case", "--line-number", "--count"],
          long_values: ["--glob", "--type", "--max-count", "--regexp"],
          patterns: 1,
        ),
      )
    "sed" -> some(Spec(flags: "nEsuz", patterns: 1))
    "sort" -> some(Spec(flags: "bdfgiMhnRrsuVc", values: "kt"))
    "uniq" -> some(Spec(flags: "cdiuDz", values: "fsw"))
    "cut" -> some(Spec(flags: "s", values: "dfcb"))
    "tr" -> some(Spec(flags: "dsc", paths: false))
    "diff" -> some(Spec(flags: "uqNaiwbB", values: "U"))
    "file" -> some(Spec(flags: "bi", long: ["--brief", "--mime-type"]))
    "stat" -> some(Spec(flags: "Lt", values: "c"))
    "pwd" -> some(Spec(paths: false))
    "which" -> some(Spec(flags: "a", paths: false))
    _ -> none
  end
end

def command_verdict(command: Parse.Command, inside: Fn[String, Bool]) -> Verdict
  for redirect in command.redirects
    verdict = redirect_verdict(redirect, inside)
    return verdict if verdict != Verdict.Safe
  end

  name = command.words[0]
  return Verdict.Unknown("the command is a glob") if name.glob
  return Verdict.Writes("#{name.text} runs other programs") if RUNNERS.include?(name.text)
  return find(command.words.drop(1), inside) if name.text == "find"
  return Verdict.Safe if name.text == "echo"

  case spec(name.text)
    some(s) -> checked(name.text, s, command.words.drop(1), inside)
    none -> Verdict.Unknown("#{name.text} is not a known read-only command")
  end
end

def redirect_verdict(redirect: Parse.Redirect, inside: Fn[String, Bool]) -> Verdict
  case redirect
    Parse.Redirect.ErrToOut -> Verdict.Safe
    Parse.Redirect.Out(_, path, _) if path == NULL -> Verdict.Safe
    Parse.Redirect.Out(_, path, _) -> Verdict.Writes("it writes #{path}")
    Parse.Redirect.In(path) -> path_verdict(Parse.Word(text: path), inside)
  end
end

def checked(name: String, s: Spec, words: List[Parse.Word], inside: Fn[String, Bool]) -> Verdict
  parsed = parsed_args(s, words)
  return Verdict.Unknown("#{name}: #{parsed.message}") if not parsed.ok?

  args = parsed.unwrap!

  patterns = s.patterns
  if args.shorts.include?("e") or args.longs.include?("--regexp") or args.longs.include?("--files")
    patterns = 0
  end

  if name == "sed"
    return Verdict.Unknown("sed without -n") if not args.shorts.include?("n")
    return Verdict.Unknown("sed without a script") if args.positionals.empty?

    script = args.positionals[0].text
    if ("wWerR".split("").any? { |c| script.include?(c) })
      return Verdict.Writes("the sed script may write, run or read a file")
    end
  end

  return Verdict.Writes("uniq writes its second file") if name == "uniq" and args.positionals.size > 1

  for i in 0...args.positionals.size
    ended = args.ended_at >= 0 and i >= args.ended_at
    word = args.positionals[i]
    verdict = Verdict.Safe
    if s.paths and i >= patterns
      verdict = path_verdict(word, inside)
    elsif word.glob
      verdict = glob_verdict(word, ended)
    end

    return verdict if verdict != Verdict.Safe
  end

  Verdict.Safe
end

# The options and the arguments of `words`, or an error for an option `s` does not list.
def parsed_args(s: Spec, words: List[Parse.Word]) -> Result[Args]
  args = Args()
  i = 0
  while i < words.size
    word = words[i]
    text = word.text
    i = i + 1
    if args.ended_at >= 0 or text == "-" or not text.start_with?("-")
      args = args.with(positionals: args.positionals.push(word))
    elsif text == "--"
      args = args.with(ended_at: args.positionals.size)
    elsif text.start_with?("--")
      name = text.split("=")[0]
      if s.long.include?(text)
        args = args.with(longs: args.longs.push(text))
      elsif s.long_values.include?(name)
        args = args.with(longs: args.longs.push(name))
        if not text.include?("=")
          return error("#{name} without its value") if i >= words.size
          return error("a glob as the value of #{name}") if words[i].glob

          i = i + 1
        end
      else
        return error("the option #{name} is not known")
      end
    elsif s.counts and only?(text.slice(1, text.length - 1), "0123456789")
      args = args.with(shorts: "#{args.shorts}n")
    else
      args = try shorts(s, args, text)
      if value_last?(s, text)
        return error("#{text} without its value") if i >= words.size
        return error("a glob as the value of #{text}") if words[i].glob

        i = i + 1
      end
    end
  end

  ok(args)
end

# The short options of `text` (`-rn`, `-A3`): flags, then at most one value option, which takes the rest.
def shorts(s: Spec, args: Args, text: String) -> Result[Args]
  out = args
  for c in text.slice(1, text.length - 1).split("")
    return error("the option -#{c} is not known") if not s.flags.include?(c) and not s.values.include?(c)

    out = out.with(shorts: "#{out.shorts}#{c}")
    return ok(out) if s.values.include?(c)
  end

  ok(out)
end

# The first value option of `text` is its last letter, so its value is the next word.
def value_last?(s: Spec, text: String) -> Bool
  letters = text.slice(1, text.length - 1).split("")
  case (letters.find_index { |c| s.values.include?(c) })
    some(at) -> at == letters.size - 1
    none -> false
  end
end

# A path inside the folder; a glob is not, since the names it gives are not resolved.
def path_verdict(word: Parse.Word, inside: Fn[String, Bool]) -> Verdict
  return Verdict.Unknown("the glob #{word.text} may name a symlink out of the folder") if word.glob

  return Verdict.Safe if word.text == NULL or word.text == "-"
  return Verdict.Unknown("#{word.text.inspect} is outside the session folder") if not inside.call(word.text)

  Verdict.Safe
end

# A glob that is not a path (a pattern) may still expand to names: only to plain ones that cannot be an option or a
# parent, so it starts with plain text other than `-` or `.`, or comes after `--`.
def glob_verdict(word: Parse.Word, ended: Bool) -> Verdict
  return Verdict.Unknown("the glob #{word.text} may reach another folder") if word.text.include?("/")

  first = word.text.slice(0, 1)
  if ("*?[-".include?(first) and not ended) or first == "."
    return Verdict.Unknown("the glob #{word.text} may expand to an option or a parent")
  end

  Verdict.Safe
end

def only?(text: String, allowed: String) -> Bool = not text.empty? and text.split("").all? { |c| allowed.include?(c) }

# `find [PATH...] [EXPRESSION]`: start paths inside the folder, then only the tests and actions above (no `-exec`,
# `-delete`, `-fprint`, `-L`, `-newer`).
def find(words: List[Parse.Word], inside: Fn[String, Bool]) -> Verdict
  i = 0
  while i < words.size and not words[i].text.start_with?("-") and not ["!", "(", ")"].include?(words[i].text)
    verdict = path_verdict(words[i], inside)
    return verdict if verdict != Verdict.Safe

    i = i + 1
  end

  while i < words.size
    text = words[i].text
    return Verdict.Unknown("a glob in the expression of find") if words[i].glob

    if FIND_TESTS.include?(text)
      return Verdict.Unknown("find #{text} without its value") if i + 1 >= words.size
      return Verdict.Unknown("a glob in the expression of find") if words[i + 1].glob

      i = i + 2
    elsif FIND_FLAGS.include?(text)
      i = i + 1
    else
      return Verdict.Unknown("find #{text} is not a known read-only test")
    end
  end

  Verdict.Safe
end
