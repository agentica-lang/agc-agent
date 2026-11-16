## The commands a user types in either client, as `/name argument`. Pure.

import Protocol from "pkg/protocol/protocol"

KIND_COMMAND = "client.command"
NAMES = [
  "/new", "/resume", "/tree", "/fork", "/clone", "/model", "/thinking", "/compact", "/stop", "/cost", "/help", "/quit",
]
HELP = [
  "/new                       a new session in this folder",
  "/resume                    list the sessions; /resume N or /resume ID switches to one",
  "/tree [N|N+]               the session's messages; N goes back before message N, N+ on after its answer",
  "/fork [N|N+]               a new session from before message N (or after its answer)",
  "/clone                     a new session with this one's history",
  "/model [NAME]              the session's model, or change it from the next turn on",
  "/thinking [low|medium|high|default]  the thinking level, or change it",
  "/compact                   fold the history into a summary now",
  "/stop                      stop the running turn",
  "/help                      this list",
  "/quit                      leave",
  "any other /name goes to the agent as a message",
]

enum Command
  New
  ## Lists the sessions without an argument; switches to the one of that number or id.
  Resume(Optional[String])
  ## Shows the tree without an argument; goes back to the message it names (see `tree_entry`).
  Tree(Optional[String])
  ## Shows the tree without an argument; a new session from the message it names.
  Fork(Optional[String])
  Clone
  ## Shows the model without an argument.
  Model(Optional[String])
  ## Shows the thinking level without an argument.
  Thinking(Optional[String])
  Compact
  Stop
  ## The cost of the session, once the model catalog gives prices (#88).
  Cost
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
  return none if not NAMES.include?(name)

  argument = words.drop(1).join(" ")
  some(command(name, argument))
end

## What a client says when the first turn after `/model NAME` fails: the server takes any name.
def model_warning(model: String) -> String
  "the call failed after /model #{model}: check the name (/model NAME changes it)"
end

## The sessions of the server, one numbered line each, for `/resume N`.
def listing(list: Protocol.SessionList) -> List[String]
  numbers = (1..list.sessions.size).to_a
  numbers.map do |n|
    s = list.sessions[n - 1]
    "#{n}. #{s.id}  #{s.model}  #{s.cwd}"
  end
end

## The id `/resume` chose: the number of a line of `listing`, or an id of the list.
def pick(list: Protocol.SessionList, choice: String) -> Result[String]
  ids = list.sessions.map { |s| s.id }
  return ok(choice) if ids.include?(choice)

  case choice.to_i
    ok(n) if n >= 1 and n <= ids.size -> ok(ids[n - 1])
    _ -> error("no session #{choice}: /resume lists them", kind: KIND_COMMAND)
  end
end

## The text on one line, each control character a space: what a client echoes of what another typed.
def printable(text: String) -> String = text.split("").map { |c| shown(c) }.join("")

private

def shown(c: String) -> String
  code = c.code
  return " " if code < 0x20 or (code >= 0x7f and code < 0xa0)

  c
end

def command(name: String, argument: String) -> Result[Command]
  case name
    "/new" -> bare(Command.New, name, argument)
    "/resume" -> ok(Command.Resume(given(argument)))
    "/tree" -> ok(Command.Tree(given(argument)))
    "/fork" -> ok(Command.Fork(given(argument)))
    "/clone" -> bare(Command.Clone, name, argument)
    "/model" -> model(argument)
    "/thinking" -> thinking(argument)
    "/compact" -> bare(Command.Compact, name, argument)
    "/stop" -> bare(Command.Stop, name, argument)
    "/cost" -> bare(Command.Cost, name, argument)
    "/help" -> bare(Command.Help, name, argument)
    # Only `/quit` is left of NAMES.
    _ -> bare(Command.Quit, name, argument)
  end
end

def bare(command: Command, name: String, argument: String) -> Result[Command]
  return error("#{name} takes no argument", kind: KIND_COMMAND) if argument != ""

  ok(command)
end

def given(argument: String) -> Optional[String]
  return none if argument == ""

  some(argument)
end

def model(argument: String) -> Result[Command]
  return error("a model name has no spaces", kind: KIND_COMMAND) if argument.include?(" ")

  ok(Command.Model(given(argument)))
end

def thinking(argument: String) -> Result[Command]
  return ok(Command.Thinking(none)) if argument == ""
  levels = Protocol.EFFORTS + [Protocol.EFFORT_DEFAULT]
  if not levels.include?(argument)
    return error("the thinking level is one of #{levels.join(", ")}", kind: KIND_COMMAND)
  end

  ok(Command.Thinking(some(argument)))
end
