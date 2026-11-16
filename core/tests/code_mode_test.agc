# Code mode: the model's script calls the tools through the fake Monty worker, which replays frames recorded from the
# real one (record again with `MONTY_RECORD=path/to/monty make unit`). A call from the script is a tool call of its
# own: the same events, the same approval, and a denial raises PermissionError in the script.

import Protocol from "pkg/protocol/protocol"
import H from "support/harness"

def test_a_script_calls_tools_and_a_denied_call_raises_in_it() -> Result[Void]
  H.using(H.Setup(replies: ["run_script.sse", "text.sse"], monty: "script.json")) do |h|
    try File.write_text("#{h.work}/hello.txt", "hi\n")
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Read hello.txt with a script.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    bash = try H.approval(a)
    try Test.eq([bash.tool, bash.preview], ["bash", "rm hello.txt"])
    _ = try H.approve(h, id, bash.approval_id, Protocol.Decision.Deny)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(H.stop_reason(a), "end_turn")
    try Test.eq(File.read_text("#{h.work}/hello.txt"), ok("hi\n"))
    started = a.seen.map { |s| started_name(s.event) }.select { |name| name != "" }
    try Test.eq(started, ["run_script", "read_file", "bash"])
    second = try H.request_messages(h, 2)
    try Test.eq(JSON.get(second.last, "role"), ok(JSON.from("tool")))
    Test.eq(JSON.get(second.last, "content"), ok(JSON.from("denied: the user denied this call\nhi\n3")))
  end
end

def started_name(event: Protocol.Event) -> String
  case event
    Protocol.Event.ToolStarted(tool) -> tool.name
    _ -> ""
  end
end
