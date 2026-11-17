## The output speed of the model for the footer: exact from the `usage` of a call, estimated from its text while it
## streams. Pure.

import Protocol from "pkg/protocol/protocol"

## Tokens a second; `estimated` while the call streams, from its characters.
struct Rate
  per_s: Int
  estimated: Bool = false
end

## The text of the call that streams: when its first piece came and the characters after that piece.
struct Streamed
  first_ms: Int
  chars: Int = 0
end

## The call that streams after a piece of `text` at `now_ms`.
def streamed(so_far: Optional[Streamed], text: String, now_ms: Int) -> Streamed
  case so_far
    some(s) -> s.with(chars: s.chars + text.length)
    none -> Streamed(first_ms: now_ms)
  end
end

## The estimate at `now_ms`, about 4 characters a token; none before the call has streamed for a while, so a burst of
## replayed pieces shows none.
def live(s: Streamed, now_ms: Int) -> Optional[Rate]
  elapsed = now_ms - s.first_ms
  return none if elapsed < MIN_MS or s.chars == 0

  some(Rate(per_s: (s.chars * 1000 + (CHARS_PER_TOKEN * elapsed) / 2) / (CHARS_PER_TOKEN * elapsed), estimated: true))
end

## The output tokens of the call (its reasoning included) over the time from its first output to its end; none for a
## call whose output came in one burst (a reply not streamed, or held back on the way), which has no speed to show.
def exact(usage: Protocol.Usage) -> Optional[Rate]
  ms = usage.output_ms.unwrap_or(0)
  tokens = usage.call_output.unwrap_or(0)
  return none if ms < MIN_EXACT_MS or tokens <= 0

  some(Rate(per_s: (tokens * 1000 + ms / 2) / ms))
end

## `42 tok/s`, `~42 tok/s` for an estimate, "" with none.
def text(rate: Optional[Rate]) -> String
  case rate
    some(r) if r.estimated -> "~#{r.per_s} tok/s"
    some(r) -> "#{r.per_s} tok/s"
    none -> ""
  end
end

private

CHARS_PER_TOKEN = 4
MIN_MS = 500
MIN_EXACT_MS = 200
