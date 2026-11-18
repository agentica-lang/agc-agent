# The server log: each line has its UTC time and level, and `GET /v1/logs` gives its end and the warnings since the
# server started, read through the server.

import Protocol from "pkg/protocol/protocol"
import Log from "../src/log"
import H from "support/harness"

def test_a_log_line_starts_with_its_utc_time_and_level() -> Result[Void]
  stamp = Log.line(Log.WARNING, "a skill is shadowed")
  try Test.assert(stamp.end_with?("Z WARNING a skill is shadowed"), stamp)
  try Test.eq(["#{stamp.length}", stamp.slice(10, 1), stamp.slice(23, 1)], ["52", "T", "Z"])
  Test.eq(Log.line(Log.INFO, "x").slice(24, 6), " INFO ")
end

def test_the_server_gives_the_end_of_its_log_and_the_warnings_since_it_started() -> Result[Void]
  H.using(H.Setup(replies: [])) do |h|
    lines = [
      "2026-11-18T10:00:00.000Z WARNING of an older server",
      "2026-11-18T10:00:01.000Z INFO #{Log.STARTED} 127.0.0.1:1",
      "2026-11-18T10:00:02.000Z WARNING one",
      "2026-11-18T10:00:03.000Z WARNING two",
      "2026-11-18T10:00:04.000Z INFO a line",
      "2026-11-18T10:00:05.000Z WARNING three",
      "2026-11-18T10:00:06.000Z WARNING four",
    ]

    try File.write_text("#{h.state_dir}/server.log", lines.join("\n") + "\n")
    shown = try Protocol.decode_server_log((try H.get(h, "#{Protocol.LOGS_PATH}?lines=2")).text)
    try Test.eq(shown.lines, lines.drop(5))
    try Test.eq(shown.warnings, [lines[3], lines[5], lines[6]])
    try Test.eq(shown.warning_count, 4)
    all = try Protocol.decode_server_log((try H.get(h, Protocol.LOGS_PATH)).text)
    try Test.eq(all.lines.size, 7)
    nothing = try Protocol.decode_server_log((try H.get(h, "#{Protocol.LOGS_PATH}?lines=0")).text)
    Test.eq(nothing.lines, [])
  end
end
