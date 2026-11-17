## For the bash peer test: reads a JSON list of lines from the file named first, and prints a JSON list with, for each,
## `{"error": Bool, "unclear": Bool, "commands": [[[kind, text], ...], ...]}`, or null when it is not read.

import Bash from "../../bash"

def main() -> Void
  lines: List[String] = JSON.decode(File.read_text(System.args()[0]).unwrap!, List[String]).unwrap!
  puts(JSON.encode(lines.map { |line| read(line) }))
end

private

def read(line: String) -> Optional[JSON.Value]
  case Bash.parse(line)
    ok(parsed) ->
      commands = parsed.commands.map { |c| c.words.map { |w| [w.kind, w.text] } }
      fields = {
        "error": JSON.from(parsed.error),
        "unclear": JSON.from(parsed.unclear),
        "commands": JSON.from(commands),
      }

      some(JSON.object(fields))
    error(_) -> none
  end
end
