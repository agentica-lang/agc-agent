import LLM from "pkg/llm/llm"

VERSION = "0.0.1"

USAGE = <<~TEXT
  usage: finn serve [--api NAME] [--model NAME] [--base-url URL]

  Each flag overrides its variable: FINN_API, FINN_MODEL, FINN_BASE_URL.

  The Finn Agent core. `serve` runs the server on 127.0.0.1 and writes server.json in the state folder:
  FINN_STATE_DIR, else $XDG_STATE_HOME/finn, else ~/.local/state/finn. The sessions are kept in
  sessions/ of FINN_DATA_DIR, else $XDG_DATA_HOME/finn, else ~/.local/share/finn: one file each, in
  plain text (tool output and file contents included), until it is deleted (finn --delete ID). A file keeps every event
  but the text deltas and grows with the session; the server reads a session's file when the session is first used. The
  model API is FINN_BASE_URL (a local llama-server by default) in the format FINN_API names: openai (chat
  completions, the default) or openai_responses; with FINN_API_KEY and FINN_MODEL. A new session may name
  another model and API (finn --model, --api), kept in its file. Past 80 % of the model's window
  (FINN_CONTEXT_WINDOW, else llama-server's /props for a local server, else the catalog, else /props, else GET
  /models), the history after the first task becomes a summary by FINN_COMPACT_MODEL (else the session's model), whose
  tokens are not in `usage` and are not costed; the last round of the running turn is kept whole. FINN_CODE_MODE=1 adds
  run_script: the model calls the tools from a Python script in pydantic's Monty sandbox, each call approved as a
  direct one; the worker is FINN_MONTY (a Monty 1.6.0 binary you trust: its hash is not checked), else the pinned Monty
  1.6.0 fetched from PyPI (sha256 checked) on first use into $XDG_CACHE_HOME/finn, else ~/.cache/finn (a folder open to
  others is refused). FINN_MCP_CONFIG names a JSON file of MCP servers on stdio ({"mcpServers": {NAME: {"command",
  "args", "env"}}}): their tools are mcp__NAME__TOOL and ask before each call. A server gets the short environment of
  bash plus its "env", which is passed on as given (put the keys it needs there); a slow server's tools come once it
  lists them. The catalog of models.dev (FINN_MODELS_URL, "off" for none), loaded at the start and kept a day in
  models.json of the state folder, gives each usage event its cost in USD (FINN_MODELS_PROVIDER names the provider
  there; by default anthropic for that API, else openai).
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
    Command.Version -> "Finn Agent core #{VERSION} (llm #{LLM.VERSION})"
    Command.Help, Command.Serve -> USAGE.strip
  end
end
