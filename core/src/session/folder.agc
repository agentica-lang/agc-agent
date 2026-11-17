## The files of a session folder for a client's `@` list: breadth first, by name within a folder, without hidden
## files, links, the folders of build output and dependencies, and the paths that `hidden` (a `read_file` deny rule)
## hides. The walk stops at MAX_FILES files, MAX_DIRS folders or `walk_ms`, so a huge tree costs a bounded time; the
## list says when it was cut.
##
## The user's config can name a command that lists the files instead (`listed`). It only proposes paths: those the walk
## would never show go, whatever the command printed.

import Protocol from "pkg/protocol/protocol"
import Shell from "../tools/shell"

MAX_FILES = 5000
MAX_DIRS = 2000
WALK_MS = 2000
## The longest one read of the disk may take.
STEP_MS = 500
SKIPPED_DIRS = ["node_modules", "deps", "target", "dist", "build", "__pycache__"]
TIMEOUT = "io.timeout"
COMMAND_MS = 2000
## The most lines and bytes of the command's output that are read; the rest is cut.
MAX_LINES = 20_000
MAX_BYTES = 1_048_576

## The paths of the files under `root`, relative to it.
def files(root: String, hidden: Optional[Fn[String, Bool]], walk_ms: Int = WALK_MS) -> Protocol.FileList
  deadline = Time.monotonic_ms + walk_ms
  found: List[String] = []
  dirs = [""]
  at = 0
  cut = false
  while at < dirs.size
    return Protocol.FileList(files: found, truncated: true) if found.size >= MAX_FILES or Time.monotonic_ms >= deadline

    dir = dirs[at]
    at += 1
    names: List[String] = []
    case Dir.list(under(root, dir), STEP_MS)
      ok(listed) -> names = listed
      error(e) -> cut = cut or e.kind == TIMEOUT
    end

    for name in names
      if found.size >= MAX_FILES or Time.monotonic_ms >= deadline
        return Protocol.FileList(files: found, truncated: true)
      end

      next if name.start_with?(".") or SKIPPED_DIRS.include?(name)

      path = under(dir, name)
      next if hides?(hidden, path)

      case File.lstat(under(root, path), STEP_MS)
        ok(info) if info.kind == "directory" and dirs.size < MAX_DIRS -> dirs = dirs.push(path)
        ok(info) if info.kind == "directory" -> cut = true
        ok(info) if info.kind == "file" -> found = found.push(path)
        error(e) -> cut = cut or e.kind == TIMEOUT
        _ -> nil
      end
    end
  end

  Protocol.FileList(files: found, truncated: cut)
end

## The files of `command` (a program and its arguments, from the user's config) when it is not empty, else of the walk.
## The command runs in `root` as the bash tool runs a command: in its own process group, with a clean environment and
## no input; its standard error is dropped. Its output is read for `command_ms` at most, up to MAX_LINES lines and MAX_BYTES bytes, and a path stays
## only when it is a regular file inside `root`, reached through no link, with a printable name that `hidden` hides
## no part of. A command that fails or runs out of time gives the walk, with a note that says why.
def listed(
  root: String,
  hidden: Optional[Fn[String, Bool]],
  command: List[String],
  env: Fn[String, Result[String]],
  command_ms: Int = COMMAND_MS,
) -> Protocol.FileList
  return files(root, hidden) if command.empty?

  case proposed(root, command, env, command_ms)
    ok(output) -> kept(root, hidden, output)
    error(e) ->
      files(root, hidden).with(note: "files.command failed, so the built-in walk listed the files: #{e.message}")
  end
end

## A control character (C0, C1) or a bidi control becomes a space, as `Client.printable` does.
def printable(c: String) -> String
  code = c.code
  return " " if code < 0x20 or (code >= 0x7f and code < 0xa0) or Protocol.BIDI.include?(code)

  c
end

private

struct Output
  lines: List[String]
  cut: Bool
end

def proposed(root: String, command: List[String], env: Fn[String, Result[String]], command_ms: Int) -> Result[Output]
  # Not captured: a full pipe holds the command until the lines are read, so a long list is cut, not lost.
  options = Process.Options(chdir: root, pgroup: true, timeout_ms: command_ms + STEP_MS, err: "/dev/null")
  process = try Process.spawn("/usr/bin/env", ["-i"] + Shell.environment(env) + command, options)
  _ = Process.close_stdin(process, STEP_MS)
  result = read_output(process, Time.monotonic_ms + command_ms)
  if not result.ok? or result.unwrap!.cut
    _ = Process.signal_group(process, System.Signal.Kill)
  end

  Process.close(process)
  result
end

def read_output(process: Process, deadline: Int) -> Result[Output]
  lines: List[String] = []
  bytes = 0
  while lines.size < MAX_LINES and bytes < MAX_BYTES
    left = deadline - Time.monotonic_ms
    return error("it did not end in time") if left <= 0

    case Process.poll_line(process, left)
      ok(line) ->
        lines = lines.push(line)
        bytes += line.bytesize + 1
      error(e) if e.kind == "process.eof" -> return ended(process, lines, deadline)
      error(e) if e.kind == "process.timeout" -> return error("it did not end in time")
      error(e) -> return error(e.message)
    end
  end

  ok(Output(lines: lines, cut: true))
end

def ended(process: Process, lines: List[String], deadline: Int) -> Result[Output]
  code = try Process.wait(process, [deadline - Time.monotonic_ms, 1].max.unwrap!)
  return error("exit code #{code}") if code != 0

  ok(Output(lines: lines, cut: false))
end

def kept(root: String, hidden: Optional[Fn[String, Bool]], output: Output) -> Protocol.FileList
  deadline = Time.monotonic_ms + WALK_MS
  real_root = Path.real(root).unwrap_or(root)
  found: List[String] = []
  seen: Map[String, Bool] = {}
  for line in output.lines
    return Protocol.FileList(files: found, truncated: true) if found.size >= MAX_FILES or Time.monotonic_ms >= deadline

    path = relative(line)
    next if seen.has_key?(path)

    seen = seen.put(path, true)
    if allowed?(real_root, hidden, path)
      found = found.push(path)
    end
  end

  Protocol.FileList(files: found, truncated: output.cut)
end

def relative(line: String) -> String
  path = line
  if path.end_with?("\r")
    path = path.slice(0, path.length - 1)
  end

  while path.start_with?("./")
    path = path.slice(2, path.length - 2)
  end

  path
end

def allowed?(real_root: String, hidden: Optional[Fn[String, Bool]], path: String) -> Bool
  parts = path.split("/")
  return false if (path == "" or path.start_with?("/") or parts.any? { |p| p == "" or p == "." or p == ".." })
  return false if (path.split("").any? { |c| printable(c) != c })

  prefix = ""
  for part in parts
    prefix = under(prefix, part)
    return false if hides?(hidden, prefix)
  end

  inside = under(real_root, path)
  case Path.real(inside)
    ok(real) if real == inside -> nil
    _ -> return false
  end

  case File.stat(inside, STEP_MS)
    ok(info) -> info.kind == "file"
    error(_) -> false
  end
end

def hides?(hidden: Optional[Fn[String, Bool]], path: String) -> Bool
  case hidden
    some(rule) -> rule.call(path)
    none -> false
  end
end

def under(root: String, path: String) -> String
  return path if root == ""
  return root if path == ""

  "#{root}/#{path}"
end
