## The bash tool: a command in its own process group, in the session folder, with a clean environment and no input.
##
## Bash is not a security boundary: the command runs as the user of the server and can do what that user can. Four
## limits to know:
## - `env -i` keeps the server's keys out of the command's own environment, not out of reach: the server is the parent
##   of the command, and `/proc/$PPID/environ` of a process of the same user shows the environment it started with.
## - A timeout and a stop kill the process group. A command that leaves it (`setsid`) outlives them.
## - The files a call reaches are checked before they are used, not as they are used: a command that runs in parallel
##   can swap a folder for a link between the check and the use.
## - A read-only command that runs without asking can still hang or work long (a FIFO that never ends, a slow regex,
##   the temp files of `sort`): only the timeout bounds it.

import Shell from "pkg/shell/shell"
import Sandbox from "sandbox"
import Spec from "spec"

DEFAULT_TIMEOUT_MS = 120000
MAX_TIMEOUT_MS = 600000
KEPT_ENV = ["PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TMPDIR", "TZ", "SHELL"]
DEFAULT_PATH = "/usr/local/bin:/usr/bin:/bin"
## Where a read-only command, which may run without asking, finds its programs: those of these folders that only root
## can change (`trusted_path`). A `.` or an empty entry of the user's PATH would find a program of the folder first, and
## a folder of the user (`~/.cargo/bin`) is not trusted: a program found only there makes the command ask.
TRUSTED_DIRS = ["/usr/local/bin", "/usr/bin", "/bin"]
## Programs that bash runs itself, whatever the PATH.
BUILTINS = ["echo", "pwd", "cd", "true", "false"]

struct BashArgs
  command: String
  timeout_ms: Optional[Int]
end

def bash(ctx: Spec.Context, input: JSON.Value) -> Result[String]
  args = try Spec.args(input, BashArgs.codec)
  timeout_ms = args.timeout_ms.unwrap_or(DEFAULT_TIMEOUT_MS)
  return error("timeout_ms must be from 1 to #{MAX_TIMEOUT_MS}") if timeout_ms < 1 or timeout_ms > MAX_TIMEOUT_MS

  options = Process.Options(chdir: ctx.root, pgroup: true, timeout_ms: timeout_ms)
  env = environment(ctx.env)
  if read_only?(ctx.root, args.command)
    env = env.select { |word| not word.start_with?("PATH=") }.push("PATH=#{trusted_path(TRUSTED_DIRS)}")
  end

  words = ["-i"] + env + ["bash", "-c", args.command]
  process = try Process.spawn_captured("/usr/bin/env", words, options)
  _ = Process.close_stdin(process, 1000)
  result = finish(process, timeout_ms)
  Process.close(process)
  result
end

## `NAME=value` words for `env -i`: only the variables bash needs, so the command's environment has none of the keys of
## the server.
def environment(read: Fn[String, Result[String]]) -> List[String]
  words: List[String] = []
  for name in KEPT_ENV
    case read.call(name)
      ok(value) -> words = words.push("#{name}=#{value}")
      error(_) -> nil
    end
  end

  has_path = words.any? { |word| word.start_with?("PATH=") }
  if has_path
    words
  else
    words.push("PATH=#{DEFAULT_PATH}")
  end
end

## Whether `command` only reads inside `root` (`Shell.verdict`, its paths resolved by `Sandbox`), with programs of the
## trusted folders.
def read_only?(root: String, command: String) -> Bool
  return false if Shell.verdict(command, ->(path) { Sandbox.resolve(root, path).ok? }) != Shell.Verdict.Safe

  dirs = TRUSTED_DIRS.select(&trusted?)
  case Shell.parse(command)
    ok(script) -> script.pipelines.all? { |p| p.commands.all? { |c| found?(dirs, Shell.argv(c)) } }
    error(_) -> false
  end
end

## The folders of `dirs` that only root can change, as a PATH: owned by root and not writable by its group or others.
def trusted_path(dirs: List[String]) -> String = dirs.select(&trusted?).join(":")

private

def finish(process: Process, timeout_ms: Int) -> Result[String]
  case Process.output(process, timeout_ms)
    ok(out) -> report(out, Process.wait(process, 5000))
    error(_) ->
      _ = Process.signal_group(process, System.Signal.Kill)
      partial = Process.read_available(process, 1000).unwrap_or("")
      error("timed out after #{timeout_ms} ms and was killed\n#{partial}")
  end
end

def report(out: Process.Output, exit: Result[Int]) -> Result[String]
  text = "#{out.stdout}#{stderr_part(out.stderr)}#{cut_part(out.truncated)}"
  case exit
    ok(0) -> ok(text)
    ok(code) -> error("exit code #{code}\n#{text}")
    error(e) -> error("the command did not exit: #{e.message}\n#{text}")
  end
end

def stderr_part(stderr: String) -> String
  if stderr == ""
    ""
  else
    "\n[stderr]\n#{stderr}"
  end
end

def cut_part(truncated: Bool) -> String
  if truncated
    "\n[output cut at 1 MiB]"
  else
    ""
  end
end

def trusted?(dir: String) -> Bool
  case File.stat(dir)
    ok(info) -> info.user_id == 0 and (info.mode / 16) % 2 == 0 and (info.mode / 2) % 2 == 0
    error(_) -> false
  end
end

def found?(dirs: List[String], words: List[String]) -> Bool
  return true if words.empty? or BUILTINS.include?(words[0])

  dirs.any? { |dir| File.stat("#{dir}/#{words[0]}").ok? }
end
