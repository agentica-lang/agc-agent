## The answers to approval requests, and `--yolo` allowing the calls of this client's turns.

import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import Approvals from "approvals"
import Yolo from "pkg/client/yolo"
import State from "state"

## The answer is sent by a command, so the keys go on; its reply comes back as a message.
def answer(app: State.Model, decision: Protocol.Decision) -> State.Model
  sent(app, app.approvals.pending[0].approval_id, decision).with(approvals: Approvals.sending(app.approvals))
end

def allowed(app: State.Model, request: Protocol.ApprovalRequested) -> State.Model
  allowing = sent(app, request.approval_id, Protocol.Decision.Allow).with(yolo: Yolo.allowing(app.yolo, request))
  State.noted(allowing, "--yolo allows #{request.tool}: #{request.preview}")
end

## An allow of `--yolo` that was not sent leaves its approval to the panel.
def unyolo(app: State.Model, approval_id: String, result: Result[Void]) -> State.Model
  back = Yolo.unsent(app.yolo, approval_id, result)
  rest = app.with(yolo: Yolo.resolved(app.yolo, approval_id))
  case back
    some(request) -> rest.with(approvals: Approvals.requested(rest.approvals, request, app.now))
    none -> rest
  end
end

def resolved(app: State.Model, approval_id: String) -> State.Model
  app.with(
    approvals: Approvals.resolved(app.approvals, approval_id, app.now),
    yolo: Yolo.resolved(app.yolo, approval_id),
  )
end

private

def sent(app: State.Model, approval_id: String, decision: Protocol.Decision) -> State.Model
  backend = app.backend
  id = app.id
  State.effect(
    app,
    TUI.Cmd.Run(-> { State.Msg.Answered(approval_id, backend.approve.call(id, approval_id, decision)) }),
  )
end
