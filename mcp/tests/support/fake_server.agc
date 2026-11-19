## A fake MCP server on stdio for the tests. Its tools: `echo` (the `text` argument), `fail` (a tool error), `big`
## (60000 characters), `greeting` (the variable `FAKE_MCP_GREETING`), `probe` (the variable named by `text`), `image`
## (an image part), `cwd` (its folder), `grandchild` (starts a `sleep` that outlives this server, and gives its pid), `crash` (exits) and
## `hang` (never answers). `tools/list` comes in two pages, the first after two requests of the server (`ping` and
## another), a notification and a line that is no JSON.
##
## Each start adds a line to the file `FAKE_MCP_STARTS`, and each line the client sends goes to `FAKE_MCP_SEEN`, when
## they are set; `FAKE_MCP_SLOW_MS` waits before the first page of `tools/list`. `FAKE_MCP_MODE`: `loop` gives the same
## next cursor for ever, `endless` a new one each time, `odd` lists `echo` twice, `probe` and a tool with a bad name,
## and `shuffle` answers a call first with another id.

TOOLS = ["echo", "fail", "big", "greeting", "probe", "image", "grandchild", "crash", "hang", "cwd"]

def main() -> Void
  case System.env("FAKE_MCP_STARTS")
    ok(path) if not path.empty? -> _ = File.append_text(path, "start\n")
    _ -> nil
  end

  while true
    case IO.gets()
      ok(line) ->
        note(line)
        serve(line)
      error(_) -> break
    end
  end
end

private

def mode() -> String = System.env("FAKE_MCP_MODE").unwrap_or("")

def note(line: String) -> Void
  case System.env("FAKE_MCP_SEEN")
    ok(path) if not path.empty? -> _ = File.append_text(path, "#{line}\n")
    _ -> nil
  end
end

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
  if text(params, "cursor").empty?
    Task.sleep(System.env("FAKE_MCP_SLOW_MS").unwrap_or("0").to_i.unwrap_or(0))
  end

  if mode() == "endless"
    next = "c#{JSON.encode(params).length}-#{Random.int(0, 999_999_999)}"
    answer(id, JSON.object({"tools": JSON.array([tool("echo")]), "nextCursor": JSON.from(next)}))
    return
  end

  if mode() == "loop"
    answer(id, JSON.object({"tools": JSON.array([tool("echo")]), "nextCursor": JSON.from("same")}))
    return
  end

  if mode() == "odd"
    answer(id, JSON.object({"tools": JSON.array([tool("echo"), tool("echo"), tool("probe"), tool("bad name!")])}))
    return
  end

  if text(params, "cursor") == "page2"
    answer(id, JSON.object({"tools": JSON.array(TOOLS.drop(3).map { |name| tool(name) })}))
    return
  end

  send(JSON.object({"jsonrpc": JSON.from("2.0"), "id": JSON.from("srv-1"), "method": JSON.from("ping")}))
  sampling = JSON.from("sampling/createMessage")
  send(JSON.object({"jsonrpc": JSON.from("2.0"), "id": JSON.from("srv-2"), "method": sampling}))
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
  if mode() == "shuffle"
    wrong = JSON.from(JSON.int(id).unwrap_or(0) + 1000)
    answer(wrong, content([text_part("not yours")], false))
  end

  case text(params, "name")
    "echo" -> answer(id, content([text_part(text(arguments, "text"))], false))
    "fail" -> answer(id, content([text_part("it failed")], true))
    "big" -> answer(id, content([text_part("x" * 60000)], false))
    "greeting" -> answer(id, content([text_part(System.env("FAKE_MCP_GREETING").unwrap_or(""))], false))
    "probe" -> answer(id, content([text_part(System.env(text(arguments, "text")).unwrap_or(""))], false))
    "grandchild" ->
      process = Process.spawn("/bin/sh", ["-c", "sleep 300 > /dev/null 2>&1 & echo $!"]).unwrap!
      pid = Process.read_line(process, 5000).unwrap_or("")
      _ = Process.wait(process, 5000)
      answer(id, content([text_part(pid)], false))
    "cwd" -> answer(id, content([text_part(Path.cwd().unwrap_or(""))], false))
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
