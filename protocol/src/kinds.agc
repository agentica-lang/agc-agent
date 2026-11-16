## The `Failure.kind` strings the server and the clients share. The server picks the HTTP status; a client branches on
## the kind, never on the message.

## A body or a header that is not a valid record (`400`).
KIND_INVALID = "protocol.invalid"

## A name that does not exist: an event, a decision, a role (`400`).
KIND_UNKNOWN = "protocol.unknown"

## No token, or a wrong one (`401`).
KIND_UNAUTHORIZED = "auth.unauthorized"

## A `Host` or `Origin` the server refuses (`403`).
KIND_FORBIDDEN = "auth.forbidden"

KIND_SESSION_NOT_FOUND = "session.not_found"

## A message sent while a turn runs and its queue is full (`409`).
KIND_SESSION_BUSY = "session.busy"

## The `error` event of a turn that ended before it read the messages queued for it: they were not sent to the model.
KIND_QUEUE_DROPPED = "session.queue_dropped"

## The server cannot write the session's file (`500`): the turn stops, and no turn starts until a write works.
KIND_SESSION_STORAGE = "session.storage"

## A session the server cannot load from its file now (`503`): a later request tries again.
KIND_SESSION_UNAVAILABLE = "session.unavailable"

KIND_APPROVAL_NOT_FOUND = "approval.not_found"

## An answer that came after the approval was resolved: the first answer won, a rule or the timeout answered, or the
## turn stopped (`409`). The `approval_resolved` event tells who answered.
KIND_APPROVAL_RESOLVED = "approval.resolved"
