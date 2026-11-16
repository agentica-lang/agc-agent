## A fake MCP server on stdio for the tests. Its tools: `echo` (the `text` argument), `fail` (a tool error), `big`
## (60000 characters), `greeting` (the variable `FAKE_MCP_GREETING`), `image` (an image part), `crash` (exits) and
## `hang` (never answers). `tools/list` comes in two pages, the first after a request of the server (`ping`), a
## notification and a line that is no JSON. Each start adds a line to the file `FAKE_MCP_STARTS` when it is set.

TOOLS = ["echo", "fail", "big", "greeting", "image", "crash", "hang"]

def main() -> Void
  case System.env("FAKE_MCP_STARTS")
    ok(path) if not path.empty? -> _ = File.append_text(path, "start\n")
    _ -> nil
  end

  while true
    case IO.gets()
      ok(line) -> serve(line)
      error(_) -> break
    end
  end
end

private

def serve(line: String) -> Void
  json = JSON.parse(line).unwrap_or(JSON.object({}))
  method = text(json, "method")
  id = JSON.get(json, "id").unwrap_or(JSON.from(0))
  case method
    "initialize" ->
      answer(
        id,
        JSON.object({
          "protocolVersion": JSON.from("2025-06-18"),
          "capabilities": JSON.object({"tools": JSON.object({})}),
          "serverInfo": JSON.object({"name": JSON.from("fake"), "version": JSON.from("1")}),
        }),
      )
    "tools/list" -> list(id, json)
    "tools/call" -> call(id, JSON.get(json, "params").unwrap_or(JSON.object({})))
    _ -> nil
  end
end

def list(id: JSON.Value, json: JSON.Value) -> Void
  params = JSON.get(json, "params").unwrap_or(JSON.object({}))
  if text(params, "cursor") == "page2"
    answer(id, JSON.object({"tools": JSON.array(TOOLS.drop(3).map { |name| tool(name) })}))
    return
  end

  send(JSON.object({"jsonrpc": JSON.from("2.0"), "id": JSON.from("srv-1"), "method": JSON.from("ping")}))
  send(JSON.object({"jsonrpc": JSON.from("2.0"), "method": JSON.from("notifications/message")}))
  puts("not json")
  IO.flush()
  page = JSON.object({"tools": JSON.array(TOOLS.take(3).map { |name| tool(name) }), "nextCursor": JSON.from("page2")})
  answer(id, page)
end

def tool(name: String) -> JSON.Value
  schema = JSON.parse("{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}}}").unwrap!
  JSON.object({"name": JSON.from(name), "description": JSON.from("The #{name} tool."), "inputSchema": schema})
end

def call(id: JSON.Value, params: JSON.Value) -> Void
  arguments = JSON.get(params, "arguments").unwrap_or(JSON.object({}))
  case text(params, "name")
    "echo" -> answer(id, content([text_part(text(arguments, "text"))], false))
    "fail" -> answer(id, content([text_part("it failed")], true))
    "big" -> answer(id, content([text_part("x" * 60000)], false))
    "greeting" -> answer(id, content([text_part(System.env("FAKE_MCP_GREETING").unwrap_or(""))], false))
    "image" ->
      image = JSON.object({"type": JSON.from("image"), "mimeType": JSON.from("image/png"), "data": JSON.from("AA==")})
      answer(id, content([text_part("a picture:"), image], false))
    "crash" -> System.exit(1)
    "hang" -> Task.sleep(600_000)
    _ ->
      err = JSON.object({"code": JSON.from(-32602), "message": JSON.from("unknown tool #{text(params, "name")}")})
      send(JSON.object({"jsonrpc": JSON.from("2.0"), "id": id, "error": err}))
  end
end

def text_part(value: String) -> JSON.Value = JSON.object({"type": JSON.from("text"), "text": JSON.from(value)})

def content(parts: List[JSON.Value], is_error: Bool) -> JSON.Value
  JSON.object({"content": JSON.array(parts), "isError": JSON.from(is_error)})
end

def answer(id: JSON.Value, result: JSON.Value) -> Void
  send(JSON.object({"jsonrpc": JSON.from("2.0"), "id": id, "result": result}))
end

def send(json: JSON.Value) -> Void
  puts(JSON.encode(json))
  IO.flush()
end

def text(json: JSON.Value, key: String) -> String
  case JSON.get(json, key)
    ok(value) -> JSON.string(value).unwrap_or("")
    error(_) -> ""
  end
end
