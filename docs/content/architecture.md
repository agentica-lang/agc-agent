---
title: Architecture
description: How Finn is built - a server and its clients, the protocol between them, and the Agentica packages of the repository.
weight: 120
---

# Architecture

Finn is a server and its clients, written in Agentica. The repository is an Agentica workspace: one folder per package.

```text
finn      ─┐                        ┌─ LLM APIs (Anthropic, OpenAI, ...)
finn chat ─┼─ HTTP + SSE ── core ───┼─ tools: files, bash, Monty
your app  ─┘   (localhost)          └─ MCP servers (stdio, HTTP)
```

## The server

`core` is the server. It runs on `127.0.0.1`, owns the sessions, and runs the agent loop of each: it sends the history to the model, runs the tool calls the model asks for, and streams every event to the clients that are attached.

- One session is one actor. A turn runs in its own task, so a client that closes stops nothing.
- A session is one file of JSON Lines ([Sessions](sessions.md)).
- Extensions, skills, MCP tools and the approval are all extensions of the core, on one registry ([Extensions](extensions.md)).

One server runs per state folder: it holds a lock there, and a client that finds none starts one in the background.

## The clients

`finn` (`tui_client`) and `finn chat` (the `cli` package) are separate programs. They reach the server only through the `client`, `protocol` and `sse` packages, never through `core`. Any program that speaks the [HTTP API](server.md) is a client too.

## The packages

| Package | What |
|---|---|
| `sse` | Server-Sent Events: a parser and a writer |
| `llm` | the client for LLM APIs: OpenAI chat completions, OpenAI Responses and Anthropic Messages behind one API |
| `mcp` | the client for MCP servers, on stdio and streamable HTTP |
| `protocol` | the commands, replies and events between the server and its clients, with JSON codecs |
| `monty` | Python scripts in pydantic's Monty sandbox, for code mode |
| `bash` | the simple commands of a bash line, read by tree-sitter-bash (a native module built on first use) |
| `core` | the server: agent loop, tools, approval, sessions, extensions |
| `client` | what the clients share: finding or starting the server, the HTTP calls, the event reader |
| `cli` | the line-mode client |
| `tui_client` | the full-screen client, on [agentica-tui](https://github.com/agentica-lang/agentica-tui) |
| `examples/extension` | a program that serves `core` with its own tool, wrapper and service |

`sse`, `llm`, `mcp`, `protocol`, `monty` and `bash` depend on no server or client package, so each could move to a repository of its own. `make coupling` checks these rules.

## For agents

The guide is also published as Markdown: every page has a `.md` version, `llms.txt` lists the pages, and `llms-full.txt` holds all of them in one file.
