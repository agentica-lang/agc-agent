## The task that reads the SSE stream of a session and puts its events on the inbox.

import HTTP from "std/http"
import SSE from "pkg/sse/sse"
import Protocol from "pkg/protocol/protocol"
import Client from "client"
import Inbox from "inbox"

RECV_MS = 60_000
SEND_MS = 30_000

struct Feed
  server: Client.Server
  session_id: String
  last_event_id: Int
  generation: Int
  inbox: Channel[Inbox.Input]
end

## Starts the reader of the events after `feed.last_event_id`. It ends by sending `Item.Ended`.
def start(feed: Feed) -> Task[Void] = Task.spawn(&run, feed)

private

def run(feed: Feed) -> Void
  reason = case read(feed)
    ok(_) -> "the server closed the stream"
    error(e) -> e.message
  end

  _ = feed.inbox.send(Inbox.Input.Stream(feed.generation, Inbox.Item.Ended(reason)), SEND_MS)
end

def read(feed: Feed) -> Result[Void]
  http = try Client.open_events(feed.server, feed.session_id, feed.last_event_id)
  try tell(feed, Inbox.Item.Opened)
  result = pump(feed, http)
  return Task.await(http.done) if result.ok?

  Task.cancel(http.done)
  _ = Task.await(http.done)
  result
end

def tell(feed: Feed, item: Inbox.Item) -> Result[Void]
  feed.inbox.send(Inbox.Input.Stream(feed.generation, item), SEND_MS)
end

def pump(feed: Feed, http: HTTP.Stream) -> Result[Void]
  parser = SSE.parser()
  while true
    case http.body.recv(RECV_MS)
      ok(piece) ->
        fed = try SSE.feed(parser, piece)
        parser = fed.parser
        for sse in fed.events
          try deliver(feed, sse)
        end

      error(_) -> break if http.body.closed? and http.body.empty?
    end
  end

  ok()
end

# An event this client cannot read (from a newer server) is skipped.
def deliver(feed: Feed, sse: SSE.Event) -> Result[Void]
  case Protocol.decode_event(sse.name, sse.data)
    ok(event) -> tell(feed, Inbox.Item.Event(event_id(sse), event))
    error(_) -> ok()
  end
end

def event_id(sse: SSE.Event) -> Optional[Int]
  case Protocol.parse_event_id(sse.id)
    ok(id) -> some(id)
    error(_) -> none
  end
end
