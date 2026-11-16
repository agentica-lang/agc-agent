## The `apply_patch` tool: the patch format of Codex, which OpenAI models are trained on. A patch adds, deletes and
## updates files of the session folder; it is checked whole before any file changes. The path rule and the approval
## rules are those of `edit_file`, for each path the patch touches.

import Approval from "approval"
import Sandbox from "sandbox"
import Spec from "spec"

NAME = "apply_patch"
BEGIN = "*** Begin Patch"
END = "*** End Patch"
ADD = "*** Add File: "
DELETE = "*** Delete File: "
UPDATE = "*** Update File: "
MOVE = "*** Move to: "
END_OF_FILE = "*** End of File"

DESCRIPTION = <<~TEXT
  Add, delete, update or move files with a patch:
  *** Begin Patch
  *** Add File: path/new.txt
  +each line of the new file, after a +
  *** Delete File: path/old.txt
  *** Update File: path/file.py
  *** Move to: path/renamed.py
  @@ def f():
   a context line, after a space
  -a removed line
  +an added line
  *** End Patch
  `@@ text` names a line before the change, to tell repeated lines apart; give about 3 lines of context around
  each change. `*** Move to:` is optional. Paths are relative to the session folder.
TEXT

## The grammar of the patch, for a model API that takes a custom tool with a Lark grammar (OpenAI Responses).
GRAMMAR = <<~TEXT
  start: begin_patch hunk+ end_patch
  begin_patch: "*** Begin Patch" LF
  end_patch: "*** End Patch" LF?

  hunk: add_hunk | delete_hunk | update_hunk
  add_hunk: "*** Add File: " filename LF add_line+
  delete_hunk: "*** Delete File: " filename LF
  update_hunk: "*** Update File: " filename LF change_move? change?

  filename: /(.+)/
  add_line: "+" /(.*)/ LF -> line

  change_move: "*** Move to: " filename LF
  change: (change_context | change_line)+ eof_line?
  change_context: ("@@" | "@@ " /(.+)/) LF
  change_line: ("+" | "-" | " ") /(.*)/ LF
  eof_line: "*** End of File" LF

  %import common.LF
TEXT

struct PatchArgs
  input: String
end

enum Kind
  Add
  Delete
  Update
end

struct Chunk
  context: Optional[String]
  old: List[String]
  new: List[String]
  ## The change ends at the end of the file.
  at_end: Bool
end

struct Hunk
  kind: Kind
  path: String
  move_to: Optional[String] = none
  ## The lines of an added file.
  lines: List[String] = []
  chunks: List[Chunk] = []
end

def tool() -> Spec.Tool
  Spec.Tool(
    name: NAME,
    description: DESCRIPTION.strip,
    input_schema: JSON.schema(PatchArgs),
    asks: true,
    run: &apply,
    target: &target,
  )
end

## The format of the tool as a custom tool of the Responses API.
def grammar() -> JSON.Value
  JSON.object({"type": JSON.from("grammar"), "syntax": JSON.from("lark"), "definition": JSON.from(GRAMMAR)})
end

## The patch of a call: from its `input` field, or the text of a custom tool call.
def args(input: JSON.Value) -> Result[String]
  parsed = try Spec.args(input, PatchArgs.codec)
  ok(parsed.input)
end

## The paths the patch touches, relative to the session folder, moves included.
def target(ctx: Spec.Context, input: JSON.Value) -> Result[String]
  ok((try paths(ctx, try parse(try args(input)))).join(", "))
end

## Each path decides as an `edit_file` (or an `apply_patch`) call on it: a deny of either denies the patch, a path that
## neither allows asks, and the patch runs without asking only when every path is allowed.
def verdict(ctx: Spec.Context, input: JSON.Value) -> Approval.Verdict
  case touched(ctx, input)
    ok(found) -> combined(found.map { |path| path_verdict(ctx.rules, path) })
    error(_) -> Approval.Verdict.Deny
  end
end

def combined(verdicts: List[Approval.Verdict]) -> Approval.Verdict
  return Approval.Verdict.Deny if verdicts.include?(Approval.Verdict.Deny)
  return Approval.Verdict.Ask if verdicts.include?(Approval.Verdict.Ask)

  Approval.Verdict.Allow
end

def apply(ctx: Spec.Context, input: JSON.Value) -> Result[String]
  hunks = try parse(try args(input))
  _ = try paths(ctx, hunks)
  changes: List[Change] = []
  for hunk in hunks
    changes = changes.push(try planned(ctx, hunk))
  end

  for change in changes
    try done(change)
  end

  ok("Done. The files changed:\n#{changes.map { |change| change.summary }.join("\n")}")
end

## The hunks of a patch, or an error that says which line is wrong.
def parse(text: String) -> Result[List[Hunk]]
  lines = text.strip.split("\n").map { |line| trim_cr(line) }
  return error("the patch must start with #{BEGIN}") if lines.empty? or lines.first.strip != BEGIN
  return error("the patch must end with #{END}") if lines.size < 2 or lines.last.strip != END

  hunks: List[Hunk] = []
  i = 1
  last = lines.size - 1
  while i < last
    line = lines[i]
    if line.start_with?(ADD)
      body: List[String] = []
      i = i + 1
      while i < last and lines[i].start_with?("+")
        body = body.push(lines[i].slice(1, lines[i].length - 1))
        i = i + 1
      end

      hunks = hunks.push(Hunk(kind: Kind.Add, path: after(line, ADD), lines: body))
    elsif line.start_with?(DELETE)
      hunks = hunks.push(Hunk(kind: Kind.Delete, path: after(line, DELETE)))
      i = i + 1
    elsif line.start_with?(UPDATE)
      read = try update(lines, i, last)
      hunks = hunks.push(read.hunk)
      i = read.next
    elsif line.strip == ""
      i = i + 1
    else
      return error("line #{i + 1} of the patch is not a hunk header: #{line}")
    end
  end

  return error("the patch has no hunk") if hunks.empty?

  ok(hunks)
end

## The lines of a file after the chunks of an update, or an error when a chunk's lines are not found.
def updated(lines: List[String], chunks: List[Chunk], path: String) -> Result[List[String]]
  at = 0
  edits: List[Edit] = []
  for chunk in chunks
    for context in option_list(chunk.context)
      found = seek(lines, [context], at, false)
      return error("#{path}: the context line is not found: #{context}") if found.none?

      at = found.unwrap! + 1
    end

    if chunk.old.empty?
      edits = edits.push(Edit(start: lines.size, size: 0, new: chunk.new))
      next
    end

    old = chunk.old
    new = chunk.new
    found = seek(lines, old, at, chunk.at_end)
    if found.none? and old.last == ""
      old = old.take(old.size - 1)
      if not new.empty? and new.last == ""
        new = new.take(new.size - 1)
      end

      found = seek(lines, old, at, chunk.at_end)
    end

    return error("#{path}: these lines are not found:\n#{old.join("\n")}") if found.none?

    edits = edits.push(Edit(start: found.unwrap!, size: old.size, new: new))
    at = found.unwrap! + old.size
  end

  out = lines
  for edit in edits.reverse
    out = out.take(edit.start) + edit.new + out.drop(edit.start + edit.size)
  end

  ok(out)
end

private

struct Update
  hunk: Hunk
  next: Int
end

struct Edit
  start: Int
  size: Int
  new: List[String]
end

struct Change
  ## The file written, with its content; none when nothing is written.
  write: Optional[String]
  content: String
  ## The file removed, after the write: a deleted file or the old path of a move.
  remove: Optional[String]
  summary: String
end

def update(lines: List[String], start: Int, last: Int) -> Result[Update]
  path = after(lines[start], UPDATE)
  i = start + 1
  move_to: Optional[String] = none
  if i < last and lines[i].start_with?(MOVE)
    move_to = some(after(lines[i], MOVE))
    i = i + 1
  end

  chunks: List[Chunk] = []
  chunk = Chunk(context: none, old: [], new: [], at_end: false)
  open = false
  while i < last and not header?(lines[i])
    line = lines[i]
    i = i + 1
    if line.start_with?("@@")
      if open
        chunks = chunks.push(chunk)
      end

      context: Optional[String] = none
      if line.strip != "@@"
        context = some(line.slice(2, line.length - 2).strip)
      end

      chunk = Chunk(context: context, old: [], new: [], at_end: false)
      open = true
    elsif line.strip == END_OF_FILE
      chunk = chunk.with(at_end: true)
    elsif line == "" or line.start_with?(" ")
      text = line.slice(1, [line.length - 1, 0].max.unwrap!)
      chunk = chunk.with(old: chunk.old.push(text), new: chunk.new.push(text))
      open = true
    elsif line.start_with?("-")
      chunk = chunk.with(old: chunk.old.push(line.slice(1, line.length - 1)))
      open = true
    elsif line.start_with?("+")
      chunk = chunk.with(new: chunk.new.push(line.slice(1, line.length - 1)))
      open = true
    else
      return error("line #{i} of the patch is not a change line (space, - or +): #{line}")
    end
  end

  if open
    chunks = chunks.push(chunk)
  end

  return error("the update of #{path} has no change") if chunks.empty? and move_to.none?

  ok(Update(hunk: Hunk(kind: Kind.Update, path: path, move_to: move_to, chunks: chunks), next: i))
end

def header?(line: String) -> Bool = [ADD, DELETE, UPDATE].any? { |h| line.start_with?(h) }

def after(line: String, prefix: String) -> String = line.slice(prefix.length, line.length - prefix.length).strip

# The paths the hunks touch, each once, relative to the session folder; an error for a path out of it.
def paths(ctx: Spec.Context, hunks: List[Hunk]) -> Result[List[String]]
  out: List[String] = []
  for hunk in hunks
    named = [hunk.path] + option_list(hunk.move_to)
    for path in named
      relative = Sandbox.relative(ctx.root, try Sandbox.resolve(ctx.root, path))
      return error("the patch touches #{relative} twice") if out.include?(relative)

      out = out.push(relative)
    end
  end

  ok(out)
end

def touched(ctx: Spec.Context, input: JSON.Value) -> Result[List[String]] = paths(ctx, try parse(try args(input)))

def path_verdict(rules: Approval.Rules, path: String) -> Approval.Verdict
  verdicts = [Approval.decide(rules, "edit_file", path, true), Approval.decide(rules, NAME, path, true)]
  return Approval.Verdict.Deny if verdicts.include?(Approval.Verdict.Deny)
  return Approval.Verdict.Allow if verdicts.include?(Approval.Verdict.Allow)

  Approval.Verdict.Ask
end

# What a hunk will do, checked against the files as they are now; nothing is written yet.
def planned(ctx: Spec.Context, hunk: Hunk) -> Result[Change]
  path = try Sandbox.resolve(ctx.root, hunk.path)
  relative = Sandbox.relative(ctx.root, path)
  case hunk.kind
    Kind.Add ->
      return error("#{relative} exists: update it instead") if File.lstat(path).ok?

      ok(Change(write: some(path), content: text_of(hunk.lines), remove: none, summary: "A #{relative}"))
    Kind.Delete ->
      _ = try read(path, relative)
      ok(Change(write: none, content: "", remove: some(path), summary: "D #{relative}"))
    Kind.Update ->
      text = try read(path, relative)
      lines = text.split("\n").map { |line| trim_cr(line) }
      if text.end_with?("\n")
        lines = lines.take(lines.size - 1)
      end

      content = text_of(try updated(lines, hunk.chunks, relative))
      case hunk.move_to
        some(to) ->
          moved = try Sandbox.resolve(ctx.root, to)
          shown = Sandbox.relative(ctx.root, moved)
          return error("#{shown} exists: the move would replace it") if File.lstat(moved).ok?

          ok(Change(write: some(moved), content: content, remove: some(path), summary: "M #{relative} -> #{shown}"))
        none -> ok(Change(write: some(path), content: content, remove: none, summary: "M #{relative}"))
      end
  end
end

def done(change: Change) -> Result[Void]
  for path in option_list(change.write)
    try Dir.mkdir(Sandbox.parent(path))
    try File.write_text(path, change.content)
  end

  for path in option_list(change.remove)
    try Path.remove(path)
  end

  ok()
end

def read(path: String, relative: String) -> Result[String]
  info = try File.lstat(path)
  return error("not a file: #{relative}") if info.kind != "file"

  File.read_text(path)
end

def text_of(lines: List[String]) -> String
  return "" if lines.empty?

  "#{lines.join("\n")}\n"
end

# Where `wanted` starts in `lines` from `from`: an exact match first, then one that ignores the spaces at the end of
# each line, then at both ends. A change at the end of the file is looked for there first.
def seek(lines: List[String], wanted: List[String], from: Int, at_end: Bool) -> Optional[Int]
  return none if wanted.size > lines.size

  last_start = lines.size - wanted.size
  if at_end and last_start >= from
    for compare in [0, 1, 2]
      return some(last_start) if same?(lines, wanted, last_start, compare)
    end
  end

  for compare in [0, 1, 2]
    for start in from..last_start
      return some(start) if same?(lines, wanted, start, compare)
    end
  end

  none
end

def same?(lines: List[String], wanted: List[String], start: Int, compare: Int) -> Bool
  (0...wanted.size).all? { |i| loose(lines[start + i], compare) == loose(wanted[i], compare) }
end

def loose(line: String, compare: Int) -> String
  case compare
    0 -> line
    1 -> trim_end(line)
    _ -> line.strip
  end
end

def trim_end(line: String) -> String
  out = line
  while out.end_with?(" ") or out.end_with?("\t")
    out = out.slice(0, out.length - 1)
  end

  out
end

def trim_cr(line: String) -> String
  return line.slice(0, line.length - 1) if line.end_with?("\r")

  line
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
