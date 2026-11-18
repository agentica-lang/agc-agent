import LLM from "pkg/llm/llm"

VERSION = "0.0.1"

USAGE = <<~TEXT
  usage: finn serve [--api NAME] [--model NAME] [--base-url URL] [--approvals]

  Each flag overrides its variable: FINN_API, FINN_MODEL, FINN_BASE_URL, FINN_APPROVALS=1.

  The Finn Agent core. `serve` runs the server on 127.0.0.1 and writes server.json in the state folder: FINN_STATE_DIR,
  else $XDG_STATE_HOME/finn, else ~/.local/state/finn. The sessions are kept in sessions/ of FINN_DATA_DIR, else
  $XDG_DATA_HOME/finn, else ~/.local/share/finn: one file each, in plain text (tool output and file contents included),
  until it is deleted (finn --delete ID). A file keeps every event but the text deltas and grows with the session; the
  server reads a session's file when the session is first used. The model API is FINN_BASE_URL (a local llama-server by
  default) in the format FINN_API names: openai (chat completions, the default) or openai_responses; with FINN_API_KEY
  and FINN_MODEL. FINN_API=anthropic is the Anthropic Messages API (ANTHROPIC_BASE_URL, else Anthropic's) with
  ANTHROPIC_API_KEY, else ANTHROPIC_AUTH_TOKEN, else the token of `ant auth login` (fetched again after a 401), never
  logged; its default model is claude-opus-5-5, and it caches the prompt. A new session may name another model and API
  (finn --model, --api), kept in its file. FINN_MAX_TOKENS limits a reply, thinking included (default: the model's
  output limit in the models.dev catalog, else none on the OpenAI APIs and 64000 on Anthropic).
  Past 80 % of the model's window (FINN_CONTEXT_WINDOW, else llama-server's
  /props for a local server, else the catalog, else /props, else GET /models), the history after the first task becomes
  a summary by FINN_COMPACT_MODEL (a model of FINN_API; else the session's model), whose tokens are not in `usage` and
  are not costed; the last round of the running turn is kept whole. On Anthropic the history folds only between turns:
  past the limit inside a turn, the rest of the turn sends no thinking blocks. Code mode (run_script; off with
  --no-codemode or FINN_CODE_MODE=0, and where no Monty worker exists for the machine): the model calls the tools from a Python script in pydantic's Monty sandbox, each call approved as a direct one; the
  worker is FINN_MONTY (a Monty 1.6.0 binary you trust: its hash is not checked), else the pinned Monty 1.6.0 fetched
  from PyPI (sha256 checked) on first use into $XDG_CACHE_HOME/finn, else ~/.cache/finn (a folder open to others is
  refused). FINN_MCP_CONFIG names a JSON file of MCP servers ({"mcpServers": {NAME: {"command", "args", "env"} or
  {"url", "headers"}}}): their tools are mcp__NAME__TOOL and ask before each call. A server on stdio gets the short
  environment of bash plus its "env", which is passed on as given (put the keys it needs there); a slow server's tools
  come once it lists them, from the next turn. Skills (SKILL.md folders under .finn/skills, .agents/skills and
  .claude/skills) come from the home folder, and from the session folder only when it is under a folder of
  FINN_TRUSTED_DIRS (separated by :); the model loads one with activate_skill, the user with /name in a message. The
  catalog of models.dev (FINN_MODELS_URL, "off" for none), loaded at the start and kept a day in models.json of the
  state folder, gives each usage event its cost in USD (FINN_MODELS_PROVIDER names the provider there; by default
  anthropic for that API, else openai). Approvals: off by default, so the model runs any command and edits any file
  that no deny rule refuses, without asking (use a sandbox or a container). FINN_APPROVALS=1 (finn serve --approvals),
  or "approvals": true in the user's config file, turns them on; FINN_APPROVALS=0 keeps them off over the file, and a
  project file cannot change them. The deny rules always count; the asks, the answers and accept_edits only with the
  approvals on. The rules {"permission": ["ask bash(*)", "allow bash(git *)", "deny read_file(*.pem)"]} come from
  FINN_CONFIG, else $XDG_CONFIG_HOME/finn/config.json, else ~/.config/finn/config.json, then from .finn/config.json of
  the session folder (all of them under a folder of FINN_TRUSTED_DIRS, else only its deny rules); the last rule that
  matches wins, and reads of .env files ask by default. An answer may allow the same call (allow_session), what
  "always" allows (the first words of each bash command, allow_prefix) or the whole tool (allow_tool) for the session,
  until the server restarts; PATCH {"accept_edits": true} runs the edits of files without asking. None of them reaches
  into .git/ or past a deny rule. A bash rule matches each command of the line (best effort, not a sandbox), and a file
  rule covers only the file tools. Providers: local (FINN_BASE_URL with FINN_API_KEY) and anthropic always; openai,
  fireworks, openrouter, groq, deepseek and opencode-go when OPENAI_API_KEY, FIREWORKS_API_KEY, OPENROUTER_API_KEY,
  GROQ_API_KEY, DEEPSEEK_API_KEY or OPENCODE_API_KEY is set; and those of "providers" in the config file
  ([{"name", "api", "base_url", "key_env", "models"}], api openai or openai_responses; one with key_env only when that
  variable is set). FINN_PROVIDER is the provider of a session that names none (finn --provider names one); PATCH
  {"provider", "model"} moves a session to another. Logins: finn login (or /login in finn) checks a key with GET /models at the provider and stores it in
  $XDG_CONFIG_HOME/finn/auth.json (else ~/.config/finn/auth.json), mode 0600; a file others may read, or of another
  user, is not used. The key variable wins over a stored key. finn logout [NAME] removes stored keys.
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
