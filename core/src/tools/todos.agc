## `todo_write`: the model's todo list for the session. Each call gives the whole list, which replaces the one before;
## the session keeps the last one and sends it to the clients.

import Spec from "spec"

NAME = "todo_write"
STATUSES = ["pending", "in_progress", "completed"]
MAX_TODOS = 100
MAX_CONTENT = 500
# The characters that show nothing: Unicode spaces, the soft hyphen, zero-width and bidi controls, blank letters and
# the byte order mark; `invisible?` adds the variation selectors and the tag characters.
INVISIBLE = Set.new([
  0x00A0, 0x00AD, 0x061C, 0x1680, 0x180E, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008,
  0x2009, 0x200A, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x2028, 0x2029, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
  0x202F, 0x205F, 0x2060, 0x2061, 0x2062, 0x2063, 0x2064, 0x2066, 0x2067, 0x2068, 0x2069, 0x2800, 0x3000, 0x3164,
  0xFEFF,
])

struct Todo
  content: String
  status: String
end

struct TodoWriteArgs
  todos: List[Todo]
end

def tool() -> Spec.Tool
  Spec.Tool(
    name: NAME,
    description: (
      "Keep a todo list for a task of several steps, and show it to the user. Give the whole list each time: it " +
      "replaces the one before. `status` is `pending`, `in_progress` or `completed`; at most one item is " +
      "`in_progress`. Mark an item `completed` as soon as it is done."
    ),
    input_schema: JSON.schema(TodoWriteArgs),
    asks: false,
    run: &write,
    target: &target,
  )
end

## The list of a call, checked: at most `MAX_TODOS` items, each with a known status and some text that shows, and one
## in progress at most. The text is stripped and its line ends and tabs become spaces; another control character is
## refused.
def todos(input: JSON.Value) -> Result[List[Todo]]
  args = try Spec.args(input, TodoWriteArgs.codec)
  return error("at most #{MAX_TODOS} todos") if args.todos.size > MAX_TODOS

  list = args.todos.map { |t| t.with(content: one_line(t.content)) }
  for todo in list
    chars = todo.content.split("")
    if (chars.any? { |c| c.code < 0x20 or (c.code >= 0x7f and c.code < 0xa0) })
      return error("a todo has a control character")
    end

    return error("a todo has no content") if (chars.all? { |c| c.strip.empty? or invisible?(c.code) })
    return error("a todo is over #{MAX_CONTENT} characters") if todo.content.length > MAX_CONTENT
    return error("unknown status: use #{STATUSES.join(", ")}") if not STATUSES.include?(todo.status)
  end

  return error("at most one todo is in_progress") if (list.count { |t| t.status == "in_progress" } > 1)

  ok(list)
end

## The list as the model and the clients read it: a count, then one line per item (`[x]` completed, `[>]` in
## progress, `[ ]` pending).
def shown(list: List[Todo]) -> String
  return "The todo list is empty." if list.empty?

  done = list.count { |t| t.status == "completed" }
  head = "#{done} of #{list.size} todos completed"
  ([head] + list.map { |t| "#{box(t.status)} #{t.content}" }).join("\n")
end

private

def write(_ctx: Spec.Context, input: JSON.Value) -> Result[String] = ok(shown(try todos(input)))

def target(_ctx: Spec.Context, input: JSON.Value) -> Result[String]
  list = try todos(input)
  ok("#{list.size} todos")
end

def one_line(text: String) -> String = text.strip.replace("\r", " ").replace("\n", " ").replace("\t", " ")

def invisible?(code: Int) -> Bool
  INVISIBLE.include?(code) or (code >= 0xFE00 and code <= 0xFE0F) or (code >= 0xE0000 and code <= 0xE007F)
end

def box(status: String) -> String
  case status
    "completed" -> "[x]"
    "in_progress" -> "[>]"
    _ -> "[ ]"
  end
end
