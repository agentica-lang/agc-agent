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

# A message another client queued into an own turn ends `--yolo` for the rest of it; one this client queued does not.
def test_a_turn_another_client_steers_is_asked() -> Result[Void]
  mine = Yolo.running(Yolo.started(Yolo.Yolo(on: true), "turn-2"), some("turn-2"))
  own = Yolo.steered(
    Yolo.queued(mine, "turn-2", "and docs"),
    Protocol.MessageQueued(turn_id: "turn-2", text: "and docs"),
  )

  try Test.eq([Yolo.allows?(own), own.sent.empty?], [true, true])
  foreign = Yolo.steered(mine, Protocol.MessageQueued(turn_id: "turn-2", text: "rm it"))
  try Test.eq(Yolo.allows?(foreign), false)
  other = Yolo.steered(mine, Protocol.MessageQueued(turn_id: "turn-9", text: "x"))
  Test.eq(Yolo.allows?(other), true)
end

# A resync that skips the replay gives no turn_finished or turn_started: the snapshot says which turn runs.
def test_a_snapshot_replaces_the_running_turn() -> Result[Void]
  mine = Yolo.running(Yolo.started(Yolo.Yolo(on: true), "turn-2"), some("turn-2"))
  idle = snapshot(none)
  try Test.eq(Yolo.allows?(Yolo.attached(mine, idle)), false)
  try Test.eq(Yolo.allows?(Yolo.attached(mine, snapshot(some("turn-3")))), false)
  Test.eq(Yolo.allows?(Yolo.attached(Yolo.attached(mine, idle), snapshot(some("turn-2")))), true)
end

private

def snapshot(turn: Optional[String]) -> Protocol.Session
  Protocol.Session(
    id: "s1",
    cwd: "/w",
    model: "m",
    last_event_id: 9,
    turn_id: turn,
    turn_from_event_id: none,
    pending_approvals: [],
    history: [],
  )
end
