## The commands of a bash line, read by tree-sitter-bash (vendored in native/, MIT): each with its text and its words
## as written. It reads only; what a command means is for the caller to decide.
##
## The module is built by the first run on a machine with a C compiler (a fetched package never builds it from source:
## it uses the prebuilt library of its release). Without the module, `parse` gives an error, and so
## does a line over `MAX_LINE` bytes, one with over `MAX_PIPES` `|`, or one whose parse takes over `LIMIT_MS`.
##
## tree-sitter-bash 0.25.1 misreads some lines; `Parsed.unclear` is set for those known, and a caller should not
## trust the commands of such a line, nor of one with `Parsed.error` (an error may drop commands, `case ... esac | x`):
## - two backtick substitutions (`a `b` `c``) read as one command `b` `c`, and backticks in a here-document body;
## - a `-` before a redirection is dropped (`a - 2>x`);
## - a line end inside a command merges two (`a | b | c x`, a line end, then `d <<EOF`), and so after `export`;
## - the words after a here-document of an assignment alone (`V=1 <<EOF rm x`) are lost;
## - backticks nested without escapes (`a `V=`b` c``) read as one substitution in another;
## - a line continuation inside a word (`a\` and a line end then `b`) splits what bash joins.
## The redirections that it puts on a pipeline, a list or a `!` (`a | b 2>x y`) are given to their last command, and
## those it puts inside a here-document's (`git <<EOF 2>x push`) to the command.

import Tree from "src/tree"

VERSION = "0.0.1"
## The longest line `parse` reads, in bytes.
MAX_LINE = 65_536
## The longest a parse may take, in milliseconds.
LIMIT_MS = 200
## The most `|` a line may hold. tree-sitter checks `LIMIT_MS` while it reads, but not while it builds the tree of a
## line with an error at its end, which takes time quadratic in the length of a pipeline (`a|a|...a|`): on a laptop
## 1,000 stages take 60 ms, 2,000 take 0.17 s, 8,000 take 1.6 s and 16,000 take 16 s.
MAX_PIPES = 1_000

export Tree.Word
export Tree.Command
export Tree.Parsed

## The commands of `line`, those inside subshells, groups, loops and substitutions included, in the order they start.
def parse(line: String) -> Result[Tree.Parsed]
  return error("the line is over #{MAX_LINE} bytes") if line.bytesize > MAX_LINE
  return error("the line has over #{MAX_PIPES} |") if line.split("|").length - 1 > MAX_PIPES

  loaded = Native.load("bash")
  if !loaded.ok?
    return error("the native module of bash is not built (#{loaded.message}); in a clone, run `make install`")
  end

  Tree.commands(line, LIMIT_MS)
end
