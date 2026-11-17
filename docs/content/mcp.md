---
title: MCP
description: Connect Model Context Protocol servers to Finn, on stdio or streamable HTTP, so the model can call their tools.
weight: 80
---

# MCP

An [MCP](https://modelcontextprotocol.io) server gives the model more tools: a database, a browser, an issue tracker. Finn connects to each server, on stdio or over streamable HTTP, and offers its tools to every session.

## Set it up

`FINN_MCP_CONFIG` names a JSON file in the shape most agents use:

```json
{
  "mcpServers": {
    "fs": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/me/notes"]
    },
    "tracker": {
      "url": "https://mcp.example.com/mcp",
      "headers": {"Authorization": "Bearer ${TRACKER_TOKEN}"}
    }
  }
}
```

```sh
FINN_MCP_CONFIG=~/.config/finn/mcp.json finn serve
```

A server name is letters, digits, `_` and `-`, with no `__`. A server has either a `command` or a `url`: one with both is refused.

## On stdio

`command`, `args` and `env` start the server as a child process.

- It gets the short environment of the `bash` tool plus its `env`, passed on as given. Put the keys it needs there: it does not see the rest of Finn's environment.
- Its stderr goes to `mcp/NAME.log` in the state folder.
- A server that crashed or hung gives an error result, and starts again on the next call.

## Over HTTP

`url` and `headers` connect to a server on streamable HTTP.

- `${NAME}` in a header value is the variable `NAME` of Finn's environment, so a key stays out of the file. The variable must be set. Its value is never shown in an error or a log.
- The URL is `http://` or `https://`, with no user part (`https://user:key@host` is refused: put the key in `headers`).
- Headers over `http://` are refused unless the host is this machine (`localhost`, `127.x.x.x` or `[::1]`), since they would cross the network in clear text.
- A header that the transport sets is refused: `Accept`, `Connection`, `Content-Length`, `Content-Type`, `Host`, `Last-Event-ID`, `Mcp-Protocol-Version`, `Mcp-Session-Id` and `Transfer-Encoding`.
- Answers come as JSON or as SSE. Finn keeps the session id the server gives, resumes a cut stream with `Last-Event-ID`, starts a new session when the server ended one, and ends its session with a `DELETE`.

## Its tools

A tool of server `NAME` is `mcp__NAME__TOOL`. Finn connects to the servers in the background: a slow server (`npx` on its first run) does not hold up the start, and its tools come from the next turn once it lists them.

A server whose tools cannot be listed is left out, and so is a tool whose name another server already has; the server log says so (`finn server logs`).

MCP tools follow the approvals and the deny rules as the other tools do. With the approvals on, a call asks before it runs unless a rule allows it: `"allow": ["mcp__fs__read_file(*)"]`. The rule's pattern matches the call's JSON input. See [Approvals and security](security.md).
