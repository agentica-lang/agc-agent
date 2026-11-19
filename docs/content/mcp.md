---
title: MCP
description: Connect Model Context Protocol servers to Finn, on stdio or streamable HTTP, so the model can call their tools.
weight: 80
---

# MCP

An [MCP](https://modelcontextprotocol.io) server gives the model more tools: a database, a browser, an issue tracker. Finn connects to each server, on stdio or over streamable HTTP, and offers its tools to the sessions it belongs to.

## Set it up

Servers come from two JSON files in the shape most agents use. `~/.config/finn/mcp.json` (`$XDG_CONFIG_HOME/finn/mcp.json`) is the user's file: it is read when it exists, and `FINN_MCP_CONFIG` names another file that replaces it. [`.finn/mcp.json`](#a-project-file) of a session folder adds the servers of a project.

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

A server name is letters, digits, `_` and `-`, with no `__`. A server has either a `command` or a `url`: one with both is refused.

## A project file

`.finn/mcp.json` in the session folder has the same shape. It starts programs from a repository, so it counts only in a [trusted folder](config.md#trusted-folders) (`FINN_TRUSTED_DIRS`), like `.finn/commands/`: anyone who can write the repository could plant a command there. In another folder it is ignored, with one warning that names the file and `FINN_TRUSTED_DIRS`. A project file can use `${NAME}` in a header as the user's file does, so trust a folder only when you trust its files.

- The servers belong to the sessions of that folder. The first session there starts them, the sessions there share them, and the end of the last one stops them. A server on stdio starts in the folder.
- A project server of the name of a user server takes its place in that folder, with a warning. The user's server stays for the other folders.
- A project file that does not read gives a warning, and no server of it starts.
- Its logs are `mcp/project-NAME.log` in the state folder.

`/reload` reads the user's file and the project file of each folder with sessions again. A changed file restarts its servers; a file that does not read keeps the servers that run.

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

MCP tools follow the approvals and the deny rules as the other tools do. With the approvals on, a call asks before it runs unless a rule allows it: `"permission": ["allow mcp__fs__read_file(*)"]`. The rule's pattern matches the call's JSON input. See [Approvals and security](security.md).
