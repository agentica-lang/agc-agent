import LLM from "pkg/llm/llm"

VERSION = "0.0.1"

USAGE = <<~TEXT
  usage: agc serve [--api NAME] [--model NAME] [--base-url URL]

  Each flag overrides its variable: AGC_AGENT_API, AGC_AGENT_MODEL, AGC_AGENT_BASE_URL.

  The agc-agent core. `serve` runs the server on 127.0.0.1 and writes server.json in the state folder:
  AGC_AGENT_STATE_DIR, else $XDG_STATE_HOME/agc-agent, else ~/.local/state/agc-agent. The sessions are kept in
  sessions/ of AGC_AGENT_DATA_DIR, else $XDG_DATA_HOME/agc-agent, else ~/.local/share/agc-agent: one file each, in
  plain text (tool output and file contents included), until it is deleted (agc --delete ID). A file keeps every event
  but the text deltas and grows with the session; the server reads a session's file when the session is first used. The
  model API is AGC_AGENT_BASE_URL (a local llama-server by default) in the format AGC_AGENT_API names: openai (chat
  completions, the default) or openai_responses; with AGC_AGENT_API_KEY and AGC_AGENT_MODEL. A new session may name
  another model and API (agc --model, --api), kept in its file. Past 80 % of the model's window
  (AGC_AGENT_CONTEXT_WINDOW, else llama-server's /props, else GET /models), the history after the first task becomes a
  summary by AGC_AGENT_COMPACT_MODEL (else the session's model), whose tokens are not in `usage`; the last round of the
  running turn is kept whole.
TEXT

enum Command
  Serve
  Version
  Help
end

def parse(args: List[String]) -> Result[Command]
  text = args.join(" ")
  case text
    "", "--help", "-h" -> ok(Command.Help)
    "--version" -> ok(Command.Version)
    "serve" -> ok(Command.Serve)
    _ -> error("unknown arguments: #{text}")
  end
end

def output(command: Command) -> String
  case command
    Command.Version -> "agc-agent core #{VERSION} (llm #{LLM.VERSION})"
    Command.Help, Command.Serve -> USAGE.strip
  end
end
