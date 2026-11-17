## The git branch of a folder, read from `.git/HEAD` of the checkout it is in (a worktree's `.git` file points to its
## own HEAD), without running git.

## How many folders up the checkout is looked for.
MAX_UP = 64

## The branch of the checkout `dir` is in, the short commit of a detached head, or "" outside a checkout.
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
  case File.read_text("#{git}/HEAD")
    ok(text) -> return some(text)
    error(_) -> nil
  end

  case File.read_text(git)
    ok(text) if text.start_with?("gitdir: ") ->
      linked = text.slice(8, text.length - 8).strip
      if not linked.start_with?("/")
        linked = "#{dir}/#{linked}"
      end

      case File.read_text("#{linked}/HEAD")
        ok(head) -> some(head)
        error(_) -> none
      end

    _ -> none
  end
end

def named(head: String) -> String
  text = head.strip
  return text.slice(16, text.length - 16) if text.start_with?("ref: refs/heads/")
  return text.slice(5, text.length - 5) if text.start_with?("ref: ")

  text.slice(0, 7)
end

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
