## A conservative parser of bash commands and a check of whether one only reads, for the approval of a `bash` tool. No
## I/O.
##
## `parse` gives the pipelines of simple commands (words without their quotes, and redirections), or an error for
## anything outside a small part of bash (expansions, subshells, here-documents, ...). `read_only?` tells `Safe` only
## for commands that read inside the session folder; anything it cannot tell is `Unknown`.

import Parse from "src/parse"
import ReadOnly from "src/read_only"

VERSION = "0.0.1"

export Parse.Script
export Parse.Pipeline
export Parse.Command
export Parse.Word
export Parse.Redirect
export Parse.Join
export ReadOnly.Verdict

def parse(text: String) -> Result[Parse.Script] = Parse.parse(text)

## The words of a simple command, without their quotes.
def argv(command: Parse.Command) -> List[String] = Parse.argv(command)

## Whether `script` only reads, inside `root` (the session folder, an absolute path).
def read_only?(script: Parse.Script, root: String) -> ReadOnly.Verdict = ReadOnly.read_only?(script, root)

## The verdict of a command as text: `Unknown` when it does not parse.
def verdict(text: String, root: String) -> ReadOnly.Verdict
  case parse(text)
    ok(script) -> read_only?(script, root)
    error(e) -> ReadOnly.Verdict.Unknown(e.message)
  end
end
