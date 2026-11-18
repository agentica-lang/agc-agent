## The tools that read and write one file: read_file, write_file and edit_file.

import Sandbox from "sandbox"
import Spec from "spec"

DEFAULT_LINES = 2000
MAX_LINES = 5000
MAX_LINE_CHARS = 2000
READ_BUDGET = 27000
MAX_TEXT_BYTES = 1048576

struct ReadFileArgs
  path: String
  offset: Optional[Int]
  limit: Optional[Int]
end

struct WriteFileArgs
  path: String
  content: String
end

struct EditFileArgs
  path: String
  old_string: String
  new_string: String
  replace_all: Optional[Bool]
end

def read_file(ctx: Spec.Context, input: JSON.Value) -> Result[String]
  args = try Spec.args(input, ReadFileArgs.codec)
  offset = args.offset.unwrap_or(0)
  limit = args.limit.unwrap_or(DEFAULT_LINES)
  return error("offset and limit must not be negative") if offset < 0 or limit < 0

  path = try readable(ctx, args.path)
  info = try File.stat(path)
  return error("not a file: #{args.path}") if info.kind != "file"

  wanted = [limit, MAX_LINES].min.unwrap!
  clamped = limit > wanted
  if info.size_bytes <= MAX_TEXT_BYTES
    ok(render(try from_text(path, offset, wanted, clamped)))
  else
    ok(render(try from_stream(path, offset, wanted, clamped)))
  end
end

def write_file(ctx: Spec.Context, input: JSON.Value) -> Result[String]
  args = try Spec.args(input, WriteFileArgs.codec)
  path = try Sandbox.reach(ctx.root, args.path, ctx.confine)
  try Dir.mkdir(Sandbox.parent(path))
  try File.write_text(path, args.content)
  ok("wrote #{args.content.bytesize} bytes to #{Sandbox.relative(ctx.root, path)}")
end

def edit_file(ctx: Spec.Context, input: JSON.Value) -> Result[String]
  args = try Spec.args(input, EditFileArgs.codec)
  return error("old_string is empty") if args.old_string == ""
  return error("old_string and new_string are the same") if args.old_string == args.new_string

  text = try read(ctx, args.path)
  count = text.split(args.old_string).size - 1
  return error("old_string not found in #{args.path}") if count == 0
  if count > 1 and not args.replace_all.unwrap_or(false)
    return error("old_string found #{count} times in #{args.path}: add context or set replace_all")
  end

  path = try Sandbox.reach(ctx.root, args.path, ctx.confine)
  try File.replace(path, text.replace(args.old_string, args.new_string).bytes)
  ok("replaced #{count} in #{args.path}")
end

## The path of each call, relative to the session folder, for the approval rules and the preview.
def read_target(ctx: Spec.Context, input: JSON.Value) -> Result[String]
  args = try Spec.args(input, ReadFileArgs.codec)
  ok(Sandbox.relative(ctx.root, try readable(ctx, args.path)))
end

## The path `read_file` reads: in the session folder, or in a folder of `read_roots` when it is absolute.
def readable(ctx: Spec.Context, path: String) -> Result[String]
  inside = Sandbox.reach(ctx.root, path, ctx.confine)
  return inside if inside.ok? or not path.start_with?("/")

  for root in ctx.read_roots
    found = Sandbox.resolve(root, path)
    return found if found.ok?
  end

  inside
end

def write_target(ctx: Spec.Context, input: JSON.Value) -> Result[String]
  args = try Spec.args(input, WriteFileArgs.codec)
  relative_path(ctx, args.path)
end

def edit_target(ctx: Spec.Context, input: JSON.Value) -> Result[String]
  args = try Spec.args(input, EditFileArgs.codec)
  relative_path(ctx, args.path)
end

def relative_path(ctx: Spec.Context, path: String) -> Result[String]
  ok(Sandbox.relative(ctx.root, try Sandbox.reach(ctx.root, path, ctx.confine)))
end

private

struct Page
  lines: List[String]
  chars: Int
  next: Int
  cut: Bool
  capped: Bool
  long_line: Optional[Int]
end

# A file of up to 1 MiB is shown as it is, `\r` and the last newline included, so an `edit_file` can match what was
# read. A bigger file is read line by line, which loses the line ends.
def from_text(path: String, offset: Int, limit: Int, clamped: Bool) -> Result[Page]
  lines = (try File.read_text(path)).split("\n")
  page = Page(lines: [], chars: 0, next: offset, cut: false, capped: false, long_line: none)
  while page.next < lines.size and page.lines.size < limit and page.chars < READ_BUDGET
    page = add(page, lines[page.next])
  end

  more = page.next < lines.size
  full = page.lines.size >= limit
  ok(page.with(cut: page.chars >= READ_BUDGET and more and not full, capped: clamped and full and more))
end

def from_stream(path: String, offset: Int, limit: Int, clamped: Bool) -> Result[Page]
  file = try File.open(path)
  page = stream(file, offset, limit, clamped)
  _ = File.close(file)
  page
end

def stream(file: File.Handle, offset: Int, limit: Int, clamped: Bool) -> Result[Page]
  page = Page(lines: [], chars: 0, next: 0, cut: false, capped: false, long_line: none)
  while page.next < offset
    case File.read_line(file)
      ok(_) -> page = page.with(next: page.next + 1)
      error(e) -> return end_of_file(e, page)
    end
  end

  collected = page.with(lines: [], chars: 0)
  while collected.lines.size < limit and collected.chars < READ_BUDGET
    case File.read_line(file)
      ok(line) -> collected = add(collected, line)
      error(e) -> return end_of_file(e, collected)
    end
  end

  full = collected.lines.size >= limit
  ok(collected.with(cut: collected.chars >= READ_BUDGET and not full, capped: clamped and full and more_lines(file)))
end

def more_lines(file: File.Handle) -> Bool
  case File.read_line(file)
    ok(_) -> true
    error(e) -> e.kind != "io.eof"
  end
end

# A line over 1 MiB cannot be read: the read stops at it, and the lines before it are kept.
def end_of_file(e: Error, page: Page) -> Result[Page]
  case e.kind
    "io.eof" -> ok(page)
    "io.too_large" -> ok(page.with(long_line: some(page.next)))
    _ -> error(e.message)
  end
end

def add(page: Page, line: String) -> Page
  shown = clip(line)
  page.with(lines: page.lines.push(shown), chars: page.chars + shown.length + 1, next: page.next + 1)
end

def clip(line: String) -> String
  if line.length > MAX_LINE_CHARS
    "#{line.slice(0, MAX_LINE_CHARS)}[line cut: #{line.length} characters]"
  else
    line
  end
end

def render(page: Page) -> String = "#{page.lines.join("\n")}#{cut_note(page)}#{long_line_note(page)}"

def cut_note(page: Page) -> String
  if page.cut
    "\n[output cut at #{READ_BUDGET} characters: continue with offset #{page.next}]"
  elsif page.capped
    "\n[output limited to #{MAX_LINES} lines: continue with offset #{page.next}]"
  else
    ""
  end
end

def long_line_note(page: Page) -> String
  case page.long_line
    some(n) -> "\n[line #{n + 1} is longer than #{MAX_TEXT_BYTES} bytes and cannot be read: reading stops there]"
    none -> ""
  end
end

def read(ctx: Spec.Context, requested: String) -> Result[String]
  path = try Sandbox.reach(ctx.root, requested, ctx.confine)
  info = try File.stat(path)
  return error("not a file: #{requested}") if info.kind != "file"

  File.read_text(path)
end
