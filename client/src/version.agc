## The version of Finn: the UTC time of the commit it runs, `YYYYMMDDhhmmss`, which `bin/finn` puts in `FINN_VERSION`
## (`unknown` without it). Two such versions compare as text; a dotted one (`0.0.1`) is from before them, so older.
## The texts here tell a user which side is older and how to get the new one; every client shows the same.

VERSION_ENV = "FINN_VERSION"
UNKNOWN = "unknown"
DATED_LENGTH = 14
DIGITS = "0123456789"
KEEPS = "it waits for the running turns and keeps the sessions"

## How the server's version stands to the client's.
enum Age
  Same
  ## The server is older than the client.
  Older
  ## The server is newer than the client.
  Newer
  ## One side does not say its version.
  Unknown
end

## The version this program runs.
def finn_version() -> String
  case System.env(VERSION_ENV)
    ok(text) if text != "" -> text
    _ -> UNKNOWN
  end
end

## The age of the server's version against the client's.
def age(client: String, server: String) -> Age
  return Age.Same if client == server

  if dated?(client) and dated?(server)
    return Age.Newer if client.compare(server) < 0

    return Age.Older
  end

  return Age.Older if dated?(client) and dotted?(server)
  return Age.Newer if dated?(server) and dotted?(client)

  Age.Unknown
end

## One line for a server that serves this client but is of another version; "" when the versions are the same or one
## side does not say. `restart` is the command that restarts the server.
def note(client: String, server: String, restart: String) -> String
  case age(client, server)
    Age.Older ->
      (
        "the server runs an older Finn (#{server}) than this client (#{client}): `#{restart}` starts the new one; " +
        KEEPS
      )
    Age.Newer ->
      "this client (#{client}) is older than the server (#{server}): start the client again to use the new version"
    Age.Same, Age.Unknown -> ""
  end
end

## Why a client does not use the server of `dir` (pid `pid`), which is of another version and speaks another protocol.
def refusal(client: String, server: String, dir: String, pid: Int, restart: String) -> String
  case age(client, server)
    Age.Older ->
      (
        "the server of #{dir} (pid #{pid}) runs an older Finn (#{server}) than this client (#{client}) and cannot " +
        "serve it: `#{restart}` replaces it; #{KEEPS}"
      )
    Age.Newer ->
      (
        "this client (#{client}) is older than the server of #{dir} (#{server}, pid #{pid}) and cannot use it: start " +
        "the client again to use the new version"
      )
    Age.Same, Age.Unknown ->
      (
        "the server of #{dir} (pid #{pid}) runs another version of Finn than this client: `#{restart}` replaces it; " +
        KEEPS
      )
  end
end

## Why a client stops reading a server that now speaks another protocol (it was restarted under the client).
def changed(client: String, server: String, restart: String) -> String
  case age(client, server)
    Age.Older ->
      (
        "the server now runs an older Finn (#{server}) than this client (#{client}): `#{restart}` replaces it, then " +
        "start the client again"
      )
    Age.Newer -> "the server now runs a newer Finn (#{server}) than this client (#{client}): start the client again"
    Age.Same, Age.Unknown -> "the server now runs another version of Finn than this client: start the client again"
  end
end

## What `finn server status` adds to the server's version: how it stands to this client's.
def version_suffix(client: String, server: String, restart: String) -> String
  case age(client, server)
    Age.Older -> " (older than this client, #{client}: `#{restart}` replaces it)"
    Age.Newer -> " (newer than this client, #{client})"
    Age.Same, Age.Unknown -> ""
  end
end

private

def dated?(version: String) -> Bool = version.length == DATED_LENGTH and digits?(version)

# `0.0.1`: digits and dots, at least one dot.
def dotted?(version: String) -> Bool
  parts = version.split(".")
  parts.size > 1 and parts.all? { |part| not part.empty? and digits?(part) }
end

def digits?(text: String) -> Bool = not text.empty? and text.split("").all? { |c| DIGITS.include?(c) }
