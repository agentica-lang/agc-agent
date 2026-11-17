## The native module of the package: tree-sitter-bash (vendored in native/, MIT) reads a line of bash. The header
## native/bash_native.h is made from this block by native-gen (`make native-header`).

## A word of a command: its tree-sitter node type and its text as written, quotes and escapes kept. The name of a
## command is always `command_name`; an argument is `word`, `string`, `raw_string`, `concatenation`,
## `simple_expansion`, `command_substitution` and so on. A statement that is not a simple command (`export`,
## `declare`, `local`, `readonly`, `typeset`, `unset`, `[ ]`, `[[ ]]`, or assignments with no command, `x=1`) is
## one word whose kind is its node type (`declaration_command`, `unset_command`, `test_command`, `variable_assignment`,
## `variable_assignments`) and whose text is the whole statement. An assignment before a command's name is not one.
struct Word
  kind: String
  text: String
end

## A command of a line: its text (with the redirections of its statement), and its name and arguments, those written
## after a redirection (`cmd >out x`, `cmd <<EOF x`) included. Assignments before the name are not words.
struct Command
  text: String
  words: List[Word]
end

## The commands of a line, in the order they start, those inside a subshell, a group, a substitution or a loop
## included. `error`: the parse found a syntax error. `unclear`: tree-sitter-bash may have read other commands than
## bash runs: a backtick that is not the edge of a command substitution (in a word, a redirection or a here-document
## body), text between nodes that it skipped, a line end inside a command, or a line continuation inside a word.
struct Parsed
  commands: List[Command]
  error: Bool
  unclear: Bool
end

extern module "bash"
  ## The commands of `line`, read by tree-sitter-bash; an error when the parse takes over `limit_ms`, or when the
  ## commands hold over 1 MiB of text (a substitution's text is in the command around it too).
  compute def commands(line: String, limit_ms: Int) -> Result[Parsed]
end
