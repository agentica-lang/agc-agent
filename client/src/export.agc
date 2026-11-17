## A session's branch as a Markdown file, for `/export` and `finn export`. The file holds what the session holds, tool
## arguments included, with nothing hidden: it is made 0600.

import UTC from "std/utc"
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

  blocks = ["# #{escaped(title)}", "Session `#{exported.id}`, started #{UTC.iso8601(exported.created_ms)}."]
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

    blocks = blocks + ["## #{heading(entry.kind)}", escaped(entry.text)]
  end

  if not tools.empty?
    blocks = blocks.push(tools.join("\n"))
  end

  if not exported.todos.empty?
    blocks = blocks + ["## Todos", exported.todos.map { |todo| todo_line(todo) }.join("\n")]
  end

  blocks.join("\n\n") + "\n"
end

## Where an export goes: `given`, else `<id>.md` in the current folder.
def export_path(id: String, given: Optional[String]) -> String = given.unwrap_or("#{id}.md")

## Writes the Markdown of `exported` to `path`, made 0600. A path that exists is an error, unless `force` and it is a
## file. Gives the path.
def saved(exported: Protocol.SessionExport, path: String, force: Bool) -> Result[String]
  case File.lstat(path, FILE_MS)
    ok(_) if not force -> return error("#{path} exists: add --force to replace it", kind: Commands.KIND_COMMAND)
    ok(info) if info.kind != "file" -> return error("#{path} is not a file", kind: Commands.KIND_COMMAND)
    ok(_) -> try Path.remove(path, FILE_MS)
    error(_) -> nil
  end

  text = markdown(exported)
  written: Result[Void] = File.open(path, "create_private", FILE_MS) do |file| File.write(file, text, FILE_MS) end
  try written
  ok(path)
end

private

HEX = "0123456789abcdef"

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

  "- `#{escaped(entry.tool)}` #{escaped(entry.text.split("\n")[0])} (#{result})"
end

def todo_line(todo: Protocol.Todo) -> String
  return "- [x] #{escaped(todo.content)}" if todo.status == "completed"
  return "- [ ] #{escaped(todo.content)} (in progress)" if todo.status == "in_progress"

  "- [ ] #{escaped(todo.content)}"
end

# Line breaks and tabs stay; every other character that `Commands.control?` names becomes its code.
def escaped(text: String) -> String = text.split("").map { |c| escaped_char(c) }.join("")

def escaped_char(c: String) -> String
  return c if c == "\n" or c == "\t" or not Commands.control?(c.code)

  code = c.code
  "\\u" + [12, 8, 4, 0].map { |shift| HEX.slice(code.shift_right(shift).bit_and(15), 1) }.join("")
end
