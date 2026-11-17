## `todo_write`: the model's todo list for the session. Each call gives the whole list, which replaces the one before;
## the session keeps the last one and sends it to the clients.

import Spec from "spec"

NAME = "todo_write"
STATUSES = ["pending", "in_progress", "completed"]
MAX_TODOS = 100
MAX_CONTENT = 500

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

## The list of a call, checked: at most `MAX_TODOS` items, each with some text and a known status, one in progress at
## most.
def todos(input: JSON.Value) -> Result[List[Todo]]
  args = try Spec.args(input, TodoWriteArgs.codec)
  return error("at most #{MAX_TODOS} todos") if args.todos.size > MAX_TODOS

  for todo in args.todos
    return error("a todo has no content") if todo.content.strip.empty?
    return error("a todo is over #{MAX_CONTENT} characters") if todo.content.length > MAX_CONTENT
    return error("unknown status #{todo.status}: use #{STATUSES.join(", ")}") if not STATUSES.include?(todo.status)
  end

  return error("at most one todo is in_progress") if (args.todos.count { |t| t.status == "in_progress" } > 1)

  ok(args.todos.map { |t| t.with(content: t.content.strip) })
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

def box(status: String) -> String
  case status
    "completed" -> "[x]"
    "in_progress" -> "[>]"
    _ -> "[ ]"
  end
end
