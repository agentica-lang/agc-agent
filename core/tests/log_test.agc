# The server log: each line has its UTC time and level, and `GET /v1/logs` gives its end and the warnings since the
# server started, read through the server.

import Protocol from "pkg/protocol/protocol"
import Logger from "std/logger"
import Log from "../src/log"
import H from "support/harness"

# The warnings are those of the process, kept in memory: the ones logged before the server listens count, and only
# the last 3 come back with the count of all.
def test_the_server_gives_the_end_of_its_log_and_the_warnings_of_the_process() -> Result[Void]
  Log.install()
  H.using(H.Setup(replies: [])) do |h|
    before = Log.warnings().count
    for name in ["one", "two", "three", "four"]
      Logger.warning("bad #{name}")
    end

    Logger.warning("cannot read \"x\" a=b")

    Logger.info("#{Log.STARTED} 127.0.0.1:1")
    bad = try Bytes.from_list([255, 254, 10])
    written = Bytes.concat(["2026-11-18T10:00:00.000Z INFO first\n2026-11-18T10:00:01.000Z INFO second\n".bytes, bad])
    file = try File.open("#{h.state_dir}/server.log", "create_private")
    try File.write_bytes(file, written)
    try File.close(file)
    shown = try Protocol.decode_server_log((try H.get(h, "#{Protocol.LOGS_PATH}?lines=2")).text)
    try Test.eq(shown.lines.size, 2)
    try Test.eq(shown.warnings.size, 3)
    try Test.assert(
      shown.warnings[2].end_with?(" WARNING cannot read \"x\" a=b"),
      "the plain message: #{shown.warnings}",
    )

    try Test.assert(shown.warnings[1].end_with?(" WARNING bad four"), "#{shown.warnings}")
    try Test.assert(shown.warnings[0].end_with?(" WARNING bad three"), "#{shown.warnings}")
    try Test.eq(shown.warning_count - before, 5)
    try Test.eq(shown.lines[0], "2026-11-18T10:00:01.000Z INFO second")
    try Test.assert(shown.lines[1].include?("�"), "a byte that is not UTF-8 is replaced")
    nothing = try Protocol.decode_server_log((try H.get(h, "#{Protocol.LOGS_PATH}?lines=0")).text)
    Test.eq(nothing.lines, [])
  end
end

# A `lines` that is no number or is out of range is a 400; a server with no log file gives no lines.
def test_the_logs_route_refuses_a_bad_count_and_has_no_file_without_a_log() -> Result[Void]
  H.using(H.Setup(replies: [])) do |h|
    for bad in ["abc", "-1", "99999999999999999999", "1001"]
      answer = try H.get(h, "#{Protocol.LOGS_PATH}?lines=#{bad}")
      try Test.eq(
        [bad, answer.status.to_s, (try Protocol.decode_failure(answer.text)).kind],
        [bad, "400", Protocol.KIND_INVALID],
      )
    end

    absent = try Protocol.decode_server_log((try H.get(h, Protocol.LOGS_PATH)).text)
    Test.eq(absent.lines, [])
  end
end

# A file over the tail is read through and its first line is dropped only when the cut fell inside it.
def test_a_cut_tail_drops_the_first_line_only_when_the_cut_fell_inside_it() -> Result[Void]
  H.using(H.Setup(replies: [])) do |h|
    for width in [16, 17]
      body = (10000...30000).to_a.map { |n| "#{n}#{"x" * (width - 6)}" }.join("\n") + "\n"
      try File.write_text("#{h.state_dir}/server.log", body)
      tail = try Log.tail(h.state_dir, 100000)
      try Test.assert(tail.lines[0].start_with?("1"), "#{width}: a whole line first: #{tail.lines[0]}")
      try Test.eq(tail.lines[0].length, width - 1)
      try Test.eq(tail.lines.last.slice(0, 5), "29999")
    end

    ok()
  end
end
