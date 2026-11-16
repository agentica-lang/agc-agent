## For the bash peer test: reads a JSON list of commands from the file named first, and prints a JSON list with, for
## each, null when it does not parse, else the words of each simple command as `[text, glob]` pairs.

import Shell from "../../shell"

def main() -> Void
  texts: List[String] = JSON.decode(File.read_text(System.args()[0]).unwrap!, List[String]).unwrap!
  out = texts.map { |text| words(text) }
  puts(JSON.encode(out))
end

private

def words(text: String) -> Optional[List[List[JSON.Value]]]
  case Shell.parse(text)
    ok(script) ->
      some(
        script.pipelines.flat_map { |p|
          p.commands.map { |c| c.words.map { |w| JSON.from([JSON.from(w.text), JSON.from(w.glob)]) } }
        },
      )
    error(_) -> none
  end
end
