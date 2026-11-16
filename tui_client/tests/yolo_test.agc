import Protocol from "pkg/protocol/protocol"
import Yolo from "../src/yolo"

def test_only_the_approvals_of_an_own_turn_are_allowed() -> Result[Void]
  mine = Yolo.started(Yolo.Yolo(on: true), "turn-2")
  try Test.eq(Yolo.allows?(Yolo.running(mine, some("turn-2"))), true)
  try Test.eq(Yolo.allows?(Yolo.running(mine, some("turn-3"))), false)
  try Test.eq(Yolo.allows?(mine), false)
  Test.eq(Yolo.allows?(Yolo.running(mine.with(on: false), some("turn-2"))), false)
end

def test_an_allow_not_sent_is_asked_unless_it_was_resolved_first() -> Result[Void]
  request = Protocol.ApprovalRequested(approval_id: "a1", call_id: "c1", tool: "write_file", preview: "p", detail: "")
  sending = Yolo.allowing(Yolo.Yolo(on: true), request)
  lost: Result[Void] = error("connection refused", kind: "client.http")
  try Test.eq(Yolo.unsent(sending, "a1", lost), some(request))
  try Test.eq(Yolo.unsent(sending, "a1", ok()), none)
  try Test.eq(Yolo.unsent(sending, "a1", error("done", kind: Protocol.KIND_APPROVAL_RESOLVED)), none)
  Test.eq(Yolo.unsent(Yolo.resolved(sending, "a1"), "a1", lost), none)
end
