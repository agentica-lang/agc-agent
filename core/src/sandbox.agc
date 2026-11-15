## The path rule: a tool reaches only files whose real path is inside the session folder.

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
def resolve(root: String, path: String) -> Result[String]
  return error("empty path") if path == ""

  found = try nearest(absolute(root, path).split("/").select { |part| part != "" }, [])
  for name in found.tail
    return error("path has #{name}: #{path}") if name == ".." or name == "."
  end

  if found.tail.size > 0 and File.lstat(join(found.real, found.tail.take(1))).ok?
    return error("unreadable or broken link: #{path}")
  end

  resolved = join(found.real, found.tail)
  return error("outside the session folder: #{path}") if not inside?(root, found.real)

  ok(resolved)
end

def relative(root: String, path: String) -> String
  return "." if path == root

  path.slice(root.length + 1, path.length - root.length - 1)
end

def inside?(root: String, path: String) -> Bool = path == root or root == "/" or path.start_with?("#{root}/")

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
