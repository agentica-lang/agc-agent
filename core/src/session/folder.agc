## The files of a session folder for a client's `@` list: breadth first, sorted by name within a folder, without
## hidden files, links and the folders of build output and dependencies.

MAX_FILES = 5000
## The folders waiting to be read; a tree wider than this is cut.
MAX_QUEUED = 1000
SKIPPED_DIRS = ["node_modules", "deps", "target", "dist", "build", "__pycache__"]

## The paths of the files under `root`, relative to it, at most MAX_FILES.
def files(root: String) -> List[String]
  found: List[String] = []
  dirs = [""]
  while not dirs.empty? and found.size < MAX_FILES
    dir = dirs[0]
    dirs = dirs.drop(1)
    names: List[String] = Dir.list(under(root, dir)).unwrap_or([])
    for name in names.sort
      next if name.start_with?(".") or SKIPPED_DIRS.include?(name)

      path = under(dir, name)
      case File.lstat(under(root, path))
        ok(info) if info.kind == "directory" and dirs.size < MAX_QUEUED -> dirs = dirs.push(path)
        ok(info) if info.kind == "file" -> found = found.push(path)
        _ -> nil
      end
    end
  end

  found.take(MAX_FILES)
end

private

def under(root: String, path: String) -> String
  return path if root == ""
  return root if path == ""

  "#{root}/#{path}"
end
