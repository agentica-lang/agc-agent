## The commands of a bash line, read by tree-sitter-bash (vendored in native/, MIT): each with its text and its words
## as written. It reads only; what a command means is for the caller to decide.
##
## The module is built by the first run on a machine with a C compiler. Without one, `parse` gives an error, and so
## does a line over `MAX_LINE` bytes or one whose parse takes over `LIMIT_MS`.
##
## tree-sitter-bash 0.25.1 misreads some lines; `Parsed.unclear` is set for those known, and a caller should not
## trust the commands of such a line, nor of one with `Parsed.error` (an error may drop commands, `case ... esac | x`):
## - two backtick substitutions (`a `b` `c``) read as one command `b` `c`, and backticks in a here-document body;
## - a `-` before a redirection is dropped (`a - 2>x`);
## - a line end inside a command merges two (`a | b | c x`, a line end, then `d <<EOF`);
## - a line continuation inside a word (`a\` and a line end then `b`) splits what bash joins.
## The redirections that it puts on a pipeline, a list or a `!` (`a | b 2>x y`) are given to their last command.

import Tree from "src/tree"

VERSION = "0.0.1"
## The longest line `parse` reads, in bytes.
MAX_LINE = 65_536
## The longest a parse may take, in milliseconds.
LIMIT_MS = 200

export Tree.Word
export Tree.Command
export Tree.Parsed

## The commands of `line`, those inside subshells, groups, loops and substitutions included, in the order they start.
def parse(line: String) -> Result[Tree.Parsed]
  return error("the line is over #{MAX_LINE} bytes") if line.bytesize > MAX_LINE

  try Native.load("bash")
  Tree.commands(line, LIMIT_MS)
end
