---
title: Providers
description: The model providers Finn talks to, how to log in to one, and how to add an OpenAI-compatible API of your own.
weight: 20
---

# Providers

A provider is where the model runs: a company's API or a server of your own.
The server offers several at once, and each session uses one. Pick it with
`/model PROVIDER/NAME` in a session, or `--provider` for a new one.

## The providers

| Provider | Offered when | Key | API |
|---|---|---|---|
| `local` | always | `FINN_API_KEY` (optional) | `FINN_API` at `FINN_BASE_URL` |
| `anthropic` | always | see [Anthropic](#anthropic) | Anthropic Messages |
| `openai` | its key is set or stored | `OPENAI_API_KEY` | OpenAI Responses |
| `openrouter` | its key is set or stored | `OPENROUTER_API_KEY` | OpenAI chat completions |
| `fireworks` | its key is set or stored | `FIREWORKS_API_KEY` | OpenAI chat completions |
| `groq` | its key is set or stored | `GROQ_API_KEY` | OpenAI chat completions |
| `deepseek` | its key is set or stored | `DEEPSEEK_API_KEY` | OpenAI chat completions |

Your config file can add more, or replace one of these: see
[Your own provider](#your-own-provider).

## Log in

```sh
finn login              # pick a provider, then paste its key
finn login openrouter   # or name it
finn logout openrouter  # remove its stored key
finn logout             # remove every stored key
```

In `finn tui`, `/login` and `/logout` do the same. The key is asked for and
hidden; it is never an argument.

A login checks the key with one call to the provider (`GET /models`, or
`/key` for OpenRouter) and stores it in `~/.config/finn/auth.json`
(`$XDG_CONFIG_HOME/finn/auth.json` when that is set), readable by you alone.
Finn does not read the file when others may read it or another user owns it,
and the server says why.

A key variable in the environment wins over a stored key.

The login list also shows Claude Pro/Max and ChatGPT/Codex subscriptions.
They have no login yet.

## Pick a provider and a model

- In a session: `/model` alone lists the models or shows the current one.
  `/model NAME` changes the model on the session's provider, and
  `/model PROVIDER/NAME` changes both, from the next turn on. On OpenRouter,
  `/model openrouter/anthropic/NAME` keeps the session on OpenRouter.
- For a new session: `finn --provider NAME --model NAME` (or `finn tui` with
  the same options).
- For the server: `FINN_PROVIDER` (`finn serve --provider`) is the provider of
  a session that names none, and `FINN_MODEL` (`--model`) its model.

The server takes any model name. When the first turn after `/model` fails, the
client says so; check the name.

## Local: llama.cpp and other servers

`local` is any server with an OpenAI-compatible API. By default it is a
llama.cpp `llama-server` at `http://127.0.0.1:8080/v1`:

```sh
llama-server -m model.gguf --port 8080
finn
```

| Variable | `finn serve` flag | Default |
|---|---|---|
| `FINN_BASE_URL` | `--base-url` | `http://127.0.0.1:8080/v1` |
| `FINN_API` | `--api` | `openai` (chat completions); or `openai_responses` |
| `FINN_API_KEY` | | none |
| `FINN_MODEL` | `--model` | none |

On a local server, Finn reads the context window from llama-server's `/props`.

## Anthropic

`anthropic` uses the Anthropic Messages API at `ANTHROPIC_BASE_URL`, else
Anthropic's own. Its credential is the first of:

1. `ANTHROPIC_API_KEY`;
2. `ANTHROPIC_AUTH_TOKEN`;
3. a key stored by `finn login anthropic`;
4. the token of `ant auth login` (the Anthropic CLI), fetched again after a
   401.

A credential is never logged. Finn asks for the prompt cache on every request.
`FINN_API=anthropic` (`finn serve --api anthropic`) makes it the server's
provider, with `claude-opus-5-5` as its default model.

## Your own provider

The `providers` list of your config file (`~/.config/finn/config.json`) adds
an OpenAI-compatible API, or replaces a preset of the same name:

```json
{
  "providers": [
    {
      "name": "together",
      "api": "openai",
      "base_url": "https://api.together.xyz/v1",
      "key_env": "TOGETHER_API_KEY",
      "models": ["meta-llama/Llama-3.3-70B-Instruct-Turbo"]
    }
  ]
}
```

- `name` and `base_url` are required. A name has no `/`.
- `api` is `openai` (chat completions, the default) or `openai_responses`.
- With `key_env`, the provider is offered only when that variable is set or a
  login stored its key. Without it, the provider needs no key.
- `models` are the names a client offers in `/model`.

The server warns when two providers take the same key variable: that key
would go to both URLs.

## Costs

Each usage event of a session has its cost in USD, from the
[models.dev](https://models.dev) catalog. The server loads it at the start
and keeps it a day. `FINN_MODELS_URL=off` turns it off.
