---
title: Configuration
description: Finn's config files, its environment variables and the folders where it keeps its state, sessions and keys.
weight: 30
---

# Configuration

Finn reads environment variables when the server starts, and a few JSON files. A flag of `finn serve` sets its variable: `--api`, `--provider`, `--model`, `--base-url` and `--approvals`.

## The user's config file

`~/.config/finn/config.json` (`$XDG_CONFIG_HOME/finn/config.json` when that is set; `FINN_CONFIG` names another file):

```json
{
  "approvals": false,
  "permission": ["ask bash(*)", "allow bash(npm test *)", "deny read_file(.env*)", "deny bash(rm *)"],
  "providers": [
    {"name": "together", "base_url": "https://api.together.xyz/v1", "key_env": "TOGETHER_API_KEY"}
  ]
}
```

| Key | What it does |
|---|---|
| `approvals` | `true` makes a call of a [tool that asks](security.md#what-asks) wait for your answer, unless a rule allows it |
| `permission` | the rules, in order: the last one that matches a call allows it, asks or denies it; a file rule covers the file tools only, not `bash` ([how they check bash](security.md#how-rules-check-bash)) |
| `providers` | OpenAI-compatible APIs of your own ([Providers](providers.md#your-own-provider)) |

Every key is optional, and so is the file. How the rules work is on [Approvals and security](security.md#rules), and where they fall short in [What rules cannot do](security.md#what-rules-cannot-do).

## The project file

`.finn/config.json` in the folder of a session holds `permission` rules for that project, which come after yours. Its `deny` rules always count. Its `allow` and `ask` rules count only when the folder is under a trusted folder, since an `ask` after your `deny` would win over it. A file with the old `allow` and `deny` keys is ignored there with a warning that names the rules to write. A project file cannot turn the approvals on or off.

## Trusted folders

`FINN_TRUSTED_DIRS` lists folders, separated by `:`. A session in one of them, or below, reads two things that anyone who can write its repository could plant:

- the `allow` and `ask` rules of its `.finn/config.json`;
- its skills ([Skills](skills.md)).

The deny rules of a project count everywhere.

## Folders

| What | Where | Variable |
|---|---|---|
| state: `server.json`, the log, the model catalog, MCP logs | `~/.local/state/finn` | `FINN_STATE_DIR` (else `$XDG_STATE_HOME/finn`) |
| sessions, one file each | `~/.local/share/finn/sessions` | `FINN_DATA_DIR` (else `$XDG_DATA_HOME/finn`) |
| config and stored keys | `~/.config/finn` | `$XDG_CONFIG_HOME/finn` |
| the Monty worker of code mode | `~/.cache/finn` | `$XDG_CACHE_HOME/finn` |

The server makes the state and data folders with mode 0700, and refuses one that others can open or that is a link. Only the folder itself is checked: a link higher up its path is fine.

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
| `FINN_TRUSTED_DIRS` | the [trusted folders](#trusted-folders) |
| `FINN_MCP_CONFIG` | the JSON file of MCP servers ([MCP](mcp.md)) |
| `FINN_CODE_MODE` | `1` adds the `run_script` tool ([Tools](tools.md#code-mode)) |
| `FINN_MONTY` | a Monty 1.6.0 binary you trust, for code mode |
| `FINN_CONTEXT_WINDOW` | the model's context window in tokens, for compaction |
| `FINN_COMPACT_MODEL` | the model that writes the summary of a compaction ([Sessions](sessions.md#compaction)) |
| `FINN_MODELS_URL` | the models.dev catalog of prices and windows; `off` for none |
| `FINN_MODELS_PROVIDER` | the provider of the model in that catalog |
| `FINN_DRAIN_MS` | how long `finn server stop` waits for the running turns (60000) |
| `FINN_STATE_DIR`, `FINN_DATA_DIR` | the folders above |
| `FINN_SERVER_COMMAND` | the program a client runs to start a server |

The key variables of the providers are on [Providers](providers.md).

## Coming from agc-agent

Finn was called agc-agent before. Some old names still work:

- Most `AGC_AGENT_` variables still work in place of their `FINN_` names, but not `AGC_AGENT_CONFIG` or `AGC_AGENT_MCP_CONFIG`: while one is set without its `FINN_` name, `finn serve` does not start and says to set `FINN_CONFIG` or `FINN_MCP_CONFIG`.
- The state and data folders fall back to an `agc-agent` folder while there is no `finn` one.
- The config folder does not. While `config.json` is in `$XDG_CONFIG_HOME/agc-agent/` or `~/.config/agc-agent/` and not in the `finn` folder, `finn serve` does not start, so its deny rules are not lost: move it to the `finn` folder it names. An old `auth.json` only gets a warning at start: move it there too to keep its stored keys.
