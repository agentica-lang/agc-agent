## Where the session files live: a record of the functions `Store` reads and writes them with, by path. `disk` keeps
## them in the data folder; `memory` keeps them in a table, for tests that need no folder. `memory` has only the
## folders it is given, and answers as `disk` does: the same error kinds (`io.not_found`, `io.exists`, `io.too_large`,
## `io.eof`), the same line limit (a line with its newline), and CRLF read as a line end.

## The size of a file and its time of change: `modified` is in seconds on disk and counts the writes in memory.
struct Stat
  size: Int
  modified: Int
end

## Every line of a file without its newline (the last one also when it has none), and the size of the file before
## they were read.
struct Content
  lines: List[String]
  size: Int
end

struct Port
  ## Makes the file with `text` (0600), refused when it is there.
  create: Fn[String, String, Result[Void]]
  append: Fn[String, String, Result[Void]]
  ## The reads of a session file refuse what is not a regular file (a link). `read` refuses a line over `max_line`.
  read: Fn[String, Result[Content]]
  first_line: Fn[String, Result[String]]
  head: Fn[String, Int, Result[Bytes]]
  stat: Fn[String, Result[Stat]]
  ## The names of the files of a folder.
  names: Fn[String, Result[List[String]]]
  remove: Fn[String, Result[Void]]
  ## A small file beside a session's, replaced whole (0600), and its text.
  replace: Fn[String, String, Result[Void]]
  read_text: Fn[String, Result[String]]
end

def disk(max_line: Int, max_write: Int) -> Port
  Port(
    create: ->(path: String, text: String) { create_file(path, text) },
    append: ->(path: String, text: String) { append_file(path, text, max_write) },
    read: ->(path: String) { read_file(path, max_line) },
    first_line: ->(path: String) { first_of(path) },
    head: ->(path: String, bytes: Int) { head_of(path, bytes) },
    stat: ->(path: String) { stat_of(path) },
    names: ->(dir: String) { Dir.list(dir) },
    remove: ->(path: String) { remove_file(path) },
    replace: ->(path: String, text: String) { replace_file(path, text) },
    read_text: ->(path: String) { File.read_text(path) },
  )
end

## The files in a table: `folders` are the folders that are there.
def memory(max_line: Int, folders: List[String]) -> Port
  files: ATS[String, List[String]] = ATS.new()
  writes: ATS[String, Int] = ATS.new()
  dirs = folders.map { |dir| folder_name(dir) }
  text_of = ->(path: String) { text_in(files, path) }
  Port(
    create: ->(path: String, text: String) { created(files, writes, dirs, path, text) },
    append: ->(path: String, text: String) { appended(files, writes, dirs, path, text) },
    read: ->(path: String) { content_of(try text_of.call(path), max_line) },
    first_line: ->(path: String) { first_in(try text_of.call(path)) },
    head: ->(path: String, bytes: Int) { ok((try text_of.call(path)).bytes.take(bytes)) },
    stat: ->(path: String) {
      text = try text_of.call(path)
      ok(Stat(size: text.bytesize, modified: writes.get(path).unwrap_or(0)))
    },
    names: ->(dir: String) { listed(files.keys, dirs, dir) },
    remove: ->(path: String) { removed(files, path) },
    replace: ->(path: String, text: String) {
      files.put(path, [text])
      ok()
    },
    read_text: ->(path: String) { text_of.call(path) },
  )
end

private

def create_file(path: String, text: String) -> Result[Void]
  handle = try File.open(path, "create_private")
  written = File.write(handle, text)
  try File.close(handle)
  written
end

def append_file(path: String, text: String, max_write: Int) -> Result[Void]
  bytes = text.bytes
  File.open(path, "append") do |handle|
    start = 0
    while start < bytes.size
      try File.write_bytes(handle, bytes.drop(start).take(max_write))
      start = start + max_write
    end

    ok()
  end
end

def regular(path: String) -> Result[Void]
  return error("#{path}: not a regular file") if (try File.lstat(path)).kind != "file"

  ok()
end

def read_file(path: String, max_line: Int) -> Result[Content]
  try regular(path)
  size = (try File.stat(path)).size_bytes
  ok(Content(lines: try File.foreach(path, max_line).to_a, size: size))
end

def first_of(path: String) -> Result[String]
  try regular(path)
  File.open(path, "read") do |handle| File.read_line(handle) end
end

def head_of(path: String, bytes: Int) -> Result[Bytes]
  try regular(path)
  File.open(path, "read") do |handle| File.read_bytes(handle, bytes) end
end

def stat_of(path: String) -> Result[Stat]
  try regular(path)
  info = try File.stat(path)
  ok(Stat(size: info.size_bytes, modified: info.modified_seconds))
end

def remove_file(path: String) -> Result[Void]
  try regular(path)
  Path.remove(path)
end

# Onto what a symbolic link at `path` points to, so the link stays; the new file is made beside it, on its file system.
def replace_file(path: String, text: String) -> Result[Void]
  target = Path.real(path).unwrap_or(path)
  temporary = "#{target}.tmp"
  _ = Path.remove(temporary)
  try create_file(temporary, text)
  replaced = Path.replace(temporary, target)
  if not replaced.ok?
    _ = Path.remove(temporary)
  end

  replaced
end

def text_in(files: ATS[String, List[String]], path: String) -> Result[String]
  case files.get(path)
    ok(parts) -> ok(parts.join(""))
    error(_) -> not_found(path)
  end
end

def not_found[T](path: String) -> Result[T] = error("#{path}: no such file or folder", kind: "io.not_found")

def folder_name(dir: String) -> String
  return dir if dir == "/" or not dir.end_with?("/")

  dir.slice(0, dir.length - 1)
end

def folder_of(path: String) -> String
  parts = path.split("/")
  folder_name(parts.take(parts.size - 1).join("/"))
end

def created(
  files: ATS[String, List[String]],
  writes: ATS[String, Int],
  dirs: List[String],
  path: String,
  text: String,
) -> Result[Void]
  return not_found(path) if not dirs.include?(folder_of(path))
  return error("#{path}: already there", kind: "io.exists") if not files.put_new(path, [text])

  _ = writes.add(path, 1)
  ok()
end

# As `File.open(path, "append")`, a missing file in a folder that is there is made.
def appended(
  files: ATS[String, List[String]],
  writes: ATS[String, Int],
  dirs: List[String],
  path: String,
  text: String,
) -> Result[Void]
  return created(files, writes, dirs, path, text) if not files.has_key?(path)

  _ = files.push(path, text)
  _ = writes.add(path, 1)
  ok()
end

def removed(files: ATS[String, List[String]], path: String) -> Result[Void]
  return not_found(path) if not files.has_key?(path)

  files.delete(path)
  ok()
end

# The lines as `File.foreach` gives them: split at each newline, none after a last newline, a `\r` before a newline
# dropped; a line with its newline over `max_line` bytes is refused.
def content_of(text: String, max_line: Int) -> Result[Content]
  lines: List[String] = []
  for line in lines_of(text)
    ended = line.end_with?("\n")
    body = line
    if ended
      body = line.slice(0, line.length - 1)
    end

    return error("a line is over #{max_line} bytes", kind: "io.too_large") if line.bytesize > max_line

    if ended and body.end_with?("\r")
      body = body.slice(0, body.length - 1)
    end

    lines = lines.push(body)
  end

  ok(Content(lines: lines, size: text.bytesize))
end

def first_in(text: String) -> Result[String]
  return error("end of file", kind: "io.eof") if text.empty?

  line = lines_of(text)[0]
  return ok(line) if not line.end_with?("\n")

  body = line.slice(0, line.length - 1)
  return ok(body.slice(0, body.length - 1)) if body.end_with?("\r")

  ok(body)
end

# Each line with its newline, the last one without when it has none.
def lines_of(text: String) -> List[String]
  return [] if text.empty?

  parts = "#{text}x".split("\n")
  lines = parts.take(parts.size - 1).map { |part| "#{part}\n" }
  last = parts.last
  return lines if last == "x"

  lines.push(last.slice(0, last.length - 1))
end

def listed(paths: List[String], dirs: List[String], dir: String) -> Result[List[String]]
  folder = folder_name(dir)
  return not_found(dir) if not dirs.include?(folder)

  prefix = "#{folder}/"
  if folder == "/"
    prefix = "/"
  end

  under = paths.select { |path| path.start_with?(prefix) }
  names = under.map { |path| path.slice(prefix.length, path.length - prefix.length) }

  ok(names.select { |name| not name.include?("/") })
end
