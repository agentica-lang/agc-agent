## The tools that read and write one file: read_file, write_file and edit_file.

import Sandbox from "sandbox"
import Spec from "spec"

DEFAULT_LINES = 2000

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

  path = try Sandbox.resolve(ctx.root, args.path)
  info = try File.stat(path)
  return error("not a file: #{args.path}") if info.kind != "file"

  file = try File.open(path)
  lines = read_lines(file, offset, limit)
  _ = File.close(file)
  lines
end

def write_file(ctx: Spec.Context, input: JSON.Value) -> Result[String]
  args = try Spec.args(input, WriteFileArgs.codec)
  path = try Sandbox.resolve(ctx.root, args.path)
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

  path = try Sandbox.resolve(ctx.root, args.path)
  try File.replace(path, text.replace(args.old_string, args.new_string).bytes)
  ok("replaced #{count} in #{args.path}")
end

## The path of each call, relative to the session folder, for the approval rules and the preview.
def read_target(ctx: Spec.Context, input: JSON.Value) -> Result[String]
  args = try Spec.args(input, ReadFileArgs.codec)
  relative_path(ctx, args.path)
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
  ok(Sandbox.relative(ctx.root, try Sandbox.resolve(ctx.root, path)))
end

private

# A file is read line by line, so `offset` and `limit` reach into a file of any size.
def read_lines(file: File.Handle, offset: Int, limit: Int) -> Result[String]
  lines: List[String] = []
  number = 0
  while lines.size < limit
    case File.read_line(file)
      ok(line) ->
        if number >= offset
          lines = lines.push(line)
        end

        number += 1
      error(e) ->
        return ok(lines.join("\n")) if e.kind == "io.eof"

        return error(e.message)
    end
  end

  ok(lines.join("\n"))
end

def read(ctx: Spec.Context, requested: String) -> Result[String]
  path = try Sandbox.resolve(ctx.root, requested)
  info = try File.stat(path)
  return error("not a file: #{requested}") if info.kind != "file"

  File.read_text(path)
end
