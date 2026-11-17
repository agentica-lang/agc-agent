## The native module of the package: tree-sitter-bash (vendored in native/, MIT) reads a line of bash. The header
## native/bash_native.h is made from this block by native-gen (`make native-header`).

## A word of a command: its tree-sitter node type (`word`, `string`, `raw_string`, `concatenation`,
## `simple_expansion`, `command_substitution`, ...) and its text as written, quotes kept.
struct Word
  kind: String
  text: String
end

## A simple command of a line: its text (with the redirections of its statement), and its name and arguments.
## Assignments before the name and redirections are not words.
struct Command
  text: String
  words: List[Word]
end

## The commands of a line, in the order they start, those inside a subshell, a group, a substitution or a loop
## included; and whether the parse found a syntax error.
struct Parsed
  commands: List[Command]
  error: Bool
end

extern module "bash"
  ## The commands of `line`, read by tree-sitter-bash.
  def commands(line: String) -> Parsed
end
