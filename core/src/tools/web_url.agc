## The URL of `web_fetch`, checked before any lookup. The address rule itself (no private, loopback, link-local or
## reserved address) is the `public_only` filter of the http client, which judges the addresses a host resolves to;
## this module refuses what must never reach the resolver, because the system reads it as an address or as this machine:
## - a host that ends in a number but is not four plain decimal numbers (`127.1`, `2130706433`, `0x7f.0.0.1`,
##   `0177.0.0.1`): the resolver would read it as an IPv4 address in the form of `inet_aton`;
## - `localhost` and every `*.localhost`;
## - user info (`http://good.example@127.0.0.1/`), a host with a character that no name has (a percent escape, a
##   backslash, a space, a non-ASCII letter) and a port that is not 1 to 65535.
## A dotted quad (`8.8.8.8`) and an IPv6 literal in brackets pass: the filter judges them.

PRIVATE_ADDRESS = "web_fetch.private_address"
BAD_URL = "web_fetch.url"
MAX_LABEL = 63
MAX_PORT = 65535

## The URL stripped, when it is an `http` or `https` URL that this module accepts; else an error of kind
## `web_fetch.url` (a bad URL) or `web_fetch.private_address` (a host that is, or may be read as, this machine or an
## address that the URL does not spell out strictly).
def check(url: String) -> Result[String]
  text = url.strip
  rest = try after_scheme(text)
  authority = rest.slice(0, authority_length(rest))
  return bad("the URL has user info") if authority.include?("@")

  host = try host_of(authority)
  try host_allowed(host)
  ok(text)
end

private

def after_scheme(text: String) -> Result[String]
  lower = text.downcase
  return ok(text.slice(7, text.length - 7)) if lower.start_with?("http://")
  return ok(text.slice(8, text.length - 8)) if lower.start_with?("https://")

  bad("the URL must start with http:// or https://")
end

def bad[T](reason: String) -> Result[T] = error("web_fetch: #{reason}", kind: BAD_URL)

def refused[T](host: String) -> Result[T]
  error("web_fetch: #{host} is a local or private address", kind: PRIVATE_ADDRESS)
end

def authority_length(rest: String) -> Int
  at = 0
  for char in rest.split("")
    return at if char == "/" or char == "?" or char == "#"

    at += 1
  end

  at
end

## The host of an authority (`host`, `host:port`, `[v6]`, `[v6]:port`), with its port checked.
def host_of(authority: String) -> Result[String]
  if authority.start_with?("[")
    close = authority.index_of("]")
    return bad("the IPv6 address has no closing bracket") if not close.some?

    inner = authority.slice(1, close.unwrap! - 1)
    tail = authority.slice(close.unwrap! + 1, authority.length - close.unwrap! - 1)
    return bad("not an IPv6 address: #{inner}") if not v6?(inner)

    try port_ok(tail)
    return ok("[#{inner}]")
  end

  parts = authority.split(":")
  return bad("the host has a colon") if parts.size > 2

  if parts.size == 2
    try port_ok(":#{parts[1]}")
  end

  return bad("the URL has no host") if parts[0] == ""

  ok(parts[0])
end

## `tail` is the text after the host: empty, or a colon and a port of 1 to 5 digits up to 65535.
def port_ok(tail: String) -> Result[Void]
  return ok() if tail == ""
  return bad("bad port after the host") if not tail.start_with?(":")

  port = tail.slice(1, tail.length - 1)
  return bad("bad port after the host") if port.empty? or port.length > 5 or not decimal?(port)
  return bad("port out of range") if port.to_i.unwrap_or(0) < 1 or port.to_i.unwrap_or(0) > MAX_PORT

  ok()
end

def v6?(text: String) -> Bool = text.include?(":") and text.bytes.to_a.all? { |b| hex_byte?(b) or b == 58 or b == 46 }

def host_allowed(host: String) -> Result[Void]
  return ok() if host.start_with?("[")

  lower = host.downcase
  dotted = lower.end_with?(".")
  name = lower
  if dotted
    name = lower.slice(0, lower.length - 1)
  end

  labels = name.split(".")
  return bad("the host name is empty") if name.empty?
  for label in labels
    return bad("bad host name: #{host}") if not label?(label)
  end

  return refused(host) if name == "localhost" or name.end_with?(".localhost")

  last = labels.last
  return ok() if not (decimal?(last) or hex_number?(last))
  return ok() if not dotted and quad?(labels)

  refused(host)
end

def label?(label: String) -> Bool
  return false if label.empty? or label.length > MAX_LABEL or label.start_with?("-") or label.end_with?("-")

  label.bytes.to_a.all? { |b| (b >= 97 and b <= 122) or (b >= 48 and b <= 57) or b == 45 }
end

def quad?(labels: List[String]) -> Bool = labels.size == 4 and labels.all? { |label| octet?(label) }

# One to three digits, no leading zero, at most 255.
def octet?(label: String) -> Bool
  (
    decimal?(label) and
    label.length <= 3 and
    (label == "0" or not label.start_with?("0")) and
    label.to_i.unwrap_or(256) <= 255
  )
end

def decimal?(text: String) -> Bool = not text.empty? and text.bytes.to_a.all? { |b| b >= 48 and b <= 57 }

def hex_number?(text: String) -> Bool
  text.start_with?("0x") and text.slice(2, text.length - 2).bytes.to_a.all? { |b| hex_byte?(b) }
end

def hex_byte?(b: Int) -> Bool = (b >= 48 and b <= 57) or (b >= 97 and b <= 102) or (b >= 65 and b <= 70)
