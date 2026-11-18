## The `apply_patch` tool: the patch format of Codex, which OpenAI models are trained on. A patch adds, deletes and
## updates files of the session folder; it is checked whole before any file changes. The path rule is that of
## `edit_file`, for each path the patch touches.

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
MAX_PATCH_CHARS = 1_048_576
MAX_CHUNK_LINES = 1000
MAX_CHUNKS = 1000
## The most line comparisons the search of a whole patch may take, so a patch cannot hold the session for long.
MAX_SEARCH = 2_000_000

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
  each change. A change of only + lines goes right after its `@@ text` line, or at the end of the file after a bare
  `@@`. `*** Move to:` is optional. Paths are relative to the session folder.
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

enum Touch
  Write
  Edit
  Remove
end

struct Touched
  path: String
  touch: Touch
end

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

## What each path of the patch does, relative to the session folder.
def touched(ctx: Spec.Context, input: JSON.Value) -> Result[List[Touched]] = touches(ctx, try parse(try args(input)))

## Applies the patch whole: every hunk is checked first, then the files are written, and the deleted files are set
## aside last (renamed to `.finn-patch-N` in their folder) and removed once every step worked. When a step fails,
## every file and new folder is put back. A process killed midway can leave a `.finn-patch-N` file behind.
def apply(ctx: Spec.Context, input: JSON.Value) -> Result[String]
  hunks = try parse(try args(input))
  _ = try paths(ctx, hunks)
  changes: List[Change] = []
  left = MAX_SEARCH
  for hunk in hunks
    plan = try planned(ctx, hunk, left)
    changes = changes.push(plan.change)
    left = left - plan.spent
  end

  undo = Undo(saved: [], folders: new_folders(changes), aside: [])
  for change in changes
    for path in option_list(change.write)
      undo = undo.with(saved: undo.saved.push(Saved(path: path, content: present(path))))
      case written(path, change.content)
        ok(_) -> nil
        error(e) -> return failed(ctx.root, e.message, undo)
      end
    end
  end

  for change in changes
    for path in option_list(change.remove)
      aside = free_name(Sandbox.parent(path))
      case Path.rename(path, aside)
        ok(_) -> undo = undo.with(aside: undo.aside.push(Aside(path: path, aside: aside)))
        error(e) -> return failed(ctx.root, e.message, undo)
      end
    end
  end

  left_behind = undo.aside
    .select { |each| not Path.remove(each.aside).ok? }
    .map { |each| Sandbox.relative(ctx.root, each.aside) }

  done = "Done. The files changed:\n#{changes.map { |change| change.summary }.join("\n")}"
  return ok(done) if left_behind.empty?

  ok("#{done}\nThese set-aside copies could not be removed: #{left_behind.join(", ")}")
end

## The hunks of a patch, or an error that says which line is wrong.
def parse(text: String) -> Result[List[Hunk]]
  return error("the patch is longer than #{MAX_PATCH_CHARS} characters") if text.length > MAX_PATCH_CHARS

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

      return error("line #{i} of the patch adds a file with no + line") if body.empty?

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

  chunks = hunks.map { |hunk| hunk.chunks.size }.sum
  return error("the patch has more than #{MAX_CHUNKS} changes") if chunks > MAX_CHUNKS

  ok(hunks)
end

## The lines of a file after the chunks of an update, and the line comparisons its search took (at most `budget`), or
## an error when a chunk's lines are not found.
def updated(lines: List[String], chunks: List[Chunk], path: String, budget: Int) -> Result[Placed]
  forms = [lines, lines.map { |line| trim_end(line) }, lines.map { |line| line.strip }]
  at = 0
  spent = 0
  edits: List[Edit] = []
  for chunk in chunks
    for context in option_list(chunk.context)
      search = try seek(forms, [context], at, false, budget - spent)
      spent = spent + search.spent
      return error("#{path}: the context line is not found: #{context}") if search.at.none?

      at = search.at.unwrap! + 1
    end

    return error("#{path}: a change has more than #{MAX_CHUNK_LINES} old lines") if chunk.old.size > MAX_CHUNK_LINES

    # Codex appends a change of only + lines at the end of the file; here it goes after its context line.
    if chunk.old.empty?
      start = lines.size
      if chunk.context.some?
        start = at
      end

      edits = edits.push(Edit(start: start, size: 0, new: chunk.new))
      next
    end

    old = chunk.old
    new = chunk.new
    search = try seek(forms, old, at, chunk.at_end, budget - spent)
    spent = spent + search.spent
    if search.at.none? and old.last == ""
      old = old.take(old.size - 1)
      if not new.empty? and new.last == ""
        new = new.take(new.size - 1)
      end

      search = try seek(forms, old, at, chunk.at_end, budget - spent)
      spent = spent + search.spent
    end

    return error("#{path}: these lines are not found:\n#{old.join("\n")}") if search.at.none?

    found = search.at.unwrap!
    edits = edits.push(Edit(start: found, size: old.size, new: new))
    at = found + old.size
  end

  # The edits by place, in order for the same place, applied in one pass over the lines.
  ordered = (0...edits.size).to_a.sort_by { |i| edits[i].start * (edits.size + 1) + i }.map { |i| edits[i] }
  out: List[String] = []
  i = 0
  e = 0
  while i < lines.size or e < ordered.size
    if e < ordered.size and ordered[e].start <= i
      for line in ordered[e].new
        out = out.push(line)
      end

      i = [i, ordered[e].start + ordered[e].size].max.unwrap!
      e = e + 1
    else
      out = out.push(lines[i])
      i = i + 1
    end
  end

  ok(Placed(lines: out, spent: spent))
end

## Removes the folders of `folders` that are empty, in order, so deepest first; a folder that holds a file stays. Gives
## the empty ones it could not remove.
def cleared(folders: List[String]) -> List[String]
  folders.select { |folder| Dir.list(folder).unwrap_or(["?"]).empty? and not Path.remove(folder).ok? }
end

private

ASIDE_TRIES = 10

struct Update
  hunk: Hunk
  next: Int
end

struct Edit
  start: Int
  size: Int
  new: List[String]
end

struct Saved
  path: String
  ## None when the file was not there.
  content: Optional[String]
end

## A deleted file, renamed out of the way until the patch is done, so a rollback gives it back with its mode.
struct Aside
  path: String
  aside: String
end

struct Undo
  saved: List[Saved]
  ## The folders that the writes may create, deepest first.
  folders: List[String]
  aside: List[Aside]
end

struct Placed
  lines: List[String]
  spent: Int
end

struct Plan
  change: Change
  spent: Int
end

struct Search
  at: Optional[Int]
  spent: Int
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
  ok((try touches(ctx, hunks)).map { |t| t.path })
end

def touches(ctx: Spec.Context, hunks: List[Hunk]) -> Result[List[Touched]]
  out: List[Touched] = []
  for hunk in hunks
    for t in touches_of(hunk)
      relative = Sandbox.relative(ctx.root, try Sandbox.reach(ctx.root, t.path, ctx.confine))
      return error("the patch touches #{relative} twice") if (out.any? { |o| o.path == relative })

      out = out.push(t.with(path: relative))
    end
  end

  ok(out)
end

def touches_of(hunk: Hunk) -> List[Touched]
  case hunk.kind
    Kind.Add -> [Touched(path: hunk.path, touch: Touch.Write)]
    Kind.Delete -> [Touched(path: hunk.path, touch: Touch.Remove)]
    Kind.Update -> moved(hunk)
  end
end

def moved(hunk: Hunk) -> List[Touched]
  for to in option_list(hunk.move_to)
    return [Touched(path: hunk.path, touch: Touch.Remove), Touched(path: to, touch: Touch.Write)]
  end

  [Touched(path: hunk.path, touch: Touch.Edit)]
end

# What a hunk will do, checked against the files as they are now, and the line comparisons its search took (at most
# `budget`); nothing is written yet.
def planned(ctx: Spec.Context, hunk: Hunk, budget: Int) -> Result[Plan]
  path = try Sandbox.reach(ctx.root, hunk.path, ctx.confine)
  relative = Sandbox.relative(ctx.root, path)
  case hunk.kind
    Kind.Add ->
      return error("#{relative} exists: update it instead") if File.lstat(path).ok?

      add = Change(write: some(path), content: text_of(hunk.lines, "\n"), remove: none, summary: "A #{relative}")
      ok(Plan(change: add, spent: 0))
    Kind.Delete ->
      _ = try read(path, relative)
      ok(Plan(change: Change(write: none, content: "", remove: some(path), summary: "D #{relative}"), spent: 0))
    Kind.Update ->
      text = try read(path, relative)
      lines = text.split("\n").map { |line| trim_cr(line) }
      if text.end_with?("\n")
        lines = lines.take(lines.size - 1)
      end

      placed = try updated(lines, hunk.chunks, relative, budget)
      content = text_of(placed.lines, line_end(text))
      case hunk.move_to
        some(to) ->
          moved = try Sandbox.reach(ctx.root, to, ctx.confine)
          shown = Sandbox.relative(ctx.root, moved)
          return error("#{shown} exists: the move would replace it") if File.lstat(moved).ok?

          change = Change(
            write: some(moved),
            content: content,
            remove: some(path),
            summary: "M #{relative} -> #{shown}",
          )

          ok(Plan(change: change, spent: placed.spent))
        none ->
          change = Change(write: some(path), content: content, remove: none, summary: "M #{relative}")
          ok(Plan(change: change, spent: placed.spent))
      end
  end
end

def written(path: String, content: String) -> Result[Void]
  try Dir.mkdir(Sandbox.parent(path))
  File.write_text(path, content)
end

# The folders above the written files that are not there yet, deepest first.
def new_folders(changes: List[Change]) -> List[String]
  out: List[String] = []
  for change in changes
    for path in option_list(change.write)
      folder = Sandbox.parent(path)
      while not File.lstat(folder).ok?
        if not out.include?(folder)
          out = out.push(folder)
        end

        folder = Sandbox.parent(folder)
      end
    end
  end

  out.sort_by { |folder| 0 - folder.length }
end

def failed(root: String, message: String, undo: Undo) -> Result[String]
  lost = rolled_back(undo).map { |path| Sandbox.relative(root, path) }
  return error("#{message}; no file was changed") if lost.empty?

  error("#{message}; these files could not be restored: #{lost.join(", ")}")
end

# Puts back the files and removes the new folders, going on past a step that fails; the paths it could not restore.
def rolled_back(undo: Undo) -> List[String]
  lost: List[String] = []
  for each in undo.aside.reverse
    if not Path.rename(each.aside, each.path).ok?
      lost = lost.push(each.path)
    end
  end

  for each in undo.saved.reverse
    restored = case each.content
      some(text) -> File.write_text(each.path, text)
      none -> gone(each.path)
    end

    if not restored.ok?
      lost = lost.push(each.path)
    end
  end

  lost + cleared(undo.folders)
end

# A name in `folder` that nothing has yet, for a file set aside.
def free_name(folder: String) -> String
  name = "#{folder}/.finn-patch-#{Random.int(0, 999_999_999)}"
  for _try in 1...ASIDE_TRIES
    return name if not File.lstat(name).ok?

    name = "#{folder}/.finn-patch-#{Random.int(0, 999_999_999)}"
  end

  name
end

def gone(path: String) -> Result[Void]
  return ok() if not File.lstat(path).ok?

  Path.remove(path)
end

def read(path: String, relative: String) -> Result[String]
  info = try File.lstat(path)
  return error("not a file: #{relative}") if info.kind != "file"

  File.read_text(path)
end

def text_of(lines: List[String], ending: String) -> String
  return "" if lines.empty?

  "#{lines.join(ending)}#{ending}"
end

# A file whose first line ends with CRLF keeps CRLF.
def line_end(text: String) -> String
  first = text.index_of("\n")
  return "\r\n" if first.some? and first.unwrap! > 0 and text.slice(first.unwrap! - 1, 1) == "\r"

  "\n"
end

def present(path: String) -> Optional[String]
  case File.read_text(path)
    ok(text) -> some(text)
    error(_) -> none
  end
end

# Where `wanted` starts in `lines` from `from`: an exact match first, then one that ignores the spaces at the end of
# each line, then at both ends. A change at the end of the file is looked for there first. Each place tried counts
# `wanted.size` comparisons, and more than `budget` is an error.
# `forms` holds the lines as they are, without the spaces at their end, and without the spaces at both ends.
def seek(forms: List[List[String]], wanted: List[String], from: Int, at_end: Bool, budget: Int) -> Result[Search]
  lines = forms[0]
  return ok(Search(at: none, spent: 0)) if wanted.size > lines.size

  wanted_forms = [wanted, wanted.map { |line| trim_end(line) }, wanted.map { |line| line.strip }]

  over = "the patch needs more than #{MAX_SEARCH} line comparisons to place its changes"
  spent = 0
  last_start = lines.size - wanted.size
  if at_end and last_start >= from
    for compare in [0, 1, 2]
      spent = spent + wanted.size
      return error(over) if spent > budget
      return ok(Search(at: some(last_start), spent: spent)) if same?(forms[compare], wanted_forms[compare], last_start)
    end
  end

  for compare in [0, 1, 2]
    for start in from..last_start
      spent = spent + wanted.size
      return error(over) if spent > budget
      return ok(Search(at: some(start), spent: spent)) if same?(forms[compare], wanted_forms[compare], start)
    end
  end

  ok(Search(at: none, spent: spent))
end

def same?(lines: List[String], wanted: List[String], start: Int) -> Bool
  (0...wanted.size).all? { |i| lines[start + i] == wanted[i] }
end

# Without the spaces at the end: the line up to the end of its stripped text, which starts after the leading spaces.
def trim_end(line: String) -> String
  core = line.strip
  return "" if core == ""

  line.slice(0, line.index_of(core).unwrap_or(0) + core.length)
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
