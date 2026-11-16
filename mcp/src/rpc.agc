## JSON-RPC 2.0 messages of MCP on stdio, one JSON object per line, and the MCP records read from them. Pure.

PROTOCOL_VERSION = "2025-06-18"
METHOD_NOT_FOUND = -32601

## A tool a server offers.
struct Tool
  name: String
  description: String
  input_schema: JSON.Value
end

## What a tool call gave: its content as text, and whether the tool says it failed.
struct Output
  text: String
  is_error: Bool
end

## A message from the server: an answer to a request of ours (no `method`), a request of the server (`method` and
## `id`) or a notification (`method` only).
struct Incoming
  id: Optional[JSON.Value]
  method: String
  result: Optional[JSON.Value]
  error: Optional[JSON.Value]
end

## A tool list and the cursor of the next page, `""` on the last one.
struct Page
  tools: List[Tool]
  cursor: String
end

def request(id: Int, method: String, params: JSON.Value) -> String
  line({"jsonrpc": JSON.from("2.0"), "id": JSON.from(id), "method": JSON.from(method), "params": params})
end

def notification(method: String) -> String = line({"jsonrpc": JSON.from("2.0"), "method": JSON.from(method)})

## The answer to a request of the server: `{}` for `ping`, "method not found" for any other.
def answer(id: JSON.Value, method: String) -> String
  fields: Map[String, JSON.Value] = {"jsonrpc": JSON.from("2.0"), "id": id}
  if method == "ping"
    fields = fields.put("result", JSON.object({}))
  else
    message = JSON.from("method not found: #{method}")
    fields = fields.put("error", JSON.object({"code": JSON.from(METHOD_NOT_FOUND), "message": message}))
  end

  line(fields)
end

def initialize_params(client: String, version: String) -> JSON.Value
  JSON.object({
    "protocolVersion": JSON.from(PROTOCOL_VERSION),
    "capabilities": JSON.object({}),
    "clientInfo": JSON.object({"name": JSON.from(client), "version": JSON.from(version)}),
  })
end

def list_params(cursor: String) -> JSON.Value
  return JSON.object({}) if cursor.empty?

  JSON.object({"cursor": JSON.from(cursor)})
end

def call_params(name: String, arguments: JSON.Value) -> JSON.Value
  JSON.object({"name": JSON.from(name), "arguments": arguments})
end

def parse(text: String) -> Result[Incoming]
  json = try JSON.parse(text)
  return error("not a JSON object") if JSON.kind(json) != "object"

  ok(
    Incoming(
      id: at(json, "id"),
      method: string_at(json, "method"),
      result: at(json, "result"),
      error: at(json, "error"),
    ),
  )
end

## Whether `incoming` answers our request `id`.
def answers?(incoming: Incoming, id: Int) -> Bool
  return false if not incoming.method.empty?

  case incoming.id
    some(value) -> JSON.int(value) == ok(id)
    none -> false
  end
end

## The result of an answer, or its error as `mcp.rpc` with the JSON-RPC code.
def outcome(incoming: Incoming) -> Result[JSON.Value]
  case incoming.error
    some(err) ->
      code = at(err, "code").map { |c| JSON.int(c).unwrap_or(0) }.unwrap_or(0)
      error("mcp: #{string_at(err, "message")}", kind: "mcp.rpc", code: code)
    none -> ok(incoming.result.unwrap_or(JSON.object({})))
  end
end

## A page of `tools/list`. A tool with no name is left out.
def page(result: JSON.Value) -> Page
  tools = list_at(result, "tools").map { |t| tool(t) }.select { |t| not t.name.empty? }
  Page(tools: tools, cursor: string_at(result, "nextCursor"))
end

## The result of `tools/call`: the text parts joined by lines, other parts named, and the structured content when there
## is no part.
def output(result: JSON.Value) -> Output
  parts = list_at(result, "content").map { |c| part_text(c) }
  text = parts.join("\n")
  if parts.empty?
    for structured in option_list(at(result, "structuredContent"))
      text = JSON.encode(structured)
    end
  end

  is_error = at(result, "isError").map { |b| JSON.bool(b).unwrap_or(false) }.unwrap_or(false)
  Output(text: text, is_error: is_error)
end

private

def line(fields: Map[String, JSON.Value]) -> String = "#{JSON.encode(JSON.object(fields))}\n"

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(x) -> [x]
    none -> []
  end
end

def at(json: JSON.Value, key: String) -> Optional[JSON.Value]
  case JSON.get(json, key)
    ok(value) if not JSON.null?(value) -> some(value)
    _ -> none
  end
end

def string_at(json: JSON.Value, key: String) -> String
  at(json, key).map { |v| JSON.string(v).unwrap_or("") }.unwrap_or("")
end

def list_at(json: JSON.Value, key: String) -> List[JSON.Value]
  case at(json, key)
    some(value) -> JSON.list(value).unwrap_or([])
    none -> []
  end
end

def tool(json: JSON.Value) -> Tool
  schema = at(json, "inputSchema").unwrap_or(JSON.object({"type": JSON.from("object")}))
  Tool(name: string_at(json, "name"), description: string_at(json, "description"), input_schema: schema)
end

def part_text(part: JSON.Value) -> String
  case string_at(part, "type")
    "text" -> string_at(part, "text")
    "resource" ->
      resource = at(part, "resource").unwrap_or(JSON.object({}))
      text = string_at(resource, "text")
      return text if not text.empty?

      "[resource #{string_at(resource, "uri")}]"
    "resource_link" -> "[resource #{string_at(part, "uri")}]"
    _ -> "[#{string_at(part, "type")} #{string_at(part, "mimeType")}]".strip
  end
end
