---
title: MCP
description: Connect Model Context Protocol servers to Finn, so the model can call their tools.
weight: 80
---

# MCP

An [MCP](https://modelcontextprotocol.io) server gives the model more tools:
a database, a browser, an issue tracker. Finn starts each server on stdio and
offers its tools to every session.

## Set it up

`FINN_MCP_CONFIG` names a JSON file in the shape most agents use:

```json
{
  "mcpServers": {
    "fs": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/me/notes"]
    },
    "github": {
      "command": "github-mcp-server",
      "args": ["stdio"],
      "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "..."}
    }
  }
}
```

```sh
FINN_MCP_CONFIG=~/.config/finn/mcp.json finn serve
```

- A server name is letters, digits, `_` and `-`, with no `__`.
- A server gets the short environment of the `bash` tool plus its `env`,
  passed on as given. Put the keys it needs there: it does not see the rest of
  the server's environment.
- Its stderr goes to `mcp/NAME.log` in the state folder.

## Its tools

A tool of server `NAME` is `mcp__NAME__TOOL`. Finn starts the servers in the
background: a slow server (`npx` on its first run) does not hold up the
start, and its tools come from the next turn once it lists them.

A server whose tools cannot be listed is left out, and so is a tool whose name
another server already has; the server log says so.

With the approvals on, a call of an MCP tool asks before it runs, unless a
rule allows it: `"allow": ["mcp__fs__read_file(*)"]`. The rule's pattern
matches the call's JSON input. See [Approvals and security](security.md).

## Transports

Finn speaks MCP over stdio.
