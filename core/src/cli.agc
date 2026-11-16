import LLM from "pkg/llm/llm"

VERSION = "0.0.1"

USAGE = <<~TEXT
  usage: finn serve [--api NAME] [--model NAME] [--base-url URL]

  Each flag overrides its variable: FINN_API, FINN_MODEL, FINN_BASE_URL.

  The Finn Agent core. `serve` runs the server on 127.0.0.1 and writes server.json in the state folder: FINN_STATE_DIR,
  else $XDG_STATE_HOME/finn, else ~/.local/state/finn. The sessions are kept in sessions/ of FINN_DATA_DIR, else
  $XDG_DATA_HOME/finn, else ~/.local/share/finn: one file each, in plain text (tool output and file contents included),
  until it is deleted (finn --delete ID). A file keeps every event but the text deltas and grows with the session; the
  server reads a session's file when the session is first used. The model API is FINN_BASE_URL (a local llama-server by
  default) in the format FINN_API names: openai (chat completions, the default) or openai_responses; with FINN_API_KEY
  and FINN_MODEL. FINN_API=anthropic is the Anthropic Messages API (ANTHROPIC_BASE_URL, else Anthropic's) with
  ANTHROPIC_API_KEY, else ANTHROPIC_AUTH_TOKEN, else the token of `ant auth login` (fetched again after a 401), never
  logged; its default model is claude-opus-5-5, and it caches the prompt. A new session may name another model and API
  (finn --model, --api), kept in its file. Past 80 % of the model's window (FINN_CONTEXT_WINDOW, else llama-server's
  /props, else GET /models), the history after the first task becomes a summary by FINN_COMPACT_MODEL (a model of
  FINN_API; else the session's model), whose tokens are not in `usage`; the last round of the running turn is kept
  whole. On Anthropic the history folds only between turns: past the limit inside a turn, the rest of the turn sends no
  thinking blocks. FINN_CODE_MODE=1 adds run_script: the model calls the tools from a Python script in pydantic's Monty
  sandbox, each call approved as a direct one; the worker is FINN_MONTY (a Monty 1.6.0 binary you trust: its hash is
  not checked), else the pinned Monty 1.6.0 fetched from PyPI (sha256 checked) on first use into $XDG_CACHE_HOME/finn,
  else ~/.cache/finn (a folder open to others is refused). FINN_MCP_CONFIG names a JSON file of MCP servers on stdio
  ({"mcpServers": {NAME: {"command", "args", "env"}}}): their tools are mcp__NAME__TOOL and ask before each call. A
  server gets the short environment of bash plus its "env", which is passed on as given (put the keys it needs there).
  Skills (SKILL.md folders under .finn/skills, .agents/skills and .claude/skills) come from the home folder, and from
  the session folder only when it is under a folder of FINN_TRUSTED_DIRS (separated by :); the model loads one with
  activate_skill, the user with /name in a message. Approvals: the rules {"allow": [...], "deny": [...]} come from
  FINN_CONFIG, else $XDG_CONFIG_HOME/finn/config.json, else ~/.config/finn/config.json, and from .finn/config.json of
  the session folder (its deny rules always; its allow rules under a folder of FINN_TRUSTED_DIRS). A bash command that
  only reads inside the folder runs without asking. An answer may allow the same call (allow_session), the bash
  commands with the same first words (allow_prefix) or the whole tool (allow_tool) for the session; PATCH
  {"accept_edits": true} runs the edits of files without asking. None of them reaches into .git/.
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
