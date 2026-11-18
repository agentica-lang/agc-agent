## The server log: `std/logger` writes it, each line as `TIME LEVEL MESSAGE key=value` with the UTC time
## (`2026-11-18T17:30:02.345Z INFO ...`), to stdout (info) and stderr (warning, error), which `finn` sends to `server.log` of the state folder. `install`
## makes the handler that does it and also keeps the last warnings of the process in memory, since the first of them
## come before the server listens; `tail` reads the end of the file.

import Logger from "std/logger"

FILE = "server.log"
## The line the server writes when it listens.
STARTED = "Finn Agent core listening on"
## The warnings that `warnings` gives, the last ones.
SHOWN = 3
## The end of the file that `tail` reads: a longer file is read through, and only this much of it is kept.
TAIL_BYTES = 262_144
READ_BYTES = 65_536

# The last warnings by their number modulo `SHOWN`, and how many there were.
RECENT: ATS[Int, String] = ATS.new()
COUNTS: ATS[String, Int] = ATS.new()
WARNINGS = "warnings"

## The warnings (and errors) the process logged: the last `SHOWN`, oldest first, and how many in all.
struct Warnings
  lines: List[String]
  count: Int
end

## The lines of the log file: the last of them.
struct Tail
  lines: List[String]
end

## Writes every line as `Logger.format_text` makes it, and keeps the warnings. The default handler `console` writes the
## same lines to stderr, so it goes.
def install() -> Void
  _ = Logger.detach("console")
  _ = Logger.attach("server", Logger.Level.Info, &record)
end

## The warnings the process has logged since `install`.
def warnings() -> Warnings
  count = COUNTS.get(WARNINGS).unwrap_or(0)
  first = [count - SHOWN + 1, 1].max.unwrap!
  lines: List[String] = []
  for number in first...(count + 1)
    lines = lines.push(RECENT.get(number % SHOWN).unwrap_or(""))
  end

  Warnings(lines: lines, count: count)
end

## The last `count` lines of the log in `dir`; the file is read through in pieces, keeping its last `TAIL_BYTES`.
def tail(dir: String, count: Int) -> Result[Tail]
  path = "#{dir}/#{FILE}"
  return ok(Tail(lines: [])) if not File.stat(path).ok?

  file = try File.open(path)
  kept = "".bytes
  cut = false
  while true
    piece = File.read_bytes(file, READ_BYTES)
    break if not piece.ok? or piece.unwrap!.size == 0

    kept = Bytes.concat([kept, piece.unwrap!])
    if kept.size > TAIL_BYTES
      kept = Bytes.slice(kept, kept.size - TAIL_BYTES, TAIL_BYTES)
      cut = true
    end
  end

  _ = File.close(file)
  lines = kept.scrub.split("\n").select { |line| line != "" }
  if cut and not lines.empty?
    lines = lines.drop(1)
  end

  ok(Tail(lines: lines.drop([lines.size - count, 0].max.unwrap!)))
end

private

def record(event: Logger.Event) -> Void
  line = Logger.format_text(event)
  case event.level
    Logger.Level.Warning, Logger.Level.Error ->
      IO.warn(line)
      number = COUNTS.add(WARNINGS, 1)
      RECENT.put(number % SHOWN, line)
    _ -> puts(line)
  end
end
