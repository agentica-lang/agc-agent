## The tools that look for files and text: glob and grep. They list only real files and never follow a link, so
## nothing outside the session folder is reached through one.

import Regex from "std/regex"
import Sandbox from "sandbox"
import Spec from "spec"

MAX_FILES = 10000
MAX_DEPTH = 32
MAX_RESULTS = 500
MAX_FILE_BYTES = 1048576
MAX_LINE_CHARS = 300

struct GlobArgs
  pattern: String
  path: Optional[String]
end

struct GrepArgs
  pattern: String
  path: Optional[String]
  glob: Optional[String]
end

def glob(ctx: Spec.Context, input: JSON.Value) -> Result[String]
  args = try Spec.args(input, GlobArgs.codec)
  matcher = try glob_regex(args.pattern)
  base = try folder(ctx, args.path)
  files = try walk(base, "", 0, [])
  found = files.select { |file| Regex.match?(file, matcher) }
  lines = found.take(MAX_RESULTS).map { |file| Sandbox.relative(ctx.root, "#{base}/#{file}") }
  ok(listing(lines, found.size))
end

def grep(ctx: Spec.Context, input: JSON.Value) -> Result[String]
  args = try Spec.args(input, GrepArgs.codec)
  pattern = try Regex.compile(args.pattern)
  filter = try glob_regex(args.glob.unwrap_or("**"))
  base = try folder(ctx, args.path)
  files = try walk(base, "", 0, [])
  wanted = files.select { |name| Regex.match?(name, filter) }
  hits: List[String] = []
  for file in wanted
    break if hits.size > MAX_RESULTS

    hits = hits + matches(pattern, "#{base}/#{file}", Sandbox.relative(ctx.root, "#{base}/#{file}"))
  end

  ok(listing(hits.take(MAX_RESULTS), hits.size))
end

## The regex of a glob: `*` and `?` stay inside a folder name, `**` crosses folders.
def glob_regex(glob: String) -> Result[Regex.Regex] = Regex.compile("\\A#{translate(glob.split(""), 0, "")}\\z")

private

def folder(ctx: Spec.Context, path: Optional[String]) -> Result[String]
  base = try Sandbox.resolve(ctx.root, path.unwrap_or("."))
  info = try File.stat(base)
  return error("not a folder: #{path.unwrap_or(".")}") if info.kind != "directory"

  ok(base)
end

def listing(lines: List[String], total: Int) -> String
  return "no matches" if total == 0

  "#{lines.join("\n")}#{more(total - lines.size)}"
end

def more(hidden: Int) -> String
  if hidden > 0
    "\n[#{hidden} more not shown]"
  else
    ""
  end
end

def char_at(chars: List[String], at: Int) -> String
  if at < chars.size
    chars[at]
  else
    ""
  end
end

def translate(chars: List[String], at: Int, out: String) -> String
  return out if at >= chars.size

  here = chars[at]
  if here == "*" and char_at(chars, at + 1) == "*"
    if char_at(chars, at + 2) == "/"
      translate(chars, at + 3, "#{out}(?:.*/)?")
    else
      translate(chars, at + 2, "#{out}.*")
    end
  elsif here == "*"
    translate(chars, at + 1, "#{out}[^/]*")
  elsif here == "?"
    translate(chars, at + 1, "#{out}[^/]")
  else
    translate(chars, at + 1, "#{out}#{Regex.escape(here)}")
  end
end

def child(dir: String, name: String) -> String
  if dir == ""
    name
  else
    "#{dir}/#{name}"
  end
end

def walk(base: String, dir: String, depth: Int, found: List[String]) -> Result[List[String]]
  files = found
  for name in try Dir.list(child(base, dir))
    next if name == ".git"
    return ok(files) if files.size >= MAX_FILES

    entry = child(dir, name)
    case File.lstat(child(base, entry))
      ok(info) if info.kind == "file" -> files = files.push(entry)
      ok(info) if info.kind == "directory" and depth < MAX_DEPTH -> files = try walk(base, entry, depth + 1, files)
      _ -> nil
    end
  end

  ok(files)
end

def matches(pattern: Regex.Regex, path: String, shown: String) -> List[String]
  case File.stat(path)
    ok(info) if info.size_bytes <= MAX_FILE_BYTES -> lines_of(pattern, path, shown)
    _ -> []
  end
end

def clip(line: String) -> String
  if line.length > MAX_LINE_CHARS
    line.slice(0, MAX_LINE_CHARS)
  else
    line
  end
end

def lines_of(pattern: Regex.Regex, path: String, shown: String) -> List[String]
  text = File.read_text(path).unwrap_or("")
  return [] if text.include?(String.from_code(0))

  hits: List[String] = []
  number = 0
  for line in text.split("\n")
    number += 1
    if Regex.match?(line, pattern)
      hits = hits.push("#{shown}:#{number}:#{clip(line)}")
    end
  end

  hits
end
