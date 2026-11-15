## A provider and the stream of one call: the only part of a provider that callers see.

import {Event, Model, Request, Response} from "types"

STREAM_WAIT_MS = 60_000

## One call in flight. Read `events` until it is closed, then `LLM.response` gives the outcome.
struct Stream
  events: Channel[Event]
  done: Task[Result[Response]]
  ## Stops the call at once; `LLM.cancel` calls it.
  stop: Fn[Void]
end

## An LLM API behind the common records. A provider for tests may give fixed streams with no HTTP at all.
struct Provider
  name: String
  stream: Fn[Request, Result[Stream]]
  models: Fn[Result[List[Model]]]
end

## Starts a call. An error here is one of the request itself (`llm.auth`, `llm.rate_limit` after its retries,
## `llm.network`, ...): nothing was streamed.
def stream(provider: Provider, request: Request) -> Result[Stream] = provider.stream.call(request)

## Stops a call at once: `events` closes, and the response is an `llm.cancelled` error.
def cancel(stream: Stream) -> Void
  stream.stop.call()
end

## The outcome of a call. It drops the events not read yet, then waits for the end of the call. Errors: those of the
## stream (`llm.protocol`, `llm.api`, `llm.network`) and `llm.cancelled`.
def response(stream: Stream) -> Result[Response]
  while not (stream.events.closed? and stream.events.empty?)
    _ = stream.events.recv(STREAM_WAIT_MS)
  end

  case Task.await(stream.done)
    ok(response) -> ok(response)
    error(e) if e.kind == "task.cancelled" -> error("llm: cancelled", kind: "llm.cancelled", cause: e)
    error(e) -> error(e)
  end
end

## The models of a provider.
def models(provider: Provider) -> Result[List[Model]] = provider.models.call()
