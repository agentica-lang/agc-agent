## The segments that the server serves for the status row (the extensions' and the ChatGPT quota): read again every
## `STATUS_MS` while the row has one, and at once when the session, its model or the layout changes.

import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import State from "state"

STATUS_MS = 5000

## Whether the row has a segment of the server to ask for: the quota counts only in a ChatGPT session, and an older
## server without the route (a 404) is not asked again in the session.
def polls?(app: State.Model) -> Bool
  return false if app.status_gone

  chatgpt = app.serving.start_with?("chatgpt/")
  case app.statusline
    some(layout) ->
      (layout.left + layout.right).any? do |name|
        not Protocol.BUILTIN_SEGMENTS.include?(name) and (name != Protocol.QUOTA_SEGMENT or chatgpt)
      end

    none -> chatgpt
  end
end

## The next read, when the row has something to ask for and none is on its way.
def tick(app: State.Model) -> State.Model
  return app if not polls?(app) or app.reading_status or app.id.empty?

  backend = app.backend
  id = app.id
  opened = app.opened
  serving = app.serving
  generation = app.status_generation + 1
  State.effect(
    app.with(reading_status: true, status_generation: generation),
    TUI.Cmd.Run(-> { State.Msg.StatusRead(opened, serving, generation, backend.status_segments.call(id)) }),
  )
end

## An answer: the segments it gives, or, when the read failed, the last ones, so that the row does not blink.
def read(app: State.Model, result: Result[Protocol.StatusSegments]) -> State.Model
  case result
    ok(found) -> app.with(reading_status: false, status_segments: found.segments)
    error(e) -> app.with(reading_status: false, status_gone: e.code == some(404))
  end
end
