## What `--yolo` allows without asking: the approvals of the turns this client started. A turn another client started,
## or one that was running when this client attached, is asked as usual; so is the rest of an own turn once another
## client queued a message into it (a `message_queued` whose text this client did not send). Pure.

import Protocol from "pkg/protocol/protocol"

struct Yolo
  on: Bool = false
  ## The turns this client started.
  own: List[String] = []
  ## The turn running now.
  turn: Optional[String] = none
  ## The allowed approvals whose answer is on its way.
  sending: List[Protocol.ApprovalRequested] = []
  ## The texts this client queued into its own turns, until their `message_queued` comes.
  sent: List[String] = []
  ## Own turns that another client steered.
  steered: List[String] = []
end

def started(yolo: Yolo, turn_id: String) -> Yolo = yolo.with(own: yolo.own.push(turn_id))

def running(yolo: Yolo, turn: Optional[String]) -> Yolo = yolo.with(turn: turn)

## A message this client queued into the turn `turn_id`.
def queued(yolo: Yolo, turn_id: String, text: String) -> Yolo
  return yolo if not yolo.own.include?(turn_id)

  yolo.with(sent: yolo.sent.push(text))
end

## A `message_queued`: one this client did not send ends `--yolo` for the rest of that turn.
def steered(yolo: Yolo, event: Protocol.MessageQueued) -> Yolo
  return yolo if not yolo.own.include?(event.turn_id)

  case (yolo.sent.find_index { |text| text == event.text })
    some(i) -> yolo.with(sent: yolo.sent.take(i) + yolo.sent.drop(i + 1))
    none -> yolo.with(steered: yolo.steered.push(event.turn_id))
  end
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
