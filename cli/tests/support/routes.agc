## The routes of the fake that most tests use, so a test shows only what makes it different.

import Protocol from "pkg/protocol/protocol"
import Fake from "fake_server"

PROMPT = "allow? y = yes, n = no, a = yes for the session"

## `POST /v1/sessions` makes the session `s1`.
def created() -> Fake.Route
  reply = Fake.Reply(status: 201, body: "{\"id\": \"s1\"}")
  Fake.Route(method: "POST", path: Protocol.SESSIONS_PATH, replies: [reply])
end

## One event stream of `s1` that stays open for pushes.
def held_events() -> Fake.Route = events([Fake.Reply(hold: true)])

## The event streams of `s1`, one reply per subscription.
def events(replies: List[Fake.Reply]) -> Fake.Route
  Fake.Route(method: "GET", path: Protocol.events_path("s1"), replies: replies)
end

## `GET /v1/sessions/s1`, one reply per read.
def session(replies: List[Fake.Reply]) -> Fake.Route
  Fake.Route(method: "GET", path: Protocol.session_path("s1"), replies: replies)
end

## A message to `s1` is accepted and puts `pushes` on the event stream.
def accepting(pushes: List[String]) -> Fake.Route
  reply = Fake.Reply(status: 202, body: "{\"turn_id\": \"t1\"}", push: pushes)
  Fake.Route(method: "POST", path: Protocol.messages_path("s1"), replies: [reply])
end

def answering(approval_id: String, reply: Fake.Reply) -> Fake.Route
  Fake.Route(method: "POST", path: Protocol.approval_path("s1", approval_id), replies: [reply])
end

def stopping(reply: Fake.Reply) -> Fake.Route
  Fake.Route(method: "POST", path: Protocol.stop_path("s1"), replies: [reply])
end

## The reply that fails: the answer to an events request that is not a stream.
def failing() -> Fake.Reply
  failure = Protocol.Failure(kind: "server.error", message: "the server fails")
  Fake.Reply(status: 500, body: Protocol.encode_failure(failure))
end
