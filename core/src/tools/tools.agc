## The six base tools, and what a call touches.
##
## Security model. The tools keep a call inside the session folder and the approval rules (when the approval extension
## is on) decide what asks, but neither is a sandbox:
## - An allow pattern is a convenience. Allowing a program allows every option it takes and every config file it reads:
##   `bash(git diff*)` allows `git diff --output=../x`, which writes outside the folder, `bash(git *)` allows
##   `git -c alias.x=!cmd x`, which runs `cmd`, and `bash(cat src/*)` allows `cat src/../../outside/secret`. Allow only
##   what is harmless with every option and argument.
## - A bash rule matches only a plain command, so a deny rule of `bash` is best effort: `rm x; true` asks and is not
##   denied. A command that is not plain always asks, never runs on a rule.
## - A deny rule of `read_file` also denies `edit_file` and hides the file from `glob` and `grep`.
## - Bash runs as the user of the server and can read what the server reads (see `Shell`). A path is checked before it
##   is used, and bash is the only way to run something in parallel, so the check can race with a swapped link.
## - On a case-insensitive filesystem a rule on `.env` may not match `.ENV`.

import Diff from "diff"
import Files from "files"
import Patch from "patch"
import Sandbox from "sandbox"
import Search from "search"
import Shell from "shell"
import Spec from "spec"

export Spec.Context
export Spec.Output
export Spec.Tool
export Spec.TurnTool
export Spec.TurnOutput
export Spec.output
export Spec.Verdict

PATCH = Patch.NAME

## The context of a session in `cwd`: the real path of the folder, where bash reads its few environment variables, and
## the tools `more` after the base ones.
def context(
  cwd: String,
  env: Fn[String, Result[String]],
  more: List[Spec.Tool] = [],
  late: Optional[Fn[List[Spec.Tool]]] = none,
) -> Result[Spec.Context]
  root = try Sandbox.open(cwd)
  ok(Spec.Context(root: root, env: env, tools: more, late: late))
end

## The tools a session offers the model: the base ones, then those of its context.
def offered(ctx: Spec.Context) -> List[Spec.Tool] = all() + Spec.more_tools(ctx)

def all() -> List[Spec.Tool]
  [
    Spec.Tool(
      name: "read_file",
      description: (
        "Read a text file of the session folder. Lines from `offset` (0 is the first), at most `limit` " +
        "(5000) and 27000 characters; the answer says where to continue. Over 1 MiB, line ends are not shown, " +
        "and a line over 1 MiB stops the read, with a note."
      ),
      input_schema: JSON.schema(Files.ReadFileArgs),
      asks: false,
      run: &Files.read_file,
      target: &Files.read_target,
    ),
    Spec.Tool(
      name: "write_file",
      description: "Create a file, or replace it, with `content`. Missing folders are created.",
      input_schema: JSON.schema(Files.WriteFileArgs),
      asks: true,
      run: &Files.write_file,
      target: &Files.write_target,
    ),
    Spec.Tool(
      name: "edit_file",
      description: (
        "Replace `old_string` with `new_string` in a file. It must occur once, unless `replace_all` is true."
      ),
      input_schema: JSON.schema(Files.EditFileArgs),
      asks: true,
      run: &Files.edit_file,
      target: &Files.edit_target,
    ),
    Spec.Tool(
      name: "glob",
      description: "List the files whose path under `path` (default `.`) matches a pattern such as `**/*.agc`.",
      input_schema: JSON.schema(Search.GlobArgs),
      asks: false,
      run: &Search.glob,
      target: &Search.glob_target,
    ),
    Spec.Tool(
      name: "grep",
      description: "Find the lines that match a regex in the files under `path`, only those matching the `glob`.",
      input_schema: JSON.schema(Search.GrepArgs),
      asks: false,
      run: &Search.grep,
      target: &Search.grep_target,
    ),
    Spec.Tool(
      name: "bash",
      description: "Run a command with bash in the session folder. It has no input. `timeout_ms` is at most 600000.",
      input_schema: JSON.schema(Shell.BashArgs),
      asks: true,
      run: &Shell.bash,
      target: &command_target,
    ),
  ]
end

## `apply_patch`, which only OpenAI models are offered (see `Patch`).
def patch() -> Spec.Tool = Patch.tool()

## The grammar of `apply_patch` as a custom tool.
def patch_grammar() -> JSON.Value = Patch.grammar()

def find(name: String) -> Result[Spec.Tool]
  found = all().push(Patch.tool()).find { |tool| tool.name == name }
  case found
    ok(tool) -> ok(tool)
    error(_) -> error("unknown tool: #{name}")
  end
end

## Runs the call. A failure, a refused path and a failed command are an output with `is_error`.
def run(ctx: Spec.Context, name: String, input: JSON.Value) -> Spec.Output
  case offered_tool(ctx, name)
    ok(tool) -> Spec.output(tool.run(ctx, input))
    error(e) -> Spec.Output(text: e.message, is_error: true)
  end
end

## The tool of that name the session offers: one of its context, else a base tool or `apply_patch`.
def offered_tool(ctx: Spec.Context, name: String) -> Result[Spec.Tool]
  case (Spec.more_tools(ctx).find { |tool| tool.name == name })
    ok(tool) -> ok(tool)
    error(_) -> find(name)
  end
end

## What a call touches, for the approval preview and the notices: the path or the command.
def target(ctx: Spec.Context, name: String, input: JSON.Value) -> Result[String]
  tool = try offered_tool(ctx, name)
  tool.target(ctx, input)
end

## What a call would write, for the approval: the content of `write_file`, the old text of `edit_file` with each line
## marked `-` and the new text marked `+`, or the patch of `apply_patch`, cut to `DETAIL_CHARS`; empty for the other
## tools.
def detail(name: String, input: JSON.Value) -> String
  case name
    "write_file" ->
      case Spec.args(input, Files.WriteFileArgs.codec)
        ok(args) -> cut(args.content)
        error(_) -> ""
      end

    "edit_file" ->
      case Spec.args(input, Files.EditFileArgs.codec)
        ok(args) -> cut("#{marked("-", args.old_string)}\n#{marked("+", args.new_string)}")
        error(_) -> ""
      end

    "apply_patch" -> cut(Patch.args(input).unwrap_or(""))
    _ -> ""
  end
end

## What a call of `edit_file` or `write_file` would change, as numbered lines, read before it runs; none for the other
## tools or a call it cannot read.
def change(ctx: Spec.Context, name: String, input: JSON.Value) -> Optional[String]
  case name
    "edit_file" ->
      case Spec.args(input, Files.EditFileArgs.codec)
        ok(args) -> nonempty(Diff.edit(text_of(ctx, args.path), args.old_string, args.new_string))
        error(_) -> none
      end

    "write_file" ->
      case Spec.args(input, Files.WriteFileArgs.codec)
        ok(args) -> nonempty(Diff.written(args.content))
        error(_) -> none
      end

    _ -> none
  end
end

## The first lines of a result for the clients, none when it has one line at most (its summary shows it).
def shown_output(text: String) -> Optional[String]
  lines = text.strip.split("\n")
  return none if lines.size <= 1

  shown = lines.take(OUTPUT_LINES)
  if lines.size > OUTPUT_LINES
    shown = shown.push("... #{lines.size - OUTPUT_LINES} more lines")
  end

  some(cut(shown.join("\n")))
end

private

DETAIL_CHARS = 4000
OUTPUT_LINES = 40

# The text of a file in the session folder, "" when it cannot be read.
def text_of(ctx: Spec.Context, path: String) -> String
  case Sandbox.resolve(ctx.root, path)
    ok(found) -> File.read_text(found).unwrap_or("")
    error(_) -> ""
  end
end

def nonempty(text: String) -> Optional[String]
  return none if text == ""

  some(text)
end

def cut(text: String) -> String
  return text if text.length <= DETAIL_CHARS

  "#{text.slice(0, DETAIL_CHARS)}\n[cut: #{text.length} characters]"
end

def marked(mark: String, text: String) -> String = text.split("\n").map { |line| "#{mark} #{line}" }.join("\n")

def command_target(_ctx: Spec.Context, input: JSON.Value) -> Result[String]
  args = try Spec.args(input, Shell.BashArgs.codec)
  ok(args.command.strip)
end
