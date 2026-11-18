## The server log: `std/logger` writes it, each line as `TIME LEVEL MESSAGE key=value` with the UTC time
## (`2026-11-18T17:30:02.345Z INFO ...`), to stdout (info) and stderr (warning, error), which `finn` sends to
## `server.log` of the state folder. `install` makes the handler that does it and also keeps the last warnings of the
## process in memory, since the first of them come before the server listens, a warning with a text already kept
## counted once, with its times as `(×N)`; `tail` reads the end of the file.

import Logger from "std/logger"

FILE = "server.log"
## The line the server writes when it listens.
STARTED = "Finn Agent core listening on"
## The warnings that `warnings` gives, the last ones.
SHOWN = 3
## The distinct warnings kept to count the ones that come again.
KEPT = 64
## The end of the file that `tail` reads: a longer file is read through, and only this much of it is kept.
TAIL_BYTES = 262_144
READ_BYTES = 65_536
NEWLINE = 10

# The distinct warnings by their number modulo `KEPT`, how many there were, and how many times each text came.
RECENT: ATS[Int, Kept] = ATS.new()
COUNTS: ATS[String, Int] = ATS.new()
TIMES: ATS[String, Int] = ATS.new()
WARNINGS = "warnings"

# A warning as its first time, level and plain message, with the message that counts it.
struct Kept
  message: String
  line: String
end

## The warnings (and errors) the process logged: the last `SHOWN` distinct ones, oldest first, and how many distinct.
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

## The warnings the process has logged since `install`: each text once, with `(×N)` after it when it came N times.
def warnings() -> Warnings
  count = COUNTS.get(WARNINGS).unwrap_or(0)
  first = [count - SHOWN + 1, 1].max.unwrap!
  lines: List[String] = []
  for number in first...(count + 1)
    case RECENT.get(number % KEPT)
      ok(kept) -> lines = lines.push(counted(kept, TIMES.get(kept.message).unwrap_or(1)))
      error(_) -> nil
    end
  end

  Warnings(lines: lines, count: count)
end

## The last `count` lines of the log in `dir`; the file is read through in pieces, keeping its last `TAIL_BYTES`.
def tail(dir: String, count: Int) -> Result[Tail]
  path = "#{dir}/#{FILE}"
  return ok(Tail(lines: [])) if not File.stat(path).ok?

  file = try File.open(path)
  kept = "".bytes
  # The start of `kept` is in the middle of a line.
  partial = false
  while true
    piece = File.read_bytes(file, READ_BYTES)
    break if not piece.ok? or piece.unwrap!.size == 0

    kept = Bytes.concat([kept, piece.unwrap!])
    if kept.size > TAIL_BYTES
      partial = kept.at(kept.size - TAIL_BYTES - 1) != NEWLINE
      kept = Bytes.slice(kept, kept.size - TAIL_BYTES, TAIL_BYTES)
    end
  end

  _ = File.close(file)
  lines = kept.scrub.split("\n").select { |line| line != "" }
  if partial and not lines.empty?
    lines = lines.drop(1)
  end

  ok(Tail(lines: lines.drop([lines.size - count, 0].max.unwrap!)))
end

private

def record(event: Logger.Event) -> Void
  line = Logger.format_text(event)
  case event.level
    Logger.Level.Warning -> warned(event, "WARNING", line)
    Logger.Level.Error -> warned(event, "ERROR", line)
    _ -> puts(line)
  end
end

# The warning is kept as its time, level and plain message: the log line quotes a message with a quote or an `=`.
# A text
# that is kept already only counts. The slot of the number is written right after the count moves, so a read between
# the two may see the line it replaces.
def warned(event: Logger.Event, level: String, line: String) -> Void
  IO.warn(line)
  if TIMES.add(event.message, 1) == 1
    number = COUNTS.add(WARNINGS, 1)
    slot = number % KEPT
    case RECENT.get(slot)
      ok(old) -> TIMES.delete(old.message)
      error(_) -> nil
    end

    RECENT.put(
      slot,
      Kept(message: event.message, line: "#{Logger.time_text(event.time_ms)} #{level} #{event.message}"),
    )
  end
end

def counted(kept: Kept, times: Int) -> String
  return kept.line if times <= 1

  "#{kept.line} (×#{times})"
end
