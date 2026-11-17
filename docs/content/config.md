---
title: Configuration
description: Finn's config files, its environment variables and the folders where it keeps its state, sessions and keys.
weight: 30
---

# Configuration

Finn reads environment variables when the server starts, and a few JSON files.
A flag of `finn serve` sets its variable: `--api`, `--provider`, `--model`,
`--base-url` and `--approvals`.

## The user's config file

`~/.config/finn/config.json` (`$XDG_CONFIG_HOME/finn/config.json` when that is
set; `FINN_CONFIG` names another file):

```json
{
  "approvals": false,
  "allow": ["bash(npm test*)", "read_file(*)"],
  "deny": ["read_file(.env*)", "bash(rm *)"],
  "providers": [
    {"name": "together", "base_url": "https://api.together.xyz/v1", "key_env": "TOGETHER_API_KEY"}
  ]
}
```

| Key | What it does |
|---|---|
| `approvals` | `true` asks before a tool call that no rule allows ([Approvals](security.md)) |
| `allow` | rules of calls that run without asking, with the approvals on |
| `deny` | rules of calls that are refused, always |
| `providers` | OpenAI-compatible APIs of your own ([Providers](providers.md#your-own-provider)) |

Every key is optional, and so is the file.

## The project file

`.finn/config.json` in the folder of a session holds `allow` and `deny` rules
for that project. Its deny rules always count. Its allow rules count only when
the folder is under one of `FINN_TRUSTED_DIRS`, since anyone who can write the
repository can write them. A project file cannot turn the approvals on or off.

## Folders

| What | Where | Variable |
|---|---|---|
| state: `server.json`, the log, the model catalog | `~/.local/state/finn` | `FINN_STATE_DIR` (else `$XDG_STATE_HOME/finn`) |
| sessions, one file each | `~/.local/share/finn/sessions` | `FINN_DATA_DIR` (else `$XDG_DATA_HOME/finn`) |
| config and stored keys | `~/.config/finn` | `$XDG_CONFIG_HOME/finn` |
| the Monty worker of code mode | `~/.cache/finn` | `$XDG_CACHE_HOME/finn` |

The server makes the state and data folders with mode 0700, and refuses one
that others can open. Session files are plain text, tool output and file
contents included, and stay until you delete them.

## Environment variables

| Variable | What it does |
|---|---|
| `FINN_API` | the API of `local`: `openai` (chat completions, the default) or `openai_responses`; `anthropic` makes Anthropic the server's provider |
| `FINN_BASE_URL` | where `local` is: `http://127.0.0.1:8080/v1` by default |
| `FINN_API_KEY` | the key of `local` |
| `FINN_PROVIDER` | the provider of a session that names none |
| `FINN_MODEL` | the model of a session that names none |
| `FINN_APPROVALS` | `1` turns the approvals on; `0` keeps them off over the config file |
| `FINN_CONFIG` | the user's config file |
| `FINN_TRUSTED_DIRS` | folders (separated by `:`) whose sessions read the project's allow rules and skills |
| `FINN_MCP_CONFIG` | the JSON file of MCP servers ([MCP](mcp.md)) |
| `FINN_CODE_MODE` | `1` adds the `run_script` tool ([Tools](tools.md#code-mode)) |
| `FINN_MONTY` | a Monty 1.6.0 binary you trust, for code mode |
| `FINN_CONTEXT_WINDOW` | the model's context window in tokens, for compaction |
| `FINN_COMPACT_MODEL` | the model that writes the summary of a compaction |
| `FINN_MODELS_URL` | the models.dev catalog of prices and windows; `off` for none |
| `FINN_MODELS_PROVIDER` | the provider of the model in that catalog |
| `FINN_DRAIN_MS` | how long `finn server stop` waits for the running turns (60000) |
| `FINN_STATE_DIR`, `FINN_DATA_DIR` | the folders above |
| `FINN_SERVER_COMMAND` | the program a client runs to start a server |

The key variables of the providers are on [Providers](providers.md).

Coming from an earlier Finn: the names that start with `AGC_AGENT_` still
work in place of `FINN_`, and so does an `agc-agent` folder while there is no
`finn` folder.
