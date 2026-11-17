## The files of a session folder for a client's `@` list: breadth first, by name within a folder, without hidden
## files, links, the folders of build output and dependencies, and the paths that `hidden` (a `read_file` deny rule)
## hides. The walk stops at MAX_FILES files, MAX_DIRS folders or `walk_ms`, so a huge tree costs a bounded time; the
## list says when it was cut.

import Protocol from "pkg/protocol/protocol"

MAX_FILES = 5000
MAX_DIRS = 2000
WALK_MS = 2000
## The longest one read of the disk may take.
STEP_MS = 500
SKIPPED_DIRS = ["node_modules", "deps", "target", "dist", "build", "__pycache__"]
TIMEOUT = "io.timeout"

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

private

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
