## The git branch of a folder, read from `.git/HEAD` of the checkout it is in (a worktree's `.git` file points to its
## own HEAD), without running git.

import Client from "pkg/client/client"

## How many folders up the checkout is looked for.
MAX_UP = 64
## A HEAD or `.git` file larger than this is not git's.
MAX_BYTES = 4096
READ_MS = 1000
MAX_NAME = 256
HEX = "0123456789abcdef"

## The branch of the checkout `dir` is in, the short commit of a detached head, or "" outside a checkout or for a HEAD
## that is not git's.
def branch(dir: String) -> String
  at = dir
  for _ in 0...MAX_UP
    for head in option_list(head_of(at))
      return named(head)
    end

    return "" if at == "/" or at.empty? or not at.include?("/")

    at = parent(at)
  end

  ""
end

private

def head_of(dir: String) -> Optional[String]
  git = "#{dir}/.git"
  for head in option_list(small_text("#{git}/HEAD"))
    return some(head)
  end

  for text in option_list(small_text(git))
    if text.start_with?("gitdir: ")
      linked = first_line(text.slice(8, text.length - 8))
      if not linked.start_with?("/")
        linked = "#{dir}/#{linked}"
      end

      return some(small_text("#{linked}/HEAD").unwrap_or(""))
    end
  end

  none
end

# Only a small regular file is read: a FIFO or a device in its place would block or never end.
def small_text(path: String) -> Optional[String]
  case File.stat(path, READ_MS)
    ok(info) if info.kind == "file" and info.size_bytes <= MAX_BYTES ->
      case File.read_text(path, READ_MS)
        ok(text) -> some(text)
        error(_) -> none
      end

    _ -> none
  end
end

def named(head: String) -> String
  text = first_line(head)
  if text.start_with?("ref: ")
    name = text.slice(5, text.length - 5)
    if name.start_with?("refs/heads/")
      name = name.slice(11, name.length - 11)
    end

    return Client.printable(name.slice(0, [name.length, MAX_NAME].min.unwrap!))
  end

  return "" if not [40, 64].include?(text.length) or not text.split("").all? { |c| HEX.include?(c) }

  text.slice(0, 7)
end

def first_line(text: String) -> String = text.split("\n").take(1).join("").strip

def parent(dir: String) -> String
  parts = dir.split("/")
  up = parts.take(parts.size - 1).join("/")
  return "/" if up.empty?

  up
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
