---
title: MCP
description: Connect Model Context Protocol servers to Finn, on stdio or streamable HTTP, so the model can call their tools.
weight: 80
---

# MCP

An [MCP](https://modelcontextprotocol.io) server gives the model more tools: a database, a browser, an issue tracker. Finn connects to each server, on stdio or over streamable HTTP, and offers its tools to the sessions it belongs to.

## Set it up

Servers come from two JSON files in the shape most agents use. `~/.config/finn/mcp.json` (`$XDG_CONFIG_HOME/finn/mcp.json`) is the user's file. It is read when it exists, and a file that is missing is no error; one that cannot be read or parsed is a warning, and the server starts without its servers. `FINN_MCP_CONFIG` names another file that replaces it: that file must be there and read, or `finn serve` does not start, and an empty `FINN_MCP_CONFIG=` means no MCP servers at all. [`.finn/mcp.json`](#a-project-file) of a session folder adds the servers of a project.

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

`.finn/mcp.json` in the session folder has the same shape. It starts programs from a repository, so it counts only in a [trusted folder](config.md#trusted-folders) (`FINN_TRUSTED_DIRS`), like `.finn/commands/`: anyone who can write the repository could plant a command there. In another folder it is ignored, with one warning that names the file and `FINN_TRUSTED_DIRS`. Even in a trusted folder it cannot read your environment: a header value with `${NAME}` leaves its server out, with a warning that names the variable (never its value). Put a key in your own file instead.

- The servers belong to the sessions of that folder that the server has loaded. The first session there starts them, the sessions there share them, and the end of the last one stops them (a session that is not loaded, or deleted, starts nothing). A server on stdio starts in the folder. The session events come in order but do not wait for the server: if one is lost, the folder still gets its servers when its tools are read, and servers may then run until the server exits.
- A project server named like a user server is left out with a warning: rename it, since the user's approval rules for `mcp__NAME__` would apply to it.
- A project server that does not read is left out with a warning, and the others of the file start. A file that does not parse starts none.
- Its logs are `mcp/project-HASH-NAME.log` in the state folder, with a short hash of the folder.

`/reload` reads the user's file and the project file of each folder with sessions again, and says how many project servers stopped and started. A changed file restarts its servers; a file that does not read keeps the servers that run.

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

## Its state

`/mcp` lists the servers with their state: `connecting` while one starts, `connected` with its number of tools, or `failed` with the reason. `connected` means it listed its tools at its last start; a stdio server that crashed since starts again at its next call, and the list does not know it yet. It shows where each one comes from (`user` for your file, `project` for the `.finn/mcp.json` of the session folder) and how it runs: the program of a stdio server or the origin of an HTTP one, never its environment or headers. `/mcp NAME` lists the tools of one, one per line with air between them and the names in bold. A server that failed to start is in the banner at the top of `finn`.

`/mcp reconnect NAME` stops the client of that server and starts it again: use it after you fixed what made it fail (a missing program, a key, a server that was down). The answer comes when the server has listed its tools. A server that crashed later starts again by itself at its next call.

## Its tools

A tool of server `NAME` is `mcp__NAME__TOOL`. Finn connects to the servers in the background: a slow server (`npx` on its first run) does not hold up the start, and its tools come from the next turn once it lists them.

A server whose tools cannot be listed is left out, and so is a tool whose name another server already has; the server log says so (`finn server logs`).

MCP tools follow the approvals and the deny rules as the other tools do. With the approvals on, a call asks before it runs unless a rule allows it: `"permission": ["allow mcp__fs__read_file(*)"]`. The rule's pattern matches the call's JSON input. See [Approvals and security](security.md).
