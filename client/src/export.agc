## A session's branch as a Markdown file, for `/export` and `finn export`. The file holds what the session holds, tool
## arguments included, with nothing hidden: it is made 0600.

import Protocol from "pkg/protocol/protocol"
import Commands from "commands"

FILE_MS = 5000

## The Markdown of `exported`: the title and date, each message under its role, the tool calls of an answer as a list
## (name, what it was called on, and ok, error or no result), then the todo list. A control or bidi character is
## written as its code (`\u001b`), so the file shows nothing a terminal or an editor would act on.
def markdown(exported: Protocol.SessionExport) -> String
  title = exported.title
  if title.strip.empty?
    title = "Session #{exported.id}"
  end

  blocks = ["# #{one_line(title)}", "Session `#{exported.id}`, started #{started(exported.created_ms)}."]
  tools: List[String] = []
  for entry in exported.entries
    if entry.kind == "tool"
      tools = tools.push(tool_line(entry))
      next
    end

    if not tools.empty?
      blocks = blocks.push(tools.join("\n"))
      tools = []
    end

    if entry.kind == "compaction"
      blocks = blocks.push("*History compacted here.*")
      next
    end

    blocks = blocks + ["## #{heading(entry.kind)}", fenced(entry.text)]
  end

  if not tools.empty?
    blocks = blocks.push(tools.join("\n"))
  end

  if not exported.todos.empty?
    blocks = blocks + ["## Todos", exported.todos.map { |todo| todo_line(todo) }.join("\n")]
  end

  blocks.join("\n\n") + "\n"
end

## Where an export goes: `given` (a leading `~` is the home folder), else `<id>.md` in the current folder.
def export_path(id: String, given: Optional[String]) -> String
  path = given.unwrap_or("#{id}.md")
  home = System.env("HOME").unwrap_or("")
  return path if home == "" or (path != "~" and not path.start_with?("~/"))

  home + path.slice(1, path.length - 1)
end

## Writes the Markdown of `exported` to `path`, made 0600. A path that exists is an error, unless `force` and it is a
## file, which is then replaced in one step: a failure keeps it. Gives the path.
def saved(exported: Protocol.SessionExport, path: String, force: Bool) -> Result[String]
  text = markdown(exported)
  case File.lstat(path, FILE_MS)
    ok(_) if not force -> return error("#{path} exists: add --force to replace it", kind: Commands.KIND_COMMAND)
    ok(info) if info.kind != "file" -> return error("#{path} is not a file", kind: Commands.KIND_COMMAND)
    ok(_) -> return replaced(path, text)
    error(_) -> nil
  end

  try created(path, text)
  ok(path)
end

## Makes the file `path`, 0600, with `text`. A path that exists is an error and stays as it is; a file whose write
## fails is removed.
def created(path: String, text: String) -> Result[Void]
  file = try File.open(path, "create_private", FILE_MS)
  written = written_to(file, text.bytes)
  closed = File.close(file, FILE_MS)
  if not written.ok? or not closed.ok?
    _ = Path.remove(path, FILE_MS)
  end

  try written
  closed
end

private

HEX = "0123456789abcdef"
# The most one write takes.
WRITE_BYTES = 1_048_576

# `YYYY-MM-DDTHH:MM:SSZ`, as std/utc wrote it; a time outside the years 1 to 9999 is no date.
def started(created_ms: Int) -> String
  return "at an unknown time" if created_ms < -62_135_596_800_000 or created_ms > 253_402_300_799_999

  case Time.at_us(created_ms * 1000)
    ok(time) -> time.strftime("%Y-%m-%dT%H:%M:%SZ")
    error(_) -> "at an unknown time"
  end
end

def written_to(file: File.Handle, bytes: Bytes) -> Result[Void]
  at = 0
  while at < bytes.length
    piece = [WRITE_BYTES, bytes.length - at].min.unwrap!
    try File.write_bytes(file, bytes.slice(at, piece), FILE_MS)
    at = at + piece
  end

  ok()
end

# The new file is written beside the old one, which moves aside until the new one has its name, so either stays.
def replaced(path: String, text: String) -> Result[String]
  temp = "#{path}.#{System.pid()}-#{Random.int(0, 999_999_999)}"
  try created("#{temp}.tmp", text)
  case Path.rename(path, "#{temp}.old", FILE_MS)
    ok(_) -> nil
    error(e) ->
      _ = Path.remove("#{temp}.tmp", FILE_MS)
      return error(e)
  end

  case Path.rename("#{temp}.tmp", path, FILE_MS)
    ok(_) -> nil
    error(e) ->
      _ = Path.rename("#{temp}.old", path, FILE_MS)
      _ = Path.remove("#{temp}.tmp", FILE_MS)
      return error(e)
  end

  _ = Path.remove("#{temp}.old", FILE_MS)
  ok(path)
end

# A fence longer than any run of backticks in the text, so the text cannot close it.
def fenced(text: String) -> String
  longest = 0
  run = 0
  for c in text.split("")
    run = run + 1
    if c != "`"
      run = 0
    end

    longest = [longest, run].max.unwrap!
  end

  fence = "`" * [3, longest + 1].max.unwrap!
  "#{fence}\n#{escaped(text)}\n#{fence}"
end

def one_line(text: String) -> String = escaped(text.split("\n").join(" "))

def heading(kind: String) -> String
  return "User" if kind == "user"

  "Assistant"
end

def tool_line(entry: Protocol.ExportEntry) -> String
  result = "no result"
  if entry.ok.some?
    result = "error"
    if entry.ok.unwrap!
      result = "ok"
    end
  end

  "- `#{one_line(entry.tool)}` #{one_line(entry.text.split("\n")[0])} (#{result})"
end

def todo_line(todo: Protocol.Todo) -> String
  return "- [x] #{one_line(todo.content)}" if todo.status == "completed"
  return "- [ ] #{one_line(todo.content)} (in progress)" if todo.status == "in_progress"

  "- [ ] #{one_line(todo.content)}"
end

# Line breaks and tabs stay; every other character that `Commands.control?` names becomes its code.
def escaped(text: String) -> String = text.split("").map { |c| escaped_char(c) }.join("")

def escaped_char(c: String) -> String
  return c if c == "\n" or c == "\t" or not Commands.control?(c.code)

  code = c.code
  "\\u" + [12, 8, 4, 0].map { |shift| HEX.slice(code.shift_right(shift).bit_and(15), 1) }.join("")
end
