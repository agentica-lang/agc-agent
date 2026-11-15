## The bash tool: a command in its own process group, in the session folder, with a clean environment and no input.

import Spec from "spec"

DEFAULT_TIMEOUT_MS = 120000
MAX_TIMEOUT_MS = 600000
KEPT_ENV = ["PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TMPDIR", "TZ", "SHELL"]
DEFAULT_PATH = "/usr/local/bin:/usr/bin:/bin"

struct BashArgs
  command: String
  timeout_ms: Optional[Int]
end

def bash(ctx: Spec.Context, input: JSON.Value) -> Result[String]
  args = try Spec.args(input, BashArgs.codec)
  timeout_ms = args.timeout_ms.unwrap_or(DEFAULT_TIMEOUT_MS)
  return error("timeout_ms must be from 1 to #{MAX_TIMEOUT_MS}") if timeout_ms < 1 or timeout_ms > MAX_TIMEOUT_MS

  options = Process.Options(chdir: ctx.root, pgroup: true, timeout_ms: timeout_ms)
  words = ["-i"] + environment(ctx.env) + ["bash", "-c", args.command]
  process = try Process.spawn_captured("env", words, options)
  _ = Process.close_stdin(process, 1000)
  result = finish(process, timeout_ms)
  Process.close(process)
  result
end

## `NAME=value` words for `env -i`: only the variables bash needs, so no key or token of the server reaches a command.
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
