## The commands a user types in either client, as `/name argument`. Pure.

import Protocol from "pkg/protocol/protocol"

KIND_COMMAND = "client.command"
DEFAULT_PROFILE = "build"
## The lines `/logs` shows without a number.
DEFAULT_LOG_LINES = 50
BUILT_IN = "built-in"
## The commands of both clients, in the order `/help` lists them: the one table that the parser, the help and the
## suggestions of the full screen read.
COMMANDS = [
  Usage(name: "/new", about: "a new session in this folder"),
  Usage(name: "/resume", args: "[N|ID]", about: "list the sessions; /resume N or /resume ID switches to one"),
  Usage(
    name: "/tree",
    args: "[N|N+]",
    about: "the session's messages; N goes back before message N, N+ on after its answer",
  ),
  Usage(name: "/fork", args: "[N|N+]", about: "a new session from before message N (or after its answer)"),
  Usage(name: "/clone", about: "a new session with this one's history"),
  Usage(
    name: "/export",
    args: "[--force] [PATH]",
    about: "write the session's branch to a Markdown file (default: ID.md here)",
    more: "PATH is the rest of the line; the file (0600) holds what the session holds; --force replaces a file",
  ),
  Usage(
    name: "/model",
    args: "[PROVIDER/]NAME",
    about: "change the model (and provider) from the next turn on; alone: pick or show it",
    more: "a model the session's provider lists stays on it: openrouter/anthropic/x forces one",
  ),
  Usage(name: "/thinking", args: "[low|medium|high|default]", about: "the thinking level, or change it"),
  Usage(
    name: "/confine",
    args: "[on|off]",
    about: "keep the file tools in the session folder (on) or let them reach any path (off); alone: show it",
    more: "the rules of approval apply either way; it lasts until the server restarts",
  ),
  Usage(
    name: "/profile",
    args: "[NAME]",
    about: "change the tools the model sees (and its model) from the next turn on; alone: list the profiles",
  ),
  Usage(name: "/compact", about: "fold the history into a summary now"),
  Usage(
    name: "/login",
    args: "[PROVIDER]",
    about: "set up a provider with its key, or local with its base URL (the full screen); alone: pick one",
  ),
  Usage(name: "/logout", args: "[PROVIDER]", about: "remove a stored key or base URL; alone: every one"),
  Usage(name: "/reload", about: "read the config, skills, extensions and AGENTS.md again, for the next turns"),
  Usage(name: "/logs", args: "[N]", about: "the last N lines (default 50) of the server log, which has its warnings"),
  Usage(
    name: "/mouse",
    about: "turn the mouse of the full screen off or on; off, the terminal selects text",
    more: "on, a drag copies the text; Shift+drag (Option+drag in iTerm2) is the terminal's own selection",
  ),
  Usage(name: "/stop", about: "stop the running turn"),
  Usage(name: "/cost", about: "what the session cost", listed: false),
  Usage(name: "/help", about: "this list"),
  Usage(name: "/quit", about: "leave"),
]
## The column where the help puts what a command does.
ABOUT_COLUMN = 27

## A command: its name, the arguments the help shows, what it does (and a second line); `listed` false keeps it out
## of the help and the suggestions.
struct Usage
  name: String
  args: String = ""
  about: String
  more: String = ""
  listed: Bool = true
end

enum Command
  New
  ## Lists the sessions without an argument; switches to the one of that number or id.
  Resume(Optional[String])
  ## Shows the tree without an argument; goes back to the message it names (see `tree_entry`).
  Tree(Optional[String])
  ## Shows the tree without an argument; a new session from the message it names.
  Fork(Optional[String])
  Clone
  ## Writes the session's branch to the file, `ID.md` here when none; the flag replaces a file that exists.
  Export(Optional[String], Bool)
  ## Shows the model without an argument.
  Model(Optional[String])
  ## Shows the thinking level without an argument.
  Thinking(Optional[String])
  ## Shows whether the file tools stay in the session folder without an argument.
  Confine(Optional[Bool])
  ## Lists the profiles without an argument.
  Profile(Optional[String])
  Compact
  ## The last lines of the server log.
  Logs(Int)
  ## Reads the config, the skills, the extensions and the project instructions again.
  Reload
  ## Turns the mouse reporting of the full screen off or on.
  Mouse
  Stop
  ## The cost of the session, once the model catalog gives prices (#88).
  Cost
  ## Picks a provider without an argument; then asks for its key.
  Login(Optional[String])
  ## Every stored key without an argument.
  Logout(Optional[String])
  Help
  Quit
end

## The command of a line, none when the line is not one of the client's: it goes to the server as text, so a `/name`
## the server knows (a skill) still works. An error for a bad argument.
def parse_command(line: String) -> Optional[Result[Command]]
  text = line.strip
  return none if not text.start_with?("/")

  words = text.split(" ").select { |word| word != "" }
  name = words[0]
  return none if (not COMMANDS.any? { |usage| usage.name == name })

  some(command(name, text.slice(name.length, text.length - name.length).strip))
end

## The command of a line `!CMD` (its output goes to the model) or `!!CMD` (it does not); none for another line or
## for `!` alone.
def parse_shell(line: String) -> Optional[Protocol.RunShell]
  text = line.strip
  return none if not text.start_with?("!")

  rest = text.slice(1, text.length - 1)
  context = not rest.start_with?("!")
  if not context
    rest = rest.slice(1, rest.length - 1)
  end

  return none if rest.strip.empty?

  some(Protocol.RunShell(command: rest.strip, context: context))
end

## The lines of `/help`, with the session's slash commands (`custom`) after the clients' own.
def help(custom: List[Usage] = []) -> List[String]
  rows = (listed() + custom).flat_map do |usage|
    head = "#{usage.name} #{usage.args}".strip
    line = "#{head}#{" " * [ABOUT_COLUMN - head.length, 2].max.unwrap!}#{usage.about}"
    [line] + [usage.more].select { |m| m != "" }.map { |m| "#{" " * ABOUT_COLUMN}#{m}" }
  end

  (
    rows +
    [
      "!CMD                       run CMD in the session folder; the model gets its output with the next message",
      "!!CMD                      run CMD without giving its output to the model",
      "any other /name goes to the agent as a message",
    ]
  )
end

## The session's slash commands as the help and the suggestions show them; one that does not load says so.
def custom(list: Protocol.CommandList) -> List[Usage]
  list.commands.map do |c|
    about = printable(c.description)
    if c.source.empty?
      about = "does not load: #{printable(c.warnings.join("; "))}"
    end

    Usage(name: "/#{printable(c.name)}", args: "[TEXT]", about: about)
  end
end

## The note lines of a client that starts on a server that has load warnings (the last of them, and where the rest is);
## none when it has none.
def warning_notes(log: Protocol.ServerLog) -> List[String]
  return [] if log.warning_count == 0

  log.warnings + ["#{counted(log.warning_count)} when the server started: /logs shows them"]
end

## The rows of the banner of a client that starts on a server that has load warnings: a head that says how many and
## how to see them and close the banner (a click only with the mouse on), then the last of them; none when it has none.
def warning_banner(log: Protocol.ServerLog, mouse: Bool = true) -> List[String]
  return [] if log.warning_count == 0

  closes = "Esc closes this"
  if mouse
    closes = "click here or Esc closes this"
  end

  head = "#{counted(log.warning_count)} when the server started (/logs shows all): #{closes}"
  [head] + log.warnings.map { |line| printable(line) }
end

## What a reload did, in one line, and a line for each warning: `skills: 2 added, 1 removed; config reloaded; 1 MCP
## server started again; 3 sessions use it from their next turn`.
def reload_report(done: Protocol.Reloaded) -> List[String]
  skills = "skills: unchanged"
  if not done.skills_added.empty? or not done.skills_removed.empty?
    parts: List[String] = []
    if not done.skills_added.empty?
      parts = parts.push("#{done.skills_added.size} added (#{done.skills_added.map { |n| printable(n) }.join(", ")})")
    end

    if not done.skills_removed.empty?
      parts = parts.push(
        "#{done.skills_removed.size} removed (#{done.skills_removed.map { |n| printable(n) }.join(", ")})",
      )
    end

    skills = "skills: #{parts.join(", ")}"
  end

  config = "config #{done.config.split(":")[0]}"
  line = ([skills, config] + done.extensions.map { |text| printable(text) }).join("; ")
  if done.sessions > 0
    running = "#{done.sessions} running sessions"
    if done.sessions == 1
      running = "1 running session"
    end

    line = "#{line}; the next turn of #{running} uses it"
  end

  [line] + done.warnings.map { |warning| "warning: #{printable(warning)}" }
end

## What a client prints on the console after its screen is closed, when the server has warnings: the last of them, the
## count and the command for all.
def warning_report(log: Protocol.ServerLog) -> Optional[String]
  return none if log.warning_count == 0

  head = "#{counted(log.warning_count)} in the server log, the last #{log.warnings.size}:"
  some(([head] + log.warnings.map { |line| "  #{line}" } + ["finn server logs shows all of them"]).join("\n"))
end

def counted(count: Int) -> String
  return "1 warning" if count == 1

  "#{count} warnings"
end

## The commands the help and the suggestions show.
def listed() -> List[Usage] = COMMANDS.select { |usage| usage.listed }

## What a logout of `name` (none: all) says it removed: `local` keeps a base URL, the others a key.
def logged_out(name: Optional[String]) -> String
  return "every stored key and base URL is removed" if name.none?
  return "the stored base URL of local is removed" if name == some("local")

  "the key of #{name.unwrap_or("")} is removed"
end

## What a client says of a turn that `done` ended, past its stop reason: why a `max_tokens` stop happened; "" for
## another stop.
def stop_note(done: Protocol.TurnFinished) -> String
  return "" if done.stop_reason != Protocol.StopReason.MaxTokens

  case done.max_tokens
    some(limit) -> "the reply hit the model's output limit (#{limit} tokens)"
    none -> "the reply hit the model's output limit"
  end
end

## What a client says when the first turn after `/model NAME` fails: the server takes any name.
def model_warning(model: String) -> String
  "the call failed after /model #{model}: check the name (/model NAME changes it)"
end

## The warning a client adds to an error of a turn, if any: on `local`, a call that reached no server says the local
## server does not answer; else, after `/model NAME`, `model_warning`.
def turn_warning(kind: String, provider: String, new_model: Optional[String]) -> Optional[String]
  if kind == KIND_NETWORK and provider == LOCAL
    return some("the local server does not answer: /model PROVIDER/NAME picks another provider, /login sets one up")
  end

  new_model.map { |model| model_warning(model) }
end

## The change `/model TEXT` asks for: the model alone when `current`, the session's provider, lists `TEXT`; that
## provider and the rest as its model when a provider of `list` has the name before the first `/` (a model name may hold
## a `/`). A name that only other providers list, whole or in part, is an error that names them: a provider never
## changes unless asked for. Any other text is the model alone.
def model_change(list: Protocol.ProviderList, current: String, text: String) -> Result[Protocol.UpdateSession]
  own = list.providers.select { |p| p.name == current }
  return ok(Protocol.UpdateSession(model: some(text))) if (own.any? { |p| p.models.include?(text) })

  case text.index_of("/")
    some(at) ->
      provider = text.slice(0, at)
      model = text.slice(at + 1, text.length - at - 1)
      if (not model.empty? and list.providers.any? { |p| p.name == provider })
        return ok(Protocol.UpdateSession(provider: some(provider), model: some(model)))
      end

    none -> nil
  end

  others = list.providers.select { |p| p.name != current }
  found = others.flat_map { |p| p.models.select { |m| m == text }.map { |m| "#{p.name}/#{m}" } }
  if found.empty?
    wanted = text.downcase
    found = others.flat_map { |p| p.models.select { |m| m.downcase.include?(wanted) }.map { |m| "#{p.name}/#{m}" } }
  end

  return ok(Protocol.UpdateSession(model: some(text))) if found.empty?

  error(not_here(text, current, found), kind: KIND_COMMAND)
end

## The sessions a client offers to resume: those with something in them (the server marks the others `empty`), but
## the `current` one.
def resumable(list: Protocol.SessionList, current: String = "") -> List[Protocol.SessionSummary]
  list.sessions.select { |s| not s.empty and s.id != current }
end

## The sessions to resume, one numbered line each, for `/resume N`.
def listing(list: Protocol.SessionList, current: String = "") -> List[String]
  sessions = resumable(list, current)
  numbers = (1..sessions.size).to_a
  numbers.map do |n|
    s = sessions[n - 1]
    "#{n}. #{s.id}  #{s.model}  #{s.cwd}"
  end
end

## The id `/resume` chose: the number of a line of `listing`, or an id of the list (an empty session's too).
def pick(list: Protocol.SessionList, choice: String, current: String = "") -> Result[String]
  return ok(choice) if (list.sessions.any? { |s| s.id == choice })

  ids = resumable(list, current).map { |s| s.id }
  case choice.to_i
    ok(n) if n >= 1 and n <= ids.size -> ok(ids[n - 1])
    _ -> error("no session #{choice}: /resume lists them", kind: KIND_COMMAND)
  end
end

## The text on one line, each control character (bidi ones too) a space: what a client echoes of what another typed.
def printable(text: String) -> String = text.split("").map { |c| shown(c) }.join("")

## A control character (C0, C1) or a bidi control, which could reorder what a screen shows.
def control?(code: Int) -> Bool = code < 0x20 or (code >= 0x7f and code < 0xa0) or Protocol.BIDI.include?(code)

## What a client says of a session's profile: its name and where it comes from, unless it is the built-in `build`,
## then each warning of the server about it, printable.
def profile_lines(profile: Optional[Protocol.Profile]) -> List[String]
  case profile
    some(p) ->
      lines = p.warnings.map { |w| "warning: #{printable(w)}" }
      return lines if p.name == DEFAULT_PROFILE and p.source == BUILT_IN

      source = p.source
      if source.empty?
        source = "does not load"
      end

      ["profile #{printable(p.name)} (#{source})"] + lines
    none -> []
  end
end

## The profiles for `/profile`, one line each: `*` before the session's, its name, where it comes from and what it is
## for, or why it does not load; printable.
def profile_listing(list: Protocol.ProfileList, current: String) -> List[String]
  list.profiles.map do |p|
    mark = "  "
    if p.name == current
      mark = "* "
    end

    line = "#{mark}#{p.name} (#{p.source})"
    if not p.description.empty?
      line = "#{line} #{p.description}"
    end

    if p.source.empty?
      line = "#{mark}#{p.name}: does not load: #{p.warnings.join("; ")}"
    end

    printable(line)
  end
end

## The model's todo list, one line an item: `[x]` completed, `[>]` in progress, `[ ]` pending, then its printable text.
def todo_lines(todos: List[Protocol.Todo]) -> List[String]
  todos.map do |todo|
    box = "[ ]"
    case todo.status
      "completed" -> box = "[x]"
      "in_progress" -> box = "[>]"
      _ -> nil
    end

    "#{box} #{printable(todo.content)}"
  end
end

private

SUGGESTED = 3
KIND_NETWORK = "llm.network"
LOCAL = "local"

def not_here(text: String, current: String, found: List[String]) -> String
  head = "#{printable(text)} is not a model of #{printable(current)}"
  keep = "(/model #{printable(current)}/#{printable(text)} keeps #{printable(current)})"
  return "#{head}: did you mean /model #{printable(found[0])}? #{keep}" if found.size == 1

  shown = found.take(SUGGESTED).map { |pair| "/model #{printable(pair)}" }.join(", ")
  more = ""
  if found.size > SUGGESTED
    more = " and #{found.size - SUGGESTED} more"
  end

  "#{head}; other providers have #{shown}#{more} #{keep}"
end

def shown(c: String) -> String
  return " " if control?(c.code)

  c
end

def command(name: String, argument: String) -> Result[Command]
  case name
    "/new" -> bare(Command.New, name, argument)
    "/resume" -> ok(Command.Resume(given(argument)))
    "/tree" -> ok(Command.Tree(given(argument)))
    "/fork" -> ok(Command.Fork(given(argument)))
    "/clone" -> bare(Command.Clone, name, argument)
    "/export" -> exporting(argument)
    "/model" -> model(argument)
    "/thinking" -> thinking(argument)
    "/confine" -> confine(argument)
    "/profile" -> ok(Command.Profile(given(argument)))
    "/compact" -> bare(Command.Compact, name, argument)
    "/logs" -> logs(argument)
    "/reload" -> bare(Command.Reload, name, argument)
    "/mouse" -> bare(Command.Mouse, name, argument)
    "/stop" -> bare(Command.Stop, name, argument)
    "/cost" -> bare(Command.Cost, name, argument)
    "/login" -> ok(Command.Login(try provider(argument)))
    "/logout" -> ok(Command.Logout(try provider(argument)))
    "/help" -> bare(Command.Help, name, argument)
    # Only `/quit` is left of COMMANDS.
    _ -> bare(Command.Quit, name, argument)
  end
end

def logs(argument: String) -> Result[Command]
  return ok(Command.Logs(DEFAULT_LOG_LINES)) if argument == ""

  case argument.to_i
    ok(count) if count > 0 -> ok(Command.Logs(count))
    _ -> error("/logs takes a number of lines, as in /logs 20", kind: KIND_COMMAND)
  end
end

# The path is the rest of the line, spaces kept; `--force` is a flag only as the first word.
def exporting(argument: String) -> Result[Command]
  return ok(Command.Export(given(argument), false)) if argument != "--force" and not argument.start_with?("--force ")

  ok(Command.Export(given(argument.slice(7, argument.length - 7).strip), true))
end

def bare(command: Command, name: String, argument: String) -> Result[Command]
  return error("#{name} takes no argument", kind: KIND_COMMAND) if argument != ""

  ok(command)
end

def given(argument: String) -> Optional[String]
  return none if argument == ""

  some(argument)
end

# One word: a key typed after the name would be shown and kept as the line.
def provider(argument: String) -> Result[Optional[String]]
  return error("give the provider alone: the key is asked for next", kind: KIND_COMMAND) if argument.include?(" ")

  ok(given(argument))
end

def model(argument: String) -> Result[Command]
  return error("a model name has no spaces", kind: KIND_COMMAND) if argument.include?(" ")

  ok(Command.Model(given(argument)))
end

def confine(argument: String) -> Result[Command]
  case argument
    "" -> ok(Command.Confine(none))
    "on" -> ok(Command.Confine(some(true)))
    "off" -> ok(Command.Confine(some(false)))
    _ -> error("/confine takes on or off", kind: KIND_COMMAND)
  end
end

def thinking(argument: String) -> Result[Command]
  return ok(Command.Thinking(none)) if argument == ""
  levels = Protocol.EFFORTS + [Protocol.EFFORT_DEFAULT]
  if not levels.include?(argument)
    return error("the thinking level is one of #{levels.join(", ")}", kind: KIND_COMMAND)
  end

  ok(Command.Thinking(some(argument)))
end
