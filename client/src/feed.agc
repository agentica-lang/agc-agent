## The task that reads the SSE stream of a session and hands each event to the client.

import HTTP from "std/http"
import SSE from "pkg/sse/sse"
import Protocol from "pkg/protocol/protocol"
import Client from "http"

RECV_MS = 60_000

struct Feed
  server: Client.Server
  session_id: String
  last_event_id: Int
  ## Hands an item to the client; an error stops the reader.
  tell: Fn[Item, Result[Void]]
end

enum Item
  ## The server accepted the subscription.
  Opened
  ## The event and its id (none when the stream gave none).
  Event(Optional[Int], Protocol.Event)
  ## An event this client does not know (a newer server) or cannot read: the reason. It is skipped.
  Skipped(String)
  ## The stream ended, or could not start: the reason.
  Ended(String)
end

## Starts the reader of the events after `feed.last_event_id`. It ends by sending `Item.Ended`.
def start(feed: Feed) -> Task[Void] = Task.spawn(&run, feed)

private

def run(feed: Feed) -> Void
  reason = case read(feed)
    ok(_) -> "the server closed the stream"
    error(e) -> e.message
  end

  _ = feed.tell(Item.Ended(reason))
end

def read(feed: Feed) -> Result[Void]
  http = try Client.open_events(feed.server, feed.session_id, feed.last_event_id)
  try tell(feed, Item.Opened)
  result = pump(feed, http)
  if result.ok?
    # The body ended: only the connection task tells a whole stream from a cut one.
    return Task.await(http.done)
  end

  Task.cancel(http.done)
  _ = Task.await(http.done)
  result
end

def tell(feed: Feed, item: Item) -> Result[Void]
  case feed.tell(item)
    ok(_) -> ok()
    error(e) -> error("the client took no more events: #{e.message}", kind: "client.stream", cause: e)
  end
end

def pump(feed: Feed, http: HTTP.Stream) -> Result[Void]
  parser = SSE.parser()
  while true
    case http.body.recv(RECV_MS)
      ok(piece) ->
        fed = try framing(SSE.feed(parser, piece))
        parser = fed.parser
        for sse in fed.events
          try deliver(feed, sse)
        end

      error(_) -> break if http.body.closed? and http.body.empty?
    end
  end

  ok()
end

def framing[T](result: Result[T]) -> Result[T]
  case result
    ok(value) -> ok(value)
    error(e) -> error("the event stream is broken: #{e.message}", kind: "client.stream", cause: e)
  end
end

def deliver(feed: Feed, sse: SSE.Event) -> Result[Void]
  case Protocol.decode_event(sse.name, sse.data)
    ok(event) -> tell(feed, Item.Event(event_id(sse), event))

    error(e) -> tell(feed, Item.Skipped("skipped event #{sse.name}: #{e.message}"))
  end
end

def event_id(sse: SSE.Event) -> Optional[Int]
  case Protocol.parse_event_id(sse.id)
    ok(id) -> some(id)
    error(_) -> none
  end
end
