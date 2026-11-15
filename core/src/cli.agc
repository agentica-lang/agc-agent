import LLM from "pkg/llm/llm"

VERSION = "0.0.1"

USAGE = <<~TEXT
  usage: agentica core/main.agc [--version | --help]

  The agc-agent core: it will serve the agent loop to its clients. Nothing works yet.
TEXT

enum Command
  Version
  Help
end

def parse(args: List[String]) -> Result[Command]
  text = args.join(" ")
  case text
    "", "--help", "-h" -> ok(Command.Help)
    "--version" -> ok(Command.Version)
    _ -> error("unknown arguments: #{text}")
  end
end

def output(command: Command) -> String
  case command
    Command.Version -> "agc-agent core #{VERSION} (llm #{LLM.VERSION})"
    Command.Help -> USAGE.strip
  end
end
