## The options of `serve`, from the environment: `AGC_AGENT_STATE_DIR` (else `$XDG_STATE_HOME/agc-agent`, else
## `~/.local/state/agc-agent`), `AGC_AGENT_DATA_DIR` for the sessions (else `$XDG_DATA_HOME/agc-agent`, else
## `~/.local/share/agc-agent`), and the model API: `AGC_AGENT_API` (`openai`, chat completions, by default, or
## `openai_responses`), `AGC_AGENT_BASE_URL` (a local llama-server by default), `AGC_AGENT_API_KEY` and
## `AGC_AGENT_MODEL`; `AGC_AGENT_CONTEXT_WINDOW` and `AGC_AGENT_COMPACT_MODEL` for compaction.

import LLM from "pkg/llm/llm"
import Server from "server"
import Tools from "tools"

STATE_DIR_ENV = "AGC_AGENT_STATE_DIR"
DATA_DIR_ENV = "AGC_AGENT_DATA_DIR"
DEFAULT_BASE_URL = "http://127.0.0.1:8080/v1"
DEFAULT_MODEL = "default"
## The names `AGC_AGENT_API` takes: OpenAI chat completions, and the OpenAI Responses format.
APIS = ["openai", "openai_responses"]

def from_env(read: Fn[String, Result[String]]) -> Result[Server.Options]
  base_url = set(read, "AGC_AGENT_BASE_URL").unwrap_or(DEFAULT_BASE_URL)
  api_key = set(read, "AGC_AGENT_API_KEY").unwrap_or("")
  provider = try provider(set(read, "AGC_AGENT_API").unwrap_or(APIS[0]), base_url, api_key)
  ok(
    Server.Options(
      state_dir: try state_dir(read),
      data_dir: try data_dir(read),
      provider: provider,
      model: set(read, "AGC_AGENT_MODEL").unwrap_or(DEFAULT_MODEL),
      env: read,
      rules: Tools.Rules(allow: [], deny: []),
      context_window: try context_window(read),
      compact_model: set(read, "AGC_AGENT_COMPACT_MODEL").unwrap_or(""),
      props_url: props_url(base_url),
      api_key: api_key,
    ),
  )
end

## The provider of the model API `api` at `base_url`.
def provider(
  api: String,
  base_url: String,
  api_key: String,
  options: LLM.Options = LLM.Options(),
) -> Result[LLM.Provider]
  case api
    "openai" -> ok(LLM.openai_chat(base_url, api_key, options))
    "openai_responses" -> ok(LLM.openai_responses(base_url, api_key, options))
    _ -> error("AGC_AGENT_API must be one of #{APIS.join(", ")}, not #{api.inspect}")
  end
end

def state_dir(read: Fn[String, Result[String]]) -> Result[String]
  folder(read, STATE_DIR_ENV, "XDG_STATE_HOME", "state")
end

def data_dir(read: Fn[String, Result[String]]) -> Result[String] = folder(read, DATA_DIR_ENV, "XDG_DATA_HOME", "share")

private

def folder(read: Fn[String, Result[String]], own: String, xdg: String, under_local: String) -> Result[String]
  for dir in option_list(set(read, own))
    return ok(dir)
  end

  for base in option_list(set(read, xdg))
    return Path.join([base, "agc-agent"])
  end

  Path.join([try read.call("HOME"), ".local", under_local, "agc-agent"])
end

def set(read: Fn[String, Result[String]], name: String) -> Optional[String]
  case read.call(name)
    ok(value) if value != "" -> some(value)
    _ -> none
  end
end

def context_window(read: Fn[String, Result[String]]) -> Result[Optional[Int]]
  for text in option_list(set(read, "AGC_AGENT_CONTEXT_WINDOW"))
    case text.to_i
      ok(tokens) if tokens > 0 -> return ok(some(tokens))
      _ -> return error("AGC_AGENT_CONTEXT_WINDOW must be a number of tokens over 0, not #{text.inspect}")
    end
  end

  ok(none)
end

# llama-server serves `/props` next to `/v1`.
def props_url(base_url: String) -> String
  base = base_url
  if base.end_with?("/")
    base = base.slice(0, base.length - 1)
  end

  return "" if not base.end_with?("/v1")

  "#{base.slice(0, base.length - 3)}/props"
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
