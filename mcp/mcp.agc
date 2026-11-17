## A client for MCP servers on stdio (JSON-RPC 2.0 with one message per line) or streamable HTTP (a POST per message,
## answered with JSON or SSE, with the session id, resume and DELETE of revision 2025-06-18): `initialize`,
## `tools/list` and `tools/call`. Each server is an actor that owns its process or HTTP session, started on the first
## use and again after it failed.
##
## Errors: `mcp.unavailable` (the server did not start, exited, could not be reached, answered nothing in time or
## broke the protocol: it is stopped, and the next use starts it again) and `mcp.rpc` (the server answered with a JSON-RPC error, its code as
## `code`). A tool that fails says so in `Output.is_error`, not as an error.

import Conn from "src/client"
import Rpc from "src/rpc"

VERSION = "0.0.1"

export Conn.Server
export Conn.Options
export Conn.Client
export Rpc.Tool
export Rpc.Output

## The client of `server`; its process starts on the first use.
def start(server: Conn.Server, options: Conn.Options = Conn.Options()) -> Conn.Client
  Conn.start(server, VERSION, options)
end

## The tools of the server, every page.
def tools(client: Conn.Client) -> Result[List[Rpc.Tool]] = Conn.tools(client)

## Calls the tool `name` with the JSON object `arguments`.
def call(client: Conn.Client, name: String, arguments: JSON.Value) -> Result[Rpc.Output]
  Conn.call(client, name, arguments)
end

## Stops the client and its server.
def stop(client: Conn.Client) -> Void
  Conn.stop(client)
end
