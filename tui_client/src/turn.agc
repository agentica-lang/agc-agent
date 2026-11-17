## The messages sent one at a time, the follow-ups kept for the end of a turn, `!` commands and the stop.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import Input from "input"
import Transcript from "transcript"
import Yolo from "pkg/client/yolo"
import State from "state"

## Esc puts the follow-ups back in the prompt, before what it holds.
def put_back(app: State.Model) -> State.Model
  text = (app.follow_ups + [app.prompt].select { |t| t.strip != "" }).join("\n")
  State.noted(app.with(prompt: text, cursor: text.length, follow_ups: []), "follow-ups back in the prompt")
end

## The follow-ups go as one message once the turn ended by itself; a stopped turn puts them back in the prompt.
def after_turn(app: State.Model, reason: Protocol.StopReason) -> State.Model
  return app if app.follow_ups.empty?
  return put_back(app) if reason == Protocol.StopReason.Cancelled

  text = app.follow_ups.join("\n\n")
  queued = app.with(follow_ups: [], outbox: app.outbox.push(text))
  return queued if not app.outbox.empty?

  sending(queued, text)
end

def expanded(app: State.Model, text: String) -> String = Input.expanded(text, app.pastes)

def remembered(history: List[String], text: String) -> List[String]
  return history if not history.empty? and history.last == text

  history.push(text)
end

def shell_send(app: State.Model, request: Protocol.RunShell) -> State.Model
  backend = app.backend
  id = app.id
  State.effect(app, TUI.Cmd.Run(-> { State.Msg.ShellSent(request.command, backend.shell.call(id, request)) }))
end

## Its `shell_started` and `shell_finished` draw the command; a refusal goes back to an empty prompt, and one that may
## have run (a timeout) stays only in the note, so it does not run twice.
def shell_reply(app: State.Model, command: String, result: Result[Protocol.ShellAccepted]) -> State.Model
  case result
    ok(_) -> app
    error(e) if e.kind == Client.KIND_TIMEOUT ->
      State.noted(app, "the command may have run (#{e.message}): #{Client.printable(command)}")
    error(e) ->
      failed = State.noted(app, "the command did not run: #{e.message}: #{Client.printable(command)}")
      return failed if app.prompt != ""

      text = "!#{command}"
      failed.with(prompt: text, cursor: text.length)
  end
end

def sending(app: State.Model, text: String) -> State.Model
  backend = app.backend
  id = app.id
  opened = app.opened
  State.effect(app, TUI.Cmd.Run(-> { State.Msg.Sent(opened, text, backend.send_message.call(id, text)) }))
end

## The next message of the outbox goes once the reply to the one before came, so the server gets them in order.
def next_send(app: State.Model) -> State.Model
  return app.with(stop_wanted: false) if app.outbox.empty?

  sending(app, app.outbox[0])
end

## A message sent while a turn runs is queued; its `message_queued` event shows it. A message that was not sent goes
## back to an empty prompt; one that may have been sent (a timeout) stays only in the note, so it is not sent twice.
def sent_reply(app: State.Model, text: String, result: Result[Protocol.MessageAccepted]) -> State.Model
  case result
    ok(accepted) if accepted.message_id.some? ->
      queued = app.with(yolo: Yolo.accepted(app.yolo, accepted))
      return queued if not app.stop_wanted

      # The message went into a turn that runs (another client's): that is the turn Esc asked to stop.
      stop(queued.with(turn: true, stop_wanted: false), some(accepted.turn_id))
    ok(accepted) ->
      entries = Transcript.add(app.entries, Transcript.Kind.User, text)
      # Until its `turn_started`, Esc stops this turn by the id of the reply.
      yolo = Yolo.running(Yolo.accepted(app.yolo, accepted), some(accepted.turn_id))
      started = app.with(entries: entries, turn: true, stopping: false, yolo: yolo)
      return started if not app.stop_wanted

      stop(started.with(stop_wanted: false), some(accepted.turn_id))
    # The text stays in the note: put back in the prompt, it would take the keys typed after it.
    error(e) if e.kind == Client.KIND_TIMEOUT ->
      State.noted(app, "error: the message may not have been sent (#{e.message}): #{Client.printable(text)}")
    error(e) ->
      failed = State.noted(app, "error: the message was not sent: #{e.message}: #{Client.printable(text)}")
      return failed if app.prompt != ""

      failed.with(prompt: text, cursor: text.length)
  end
end

def stop_reply(app: State.Model, what: String, result: Result[Bool]) -> State.Model
  case result
    ok(true) -> app
    ok(_) -> State.noted(app.with(stopping: false), "the #{what} had already ended")
    error(e) -> State.noted(app.with(stopping: false), "error: the stop was not sent: #{e.message}")
  end
end

## Stops what runs: the turn by its id (`turn_id`, else the one running), so a stop cannot reach the turn after it.
def stop(app: State.Model, turn_id: Optional[String] = none) -> State.Model
  if not app.turn and not app.outbox.empty?
    return State.noted(app.with(stop_wanted: true), "the turn stops once it starts")
  end

  return app if not State.busy?(app) or app.stopping

  backend = app.backend
  id = app.id
  wanted = turn_id
  if wanted.none? and app.turn
    wanted = app.yolo.turn
  end

  what = "turn"
  if not app.turn
    what = "command"
  end

  State.effect(
    State.noted(app.with(stopping: true), "stopping the #{what}"),
    TUI.Cmd.Run(-> { State.Msg.Stopped(what, backend.stop.call(id, wanted)) }),
  )
end
