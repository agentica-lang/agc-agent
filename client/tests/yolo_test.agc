import Protocol from "pkg/protocol/protocol"
import Yolo from "../yolo"

def test_only_the_approvals_of_an_own_turn_are_allowed() -> Result[Void]
  mine = Yolo.accepted(Yolo.Yolo(on: true), Protocol.MessageAccepted(turn_id: "turn-2"))
  try Test.eq(Yolo.allows?(Yolo.running(mine, some("turn-2"))), true)
  try Test.eq(Yolo.allows?(Yolo.running(mine, some("turn-3"))), false)
  try Test.eq(Yolo.allows?(mine), false)
  try Test.eq(Yolo.allows?(Yolo.running(mine.with(on: false), some("turn-2"))), false)
  queued = Yolo.accepted(
    Yolo.Yolo(on: true),
    Protocol.MessageAccepted(turn_id: "turn-3", message_id: some("turn-3.1")),
  )

  Test.eq(Yolo.allows?(Yolo.running(queued, some("turn-3"))), false)
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

# A message another client queued into an own turn ends `--yolo` for the rest of it, even with the text of one this
# client queued; one this client queued does not, also when a replay brings it again.
def test_a_turn_another_client_steers_is_asked() -> Result[Void]
  started = Yolo.accepted(Yolo.Yolo(on: true), Protocol.MessageAccepted(turn_id: "turn-2"))
  mine = Yolo.running(started, some("turn-2"))
  sent = Yolo.accepted(mine, Protocol.MessageAccepted(turn_id: "turn-2", message_id: some("turn-2.1")))
  event = Protocol.MessageQueued(turn_id: "turn-2", text: "and docs", message_id: some("turn-2.1"))
  try Test.eq(Yolo.allows?(Yolo.steered(Yolo.steered(sent, event), event)), true)
  foreign = Yolo.steered(sent, event.with(message_id: some("turn-2.2")))
  try Test.eq(Yolo.allows?(foreign), false)
  other = Yolo.steered(mine, event.with(turn_id: "turn-9", message_id: some("turn-9.1")))
  Test.eq(Yolo.allows?(other), true)
end

# A resync that does not replay the running own turn may have missed a message queued into it: the turn is asked.
def test_an_own_turn_read_again_without_its_events_is_asked() -> Result[Void]
  mine = Yolo.accepted(Yolo.Yolo(on: true), Protocol.MessageAccepted(turn_id: "turn-2"))
  try Test.eq(Yolo.allows?(Yolo.attached(mine, some("turn-2"), true)), true)
  try Test.eq(Yolo.allows?(Yolo.attached(mine, some("turn-2"), false)), false)
  Test.eq(Yolo.allows?(Yolo.attached(mine, some("turn-3"), false)), false)
end

# A resync that skips the replay gives no turn_finished or turn_started: the snapshot says which turn runs.
def test_a_snapshot_replaces_the_running_turn() -> Result[Void]
  mine = Yolo.running(Yolo.accepted(Yolo.Yolo(on: true), Protocol.MessageAccepted(turn_id: "turn-2")), some("turn-2"))
  idle = Yolo.attached(mine, none, false)
  try Test.eq(Yolo.allows?(idle), false)
  try Test.eq(Yolo.allows?(Yolo.attached(mine, some("turn-3"), true)), false)
  Test.eq(Yolo.allows?(Yolo.attached(idle, some("turn-2"), true)), true)
end
