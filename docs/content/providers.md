---
title: Providers
description: The model providers Finn talks to, how to log in to one, and how to add an OpenAI-compatible API of your own.
weight: 20
---

# Providers

A provider is where the model runs: a company's API or a server of your own. The server offers several at once, and each session uses one. Pick it with `/model PROVIDER/NAME` in a session, or `--provider` for a new one.

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
| `opencode-go` | its key is set or stored | `OPENCODE_API_KEY` | OpenAI chat completions |
| `chatgpt` | you signed in with `finn login chatgpt` | your ChatGPT plan ([ChatGPT](#chatgpt-plus-or-pro)) | OpenAI Responses (Codex) |

Your config file can add more, or replace one of these: see [Your own provider](#your-own-provider).

A model call fails when its API sends nothing for 2 minutes in the middle of an answer.

## Log in

```sh
finn login              # pick a provider, then paste its key
finn login openrouter   # or name it
finn logout openrouter  # remove its stored key
finn logout             # remove every stored key (and the base URL of local)
```

In `finn` (the full screen), `/login` and `/logout` do the same. The key is asked for and hidden; it is never an argument.

A login checks the key with one call to the provider (`GET /models`, or `/key` for OpenRouter) and stores it in `~/.config/finn/auth.json` (`$XDG_CONFIG_HOME/finn/auth.json` when that is set), with mode 0600. Finn does not read the file when others may read it or another user owns it, and the server says why. A key is never logged.

A key variable in the environment wins over a stored key.

The login list also shows `Claude Pro/Max: coming`. It is listed but cannot be used: picking it says there is no login for it yet.

## Pick a provider and a model

- In a session: `/model` alone lists the models or shows the current one. `/model NAME` changes the model on the session's provider, and `/model PROVIDER/NAME` changes both, from the next turn on. On OpenRouter, `/model openrouter/anthropic/NAME` keeps the session on OpenRouter.
- For a new session: `finn --provider NAME --model NAME` (or `finn chat` with the same options).
- For the server: `FINN_PROVIDER` (`finn serve --provider`) is the provider of a session that names none, and `FINN_MODEL` (`--model`) its model.

The server takes any model name. `/model NAME` with a name that the session's provider does not list but another provider does, whole or in part, changes nothing and names those models (`/model local/NAME` keeps the name on `local`). When the first turn after `/model` fails, the client says so; check the name. When the local server does not answer, the client says that `/model PROVIDER/NAME` picks another provider.

## OpenCode Go

`opencode-go` is the OpenCode Go subscription, through its OpenAI chat completions endpoint (`https://opencode.ai/inference/go/v1`). Give it the key of your OpenCode account, then pick a model:

```sh
finn login opencode-go        # or set OPENCODE_API_KEY
finn --provider opencode-go --model deepseek-v4.1-flash
```

## Local: llama.cpp and other servers

`local` is any server with an OpenAI-compatible API. By default it is a llama.cpp `llama-server` at `http://127.0.0.1:8080/v1`:

```sh
llama-server -m model.gguf --port 8080
finn
```

| Variable | `finn serve` flag | Default |
|---|---|---|
| `FINN_BASE_URL` | `--base-url` | `http://127.0.0.1:8080/v1` |
| `FINN_API` | `--api` | `openai` (chat completions); or `openai_responses` |
| `FINN_API_KEY` | | none |
| `FINN_MODEL` | `--model` | `default` |

`finn login local` (or `/login local`) sets the base URL without a variable: it asks for the URL, checks that `GET /models` answers there, and stores it in `auth.json`, so the server uses it (and its `/props`) from then on, also after a restart. The check sends `FINN_API_KEY` as a Bearer token when it is set, as the turns do, so a server that needs a key can log in. The URL is `http://` or `https://`, a host and a path, with no user, password, query or fragment. `FINN_BASE_URL` wins over a stored URL. `finn logout local` goes back to the default.

## Anthropic

`anthropic` uses the Anthropic Messages API at `ANTHROPIC_BASE_URL`, else Anthropic's own. Its credential is the first of:

1. `ANTHROPIC_API_KEY`;
2. `ANTHROPIC_AUTH_TOKEN`;
3. a key stored by `finn login anthropic`;
4. the token of `ant auth login` (the Anthropic CLI), fetched again after a 401.

Finn asks for the prompt cache on every request. `FINN_API=anthropic` (`finn serve --api anthropic`) makes it the server's provider, with `claude-opus-5-5` as its default model.

## ChatGPT Plus or Pro

`chatgpt` runs the Codex models of your ChatGPT plan, with no API key:

```sh
finn login chatgpt      # or /login chatgpt in finn
```

Finn shows a URL and a code. Open the URL, sign in, and enter the code within 15 minutes; Esc stops waiting. Finn then lists the models of your plan and keeps the tokens in `chatgpt.json` in the state folder (`~/.local/state/finn`), mode 0600, apart from `auth.json`. The first of the list is the default model. An expired token is refreshed when a call gets a 401, once for all sessions at a time. `finn logout chatgpt` removes the file.

## Your own provider

The `providers` list of your config file (`~/.config/finn/config.json`) adds an OpenAI-compatible API, or replaces a preset of the same name:

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
- With `key_env`, the provider is offered only when that variable is set or a login stored its key. Without it, the provider needs no key.
- `models` are the names a client offers in `/model`.

The server warns when two providers take the same key variable: that key would go to both URLs.

## Costs

When the [models.dev](https://models.dev) catalog has the prices of the model, each usage event has its cost in USD: the call's, the turn's and the session's. The server loads the catalog at the start and keeps it a day. `FINN_MODELS_URL=off` turns it off.
