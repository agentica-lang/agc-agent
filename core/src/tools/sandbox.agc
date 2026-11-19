## The path rule: with the confinement on, a tool reaches only files whose real path is inside the session folder; with
## it off, any path.

struct Found
  real: String
  tail: List[String]
end

def open(cwd: String) -> Result[String]
  root = try Path.real(cwd)
  info = try File.stat(root)
  return error("not a folder: #{cwd}") if info.kind != "directory"

  ok(root)
end

## The absolute path of `path` (relative to `root`, or absolute) with `..` and links resolved, or an error when it
## leaves `root`. The path may not exist yet: its last existing folder is resolved, the rest must be plain names.
def resolve(root: String, path: String) -> Result[String] = reach(root, path, true)

## `resolve`, where `confine` off lets the path be anywhere: the other checks (control characters, `..` in the part
## that does not exist, a broken link) stay.
def reach(root: String, path: String, confine: Bool) -> Result[String]
  return error("empty path") if path == ""

  control = path.split("").any? { |char| char.code < 32 or char.code == 127 }
  return error("path has a control character: #{path.inspect}") if control

  found = try nearest(absolute(root, path).split("/").select { |part| part != "" }, [])
  for name in found.tail
    return error("path has #{name}: #{path}") if name == ".." or name == "."
  end

  if found.tail.size > 0 and File.lstat(join(found.real, found.tail.take(1))).ok?
    return error("unreadable or broken link: #{path}")
  end

  resolved = join(found.real, found.tail)
  return error("outside the session folder: #{path}") if confine and not inside?(root, found.real)

  ok(resolved)
end

## `path` relative to `root`; a path outside it stays absolute.
def relative(root: String, path: String) -> String
  return "." if path == root
  return path if not inside?(root, path)
  return path.slice(1, path.length - 1) if root == "/"

  path.slice(root.length + 1, path.length - root.length - 1)
end

def inside?(root: String, path: String) -> Bool = path == root or root == "/" or path.start_with?("#{root}/")

## The size of `path` when it is a regular file whose real path (its links followed) is inside the real `dir`; none
## for a link out of `dir`, a folder, a FIFO or anything else.
def file_inside(dir: String, path: String) -> Optional[Int]
  size = case File.stat(path)
    ok(found) if found.kind == "file" -> found.size_bytes
    _ -> -1
  end

  return none if size < 0

  real_dir = Path.real(dir).unwrap_or("")
  real = Path.real(path).unwrap_or("")
  return none if real_dir.empty? or real.empty? or not inside?(real_dir, real)

  some(size)
end

## Whether `root` is one of the folders `dirs` or below one (a folder is the real path of what it names).
def trusted?(dirs: List[String], root: String) -> Bool
  dirs.any? { |dir| inside?(Path.real(dir).unwrap_or(dir), root) }
end

def parent(path: String) -> String
  parts = path.split("/")
  parent_parts = parts.take(parts.size - 1)
  if parent_parts.size <= 1
    "/"
  else
    parent_parts.join("/")
  end
end

private

def nearest(parts: List[String], tail: List[String]) -> Result[Found]
  candidate = "/#{parts.join("/")}"
  case Path.real(candidate)
    ok(real) -> ok(Found(real: real, tail: tail))
    error(e) ->
      return error(e.message) if parts.empty?

      nearest(parts.take(parts.size - 1), [parts.last] + tail)
  end
end

def absolute(root: String, path: String) -> String
  if path.start_with?("/")
    path
  else
    "#{root}/#{path}"
  end
end

def join(real: String, tail: List[String]) -> String
  return real if tail.empty?

  if real == "/"
    "/#{tail.join("/")}"
  else
    "#{real}/#{tail.join("/")}"
  end
end
