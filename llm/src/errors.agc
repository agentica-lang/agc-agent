## The errors of every provider: a kind under `llm.`, the HTTP status as `code`, and the retry of a request that
## failed before its first byte.

import HTTP from "std/http"

MAX_MESSAGE_CHARS = 500
## Kinds worth another try: the request never reached the model, or the API asked to come back.
RETRYABLE = Set.new(["llm.rate_limit", "llm.overloaded", "llm.server", "llm.network"])

## How a request is tried again: at most `tries` times in all, waiting `base_ms`, then twice as long each time, at
## most `max_ms`, or what `Retry-After` asks when it asks for longer.
struct Retry
  tries: Int = 3
  base_ms: Int = 500
  max_ms: Int = 30_000
end

## The error of a response that is not a 2xx: `llm.auth` (401, 403), `llm.rate_limit` (429, with `retry_after_ms` in
## `details` when the API sent `Retry-After`), `llm.overloaded` (503, 529), `llm.server` (another 5xx) or
## `llm.invalid_request`. The message is the API's own when its body has one.
def from_status[T](status: Int, headers: List[HTTP.Header], body: Bytes) -> Result[T]
  message = "llm: HTTP #{status}: #{api_message(body)}"
  case status
    401, 403 -> error(message, kind: "llm.auth", code: status)
    429 -> error(message, kind: "llm.rate_limit", code: status, details: retry_after(headers))
    503, 529 -> error(message, kind: "llm.overloaded", code: status)
    _ if status >= 500 -> error(message, kind: "llm.server", code: status)
    _ -> error(message, kind: "llm.invalid_request", code: status)
  end
end

## Calls `attempt` until it succeeds, fails with a kind that is not worth another try, or used its tries.
def with_retry[T](retry: Retry, attempt: Fn[Result[T]]) -> Result[T]
  tries = [retry.tries, 1].max.unwrap!
  wait_ms = [retry.base_ms, 0].max.unwrap!
  for n in 1..tries
    result = attempt.call()
    case result
      ok(_) -> return result
      error(e) ->
        return result if n == tries or not RETRYABLE.include?(e.kind)

        Task.sleep([[wait_ms, asked_ms(e)].max.unwrap!, [retry.max_ms, 0].max.unwrap!].min.unwrap!)
    end

    wait_ms = [wait_ms * 2, retry.max_ms].min.unwrap!
  end

  # Not reached: the last try returns above.
  error("llm: no try left", kind: "argument")
end

private

# `{"error": {"message": ...}}` or `{"error": "..."}`, else the body itself, cut short.
def api_message(body: Bytes) -> String
  text = String.from_bytes(body).unwrap_or("").strip
  case error_text(text)
    ok(message) -> message
    error(_) -> text.slice(0, [text.length, MAX_MESSAGE_CHARS].min.unwrap!)
  end
end

def error_text(text: String) -> Result[String]
  err = try JSON.get(try JSON.parse(text), "error")
  case JSON.string(err)
    ok(message) -> ok(message)
    error(_) -> JSON.string(try JSON.get(err, "message"))
  end
end

# Only the seconds form of `Retry-After`; an HTTP date asks for nothing.
def retry_after(headers: List[HTTP.Header]) -> Map[String, String]
  values = HTTP.header_values(headers, "retry-after")
  return {} if values.empty?

  case values[0].strip.to_i
    ok(seconds) if seconds >= 0 and seconds <= 86_400 -> {"retry_after_ms": "#{seconds * 1000}"}
    _ -> {}
  end
end

def asked_ms(e: Error) -> Int
  case e.details.get("retry_after_ms")
    some(ms) -> ms.to_i.unwrap_or(0)
    none -> 0
  end
end
