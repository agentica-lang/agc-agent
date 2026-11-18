## The server log: each line starts with its UTC time (`2026-11-18T17:30:02.345Z`) and its level, as `std/logger` writes
## them. The server writes it to stderr and stdout, which `finn` sends to `server.log` of the state folder.

import UTC from "std/utc"

FILE = "server.log"
## The line a server writes when it starts: the warnings after the last one are the ones of this server.
STARTED = "Finn Agent core listening on"
WARNING = "WARNING"
INFO = "INFO"
## The warnings that `tail` gives, the last ones.
SHOWN_WARNINGS = 3

## What `tail` read: the last lines of the log, the warnings since the server started (the last `SHOWN_WARNINGS`) and
## how many there were.
struct Tail
  lines: List[String]
  warnings: List[String]
  warning_count: Int
end

def line(level: String, text: String) -> String = "#{UTC.iso8601(Time.now_ms, 3)} #{level} #{text}"

def info(text: String) -> Void
  puts(line(INFO, text))
end

def warn(text: String) -> Void
  IO.warn(line(WARNING, text))
end

## The last `count` lines of the log in `dir`, one pass over the file (rotation keeps it small).
def tail(dir: String, count: Int) -> Result[Tail]
  path = "#{dir}/#{FILE}"
  return ok(Tail(lines: [], warnings: [], warning_count: 0)) if not File.stat(path).ok?

  lines: List[String] = []
  warnings: List[String] = []
  total = 0
  for text in (try File.read_text(path)).split("\n")
    next if text == ""

    lines = lines.push(text)
    if lines.size > count * 2 + 1
      lines = last(lines, count)
    end

    if text.include?(" #{INFO} #{STARTED}")
      warnings = []
      total = 0
    end

    if text.include?(" #{WARNING} ")
      warnings = last(warnings.push(text), SHOWN_WARNINGS)
      total = total + 1
    end
  end

  ok(Tail(lines: last(lines, count), warnings: warnings, warning_count: total))
end

def last(list: List[String], count: Int) -> List[String] = list.drop([list.size - count, 0].max.unwrap!)
