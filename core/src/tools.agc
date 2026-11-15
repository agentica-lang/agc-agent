## The six base tools, and the rules around them: which run without asking, and what a call touches.

import Approval from "approval"
import Files from "files"
import Sandbox from "sandbox"
import Search from "search"
import Shell from "shell"
import Spec from "spec"

export Spec.Context
export Spec.Output
export Spec.Tool
export Approval.Verdict
export Approval.Rules

## The context of a session in `cwd`: the real path of the folder, and where bash reads its few environment variables.
def context(cwd: String, env: Fn[String, Result[String]]) -> Result[Spec.Context]
  root = try Sandbox.open(cwd)
  ok(Spec.Context(root: root, env: env))
end

def all() -> List[Spec.Tool]
  [
    Spec.Tool(
      name: "read_file",
      description: "Read a text file of the session folder. Lines from `offset` (0 is the first), at most `limit`.",
      input_schema: JSON.schema(Files.ReadFileArgs),
      asks: false,
      run: &Files.read_file,
      target: &Files.path_target,
    ),
    Spec.Tool(
      name: "write_file",
      description: "Create a file, or replace it, with `content`. Missing folders are created.",
      input_schema: JSON.schema(Files.WriteFileArgs),
      asks: true,
      run: &Files.write_file,
      target: &Files.path_target,
    ),
    Spec.Tool(
      name: "edit_file",
      description: (
        "Replace `old_string` with `new_string` in a file. It must occur once, unless `replace_all` is true."
      ),
      input_schema: JSON.schema(Files.EditFileArgs),
      asks: true,
      run: &Files.edit_file,
      target: &Files.path_target,
    ),
    Spec.Tool(
      name: "glob",
      description: "List the files whose path under `path` (default `.`) matches a pattern such as `**/*.agc`.",
      input_schema: JSON.schema(Search.GlobArgs),
      asks: false,
      run: &Search.glob,
      target: &Files.path_target,
    ),
    Spec.Tool(
      name: "grep",
      description: "Find the lines that match a regex in the files under `path`, only those matching the `glob`.",
      input_schema: JSON.schema(Search.GrepArgs),
      asks: false,
      run: &Search.grep,
      target: &Files.path_target,
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

def find(name: String) -> Result[Spec.Tool]
  found = all().find { |tool| tool.name == name }
  case found
    ok(tool) -> ok(tool)
    error(_) -> error("unknown tool: #{name}")
  end
end

## Runs the call. A failure, a refused path and a failed command are an output with `is_error`.
def run(ctx: Spec.Context, name: String, input: JSON.Value) -> Spec.Output
  case find(name)
    ok(tool) -> Spec.output(tool.run(ctx, input))
    error(e) -> Spec.Output(text: e.message, is_error: true)
  end
end

## Whether a call runs, waits for an answer or is refused. A path that leaves the folder is not asked about: the tool
## refuses it when it runs.
def verdict(ctx: Spec.Context, rules: Approval.Rules, name: String, input: JSON.Value) -> Approval.Verdict
  case find(name)
    ok(tool) -> verdict_of(ctx, rules, tool, input)
    error(_) -> Approval.Verdict.Deny
  end
end

## What a call touches, for the approval preview and the notices: the path or the command.
def target(ctx: Spec.Context, name: String, input: JSON.Value) -> Result[String]
  tool = try find(name)
  tool.target(ctx, input)
end

private

def verdict_of(ctx: Spec.Context, rules: Approval.Rules, tool: Spec.Tool, input: JSON.Value) -> Approval.Verdict
  case tool.target(ctx, input)
    ok(target) -> Approval.decide(rules, tool.name, target, tool.asks)
    error(_) -> Approval.Verdict.Allow
  end
end

def command_target(_ctx: Spec.Context, input: JSON.Value) -> Result[String]
  args = try Spec.args(input, Shell.BashArgs.codec)
  ok(args.command.strip)
end
