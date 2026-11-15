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

## A message sent while a turn runs (`409`).
KIND_SESSION_BUSY = "session.busy"

KIND_APPROVAL_NOT_FOUND = "approval.not_found"

## An answer that came after the approval was resolved: the first answer won, a rule or the timeout answered, or the
## turn stopped (`409`). The `approval_resolved` event tells who answered.
KIND_APPROVAL_RESOLVED = "approval.resolved"
