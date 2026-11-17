## The simple commands of a bash line, read by tree-sitter-bash (vendored in native/, MIT): each with its text and its
## words as written. It reads only; what a command means is for the caller to decide.
##
## The module is built by the first run on a machine with a C compiler. Without one, `parse` gives an error, and so
## does a line over `MAX_LINE` bytes.

import Tree from "src/tree"

VERSION = "0.0.1"
## The longest line `parse` reads, in bytes.
MAX_LINE = 65536

export Tree.Word
export Tree.Command
export Tree.Parsed

## The commands of `line`, those inside subshells, groups, loops and substitutions included, in the order they start.
def parse(line: String) -> Result[Tree.Parsed]
  return error("the line is over #{MAX_LINE} bytes") if line.bytesize > MAX_LINE

  try Native.load("bash")
  ok(Tree.commands(line))
end
