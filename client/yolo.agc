## What `--yolo` allows without asking: the approvals of the turns this client started. A turn another client started,
## or one that was running when this client attached, is asked as usual; so is the rest of an own turn once another
## client queued a message into it (a `message_queued` with a message id this client was not given), or once events of
## it may have been missed (a resync that does not replay the turn). Pure.

import Protocol from "pkg/protocol/protocol"

struct Yolo
  on: Bool = false
  ## The turns this client started.
  own: List[String] = []
  ## The turn running now.
  turn: Optional[String] = none
  ## The allowed approvals whose answer is on its way.
  sending: List[Protocol.ApprovalRequested] = []
  ## The ids of the messages this client queued into its own turns.
  sent: List[String] = []
  ## Own turns that another client steered.
  steered: List[String] = []
end

## The `202` of a message this client sent: it started the turn, or it was queued into the running one.
def accepted(yolo: Yolo, reply: Protocol.MessageAccepted) -> Yolo
  case reply.message_id
    some(id) -> yolo.with(sent: yolo.sent.push(id))
    none -> yolo.with(own: yolo.own.push(reply.turn_id))
  end
end

def running(yolo: Yolo, turn: Optional[String]) -> Yolo = yolo.with(turn: turn)

## The session as the client reads it again: the running turn, whose events since it started come again when
## `replayed`; when they do not, a message queued into it may be missed, so an own turn is steered.
def attached(yolo: Yolo, turn: Optional[String], replayed: Bool) -> Yolo
  case turn
    some(id) if not replayed and yolo.own.include?(id) -> yolo.with(turn: turn, steered: yolo.steered.push(id))
    _ -> yolo.with(turn: turn)
  end
end

## A `message_queued`: one this client did not send ends `--yolo` for the rest of that turn.
def steered(yolo: Yolo, event: Protocol.MessageQueued) -> Yolo
  return yolo if not yolo.own.include?(event.turn_id) or yolo.sent.include?(event.message_id)

  yolo.with(steered: yolo.steered.push(event.turn_id))
end

## An approval asked now is of the running turn.
def allows?(yolo: Yolo) -> Bool
  case yolo.turn
    some(turn) -> yolo.on and yolo.own.include?(turn) and not yolo.steered.include?(turn)
    none -> false
  end
end

def allowing(yolo: Yolo, request: Protocol.ApprovalRequested) -> Yolo = yolo.with(sending: yolo.sending.push(request))

def resolved(yolo: Yolo, approval_id: String) -> Yolo
  yolo.with(sending: yolo.sending.select { |r| r.approval_id != approval_id })
end

## The request to ask in the panel after the reply to its allow: one whose allow was not sent and that is still
## pending (no `ApprovalResolved` came for it).
def unsent(yolo: Yolo, approval_id: String, result: Result[Void]) -> Optional[Protocol.ApprovalRequested]
  mine = yolo.sending.select { |r| r.approval_id == approval_id }
  return none if mine.empty?

  case result
    ok(_) -> none
    error(e) if e.kind == Protocol.KIND_APPROVAL_RESOLVED or e.kind == Protocol.KIND_APPROVAL_NOT_FOUND -> none
    error(_) -> some(mine[0])
  end
end
