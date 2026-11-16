## The commands a user types in either client, as `/name argument`. Pure.

import Protocol from "pkg/protocol/protocol"

KIND_COMMAND = "client.command"
HELP = [
  "/new                       a new session in this folder",
  "/resume                    list the sessions; /resume N or /resume ID switches to one",
  "/model [NAME]              the session's model, or change it from the next turn on",
  "/thinking [low|medium|high]  the thinking level, or change it",
  "/compact                   fold the history into a summary now",
  "/stop                      stop the running turn",
  "/help                      this list",
  "/quit                      leave",
]

enum Command
  New
  ## Lists the sessions without an argument; switches to the one of that number or id.
  Resume(Optional[String])
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

## The command of a line, none when the line is not one (it does not start with `/`); an error for an unknown command
## or a bad argument.
def parse_command(line: String) -> Optional[Result[Command]]
  text = line.strip
  return none if not text.start_with?("/")

  words = text.split(" ").select { |word| word != "" }
  name = words[0]
  argument = words.drop(1).join(" ")
  some(command(name, argument))
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

private

def command(name: String, argument: String) -> Result[Command]
  case name
    "/new" -> bare(Command.New, name, argument)
    "/resume" -> ok(Command.Resume(given(argument)))
    "/model" -> ok(Command.Model(given(argument)))
    "/thinking" -> thinking(argument)
    "/compact" -> bare(Command.Compact, name, argument)
    "/stop" -> bare(Command.Stop, name, argument)
    "/cost" -> bare(Command.Cost, name, argument)
    "/help" -> bare(Command.Help, name, argument)
    "/quit" -> bare(Command.Quit, name, argument)
    _ -> error("unknown command #{name}: /help lists them", kind: KIND_COMMAND)
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

def thinking(argument: String) -> Result[Command]
  return ok(Command.Thinking(none)) if argument == ""
  if not Protocol.EFFORTS.include?(argument)
    return error("the thinking level is one of #{Protocol.EFFORTS.join(", ")}", kind: KIND_COMMAND)
  end

  ok(Command.Thinking(some(argument)))
end
