## `web_fetch`: an HTTP or HTTPS request for the model, as minibot's `http_request` makes it, for public addresses only.
##
## The host is resolved and every address that is not public (loopback, private, link-local, reserved, and the IPv4
## forms inside IPv6) is dropped; the connection goes to an address that was checked, so a second DNS answer cannot
## lead elsewhere, and a redirect is dialed the same way, hop by hop. That is the `public_only` filter of the http
## client; `WebUrl` refuses beforehand what the system would read as this machine. A call that reaches no public
## address fails with `web_fetch_private_address`. There is no setting that allows private addresses: a local target
## goes through `bash` (`curl`), which has its own approval. `Settings.public_only` and `resolver` exist so that a test
## can reach its peer on 127.0.0.1 or choose what a name resolves to.
##
## A body is read up to `max(max_bytes, max_parse_bytes)` bytes and cut at `max_bytes` (a page of HTML is read up to
## `max_parse_bytes`); there is no file for the rest.

import HttpClient from "pkg/http-client/http_client"
import HTTP from "std/http"
import Regex from "std/regex"
import Spec from "spec"
import WebUrl from "web_url"

NAME = "web_fetch"
METHODS = ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]
## The whole request, the body included, is given this many times `timeout_ms`.
TOTAL_TIMEOUT_FACTOR = 3
MAX_HEADERS = 10
INVALID_URL = "web_fetch_invalid_url"
INVALID_REQUEST = "web_fetch_invalid_request"
PRIVATE_ADDRESS = "web_fetch_private_address"
TIMEOUT = "web_fetch_timeout"
FAILED = "web_fetch_failed"

## The limits are minibot's defaults. Redirects are returned as they are unless `follow_redirects`.
struct Settings
  timeout_ms: Int = 10_000
  follow_redirects: Bool = false
  max_redirects: Int = 5
  max_bytes: Int = 16_384
  max_parse_bytes: Int = 2_000_000
  ## The longest text given back; none is `max_bytes`.
  max_chars: Optional[Int] = none
  ## A seam for tests, never read from a config or the model's input: off, any address is reached.
  public_only: Bool = true
  resolver: Optional[Fn[String, Result[List[String]]]] = none
end

struct FetchArgs
  url: String
  method: Optional[String]
  headers: Optional[Map[String, String]]
  body: Optional[String]
  json: Optional[String]
end

## What a good call gives.
struct Page
  status: Int
  headers: Map[String, String]
  body: String
  content_type: String
  truncated: Bool
  truncated_chars: Bool
  processor_used: String
end

## What a failed call gives, as the text of the error.
struct Failure
  ok: Bool
  error_code: String
  error: String
  url: String
end

def tool() -> Spec.Tool = tool_with(Settings())

def tool_with(settings: Settings) -> Spec.Tool
  Spec.Tool(
    name: NAME,
    description: (
      "Fetch an HTTP or HTTPS URL on the public internet. Returns status, headers (the first #{MAX_HEADERS}), body, " +
      "content_type, truncated, truncated_chars and processor_used. A body over #{settings.max_bytes} bytes is cut. " +
      "Redirects are not followed. Local and private addresses are refused: use bash (curl) for those."
    ),
    input_schema: JSON.schema(FetchArgs),
    asks: true,
    run: ->(ctx: Spec.Context, input: JSON.Value) { run(settings, ctx, input) },
    target: &target,
  )
end

## What a rule sees of the target of a call of `tool`: for `web_fetch` the URL, up to the tab that starts what tells two
## calls to one URL apart; the target of another tool as it is.
def rule_view(tool: String, target: String) -> String
  return target if tool != NAME

  target.split("\t").take(1).join("")
end

## What a call would send, for the approval: the method and the URL, the headers, and the body or the JSON.
def detail(input: JSON.Value) -> String
  case Spec.args(input, FetchArgs.codec)
    ok(args) ->
      given = args.headers.unwrap_or({})
      lines = ["#{method_of(args)} #{args.url.strip}"] + given.keys.map { |name| "#{name}: #{given[name]}" }
      body = args.body.unwrap_or(args.json.unwrap_or(""))
      if body != ""
        lines = lines + ["", body]
      end

      lines.join("\n")
    error(_) -> ""
  end
end

private

struct RequestBody
  bytes: Optional[Bytes]
  json: Optional[JSON.Value]
end

struct Processed
  text: String
  name: String
end

## The target of a call, which the rules and the answers of approval see. It is the URL as a rule matches it (see
## `WebUrl.canonical`); a call that does more than read (a method other than GET or HEAD, headers or a body) adds, after
## a tab, its method and a hash of what it sends, so that allowing one call never allows another.
def target(_ctx: Spec.Context, input: JSON.Value) -> Result[String]
  args = try Spec.args(input, FetchArgs.codec)
  url = WebUrl.canonical(args.url).unwrap_or(args.url.strip)
  method = method_of(args)
  given = args.headers.unwrap_or({})
  reads = (method == "GET" or method == "HEAD") and given.empty? and not args.body.some? and not args.json.some?
  return ok(url) if reads

  sent = given.keys.sort.map { |name| "#{name.downcase}:#{given[name]}" }.join("\n")
  digest = "#{method}\n#{sent}\n#{args.body.unwrap_or("")}\n#{args.json.unwrap_or("")}"
  ok("#{url}\t#{method} #{OpenSSL.Digest.sha256_hexdigest(digest.bytes).slice(0, 12)}")
end

def method_of(args: FetchArgs) -> String = args.method.unwrap_or("GET").upcase

def run(settings: Settings, _ctx: Spec.Context, input: JSON.Value) -> Result[String]
  args = try Spec.args(input, FetchArgs.codec)
  url = args.url.strip
  case fetch(settings, url, args)
    ok(page) -> ok(JSON.encode(JSON.from(page)))
    error(e) -> error(JSON.encode(JSON.from(failure(args, url, e))))
  end
end

def failure(args: FetchArgs, url: String, e: Error) -> Failure
  method = method_of(args)
  detail = e.message.strip
  if detail.empty?
    detail = e.kind
  end

  code = code_of(e)
  if code == TIMEOUT and not detail.include?("timeout")
    detail = "timeout: #{detail}"
  end

  Failure(ok: false, error_code: code, error: "#{method} #{url} failed: #{detail}", url: url)
end

def code_of(e: Error) -> String
  return PRIVATE_ADDRESS if e.is_a?("web_fetch.private_address") or e.is_a?("http_client.address_denied")
  return INVALID_URL if e.is_a?("web_fetch.url")
  return TIMEOUT if e.is_a?("http_client.timeout") or e.is_a?("net.timeout") or e.is_a?("channel.timeout")
  return INVALID_REQUEST if e.is_a?("argument") or e.is_a?("web_fetch.request")

  FAILED
end

def fetch(settings: Settings, url: String, args: FetchArgs) -> Result[Page]
  checked = try WebUrl.check(url)
  method = method_of(args)
  return error("unsupported method #{method}", kind: "web_fetch.request") if not METHODS.include?(method)

  given = args.headers.unwrap_or({})
  for name in given.keys
    try header_ok(name, given[name])
  end

  headers = given.keys.map { |name| HTTP.Header(name: name, value: given[name]) }
  body = try request_body(args)
  client = try HttpClient.new(
    connect_timeout_ms: settings.timeout_ms,
    read_timeout_ms: settings.timeout_ms,
    timeout_ms: settings.timeout_ms,
    max_retries: 1,
    max_redirects: redirects(settings),
    max_body_bytes: settings.max_parse_bytes,
    dns_cache_ms: 0,
    resolver: settings.resolver,
    public_only: settings.public_only,
  )

  result = exchange(settings, client, method, checked, headers, body)
  HttpClient.close(client, 0)
  result
end

## A header the client would refuse after it connected is refused here, so a bad call never opens a connection: a name
## that is no HTTP token, a value with a control character (a line break would add a header), and the headers that the
## client sets itself.
def header_ok(name: String, value: String) -> Result[Void]
  if not Regex.match?(name, /\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/)
    return error("bad header name: #{name}", kind: "web_fetch.request")
  end

  if value.split("").any? { |char| (char.code < 32 and char != "\t") or char.code == 127 }
    return error("the header #{name} has a control character", kind: "web_fetch.request")
  end

  if ["host", "content-length", "transfer-encoding", "connection"].include?(name.downcase)
    return error("the header #{name} is set by the client", kind: "web_fetch.request")
  end

  ok()
end

def redirects(settings: Settings) -> Int
  return settings.max_redirects if settings.follow_redirects

  0
end

def request_body(args: FetchArgs) -> Result[RequestBody]
  if args.body.some? and args.json.some?
    return error("provide either json or body, not both", kind: "web_fetch.request")
  end

  case args.json
    some(text) ->
      case JSON.parse(text)
        ok(value) -> return ok(RequestBody(bytes: none, json: some(value)))
        error(_) -> return error("json must be a JSON string", kind: "web_fetch.request")
      end

    none -> nil
  end

  ok(RequestBody(bytes: args.body.map { |text| text.bytes }, json: none))
end

def exchange(
  settings: Settings,
  client: HttpClient.Client,
  method: String,
  url: String,
  headers: List[HTTP.Header],
  body: RequestBody,
) -> Result[Page]
  deadline = Time.monotonic_ms() + settings.timeout_ms * TOTAL_TIMEOUT_FACTOR
  stream = try HttpClient.stream(client, method, url, body: body.bytes, json: body.json, headers: headers)
  limit = read_limit(settings, content_type(stream.headers))
  content = read(stream, limit, deadline)
  HttpClient.cancel(stream)
  ok(shaped(settings, stream, try content))
end

## HTML is read up to `max_parse_bytes`, which the compaction needs to see a whole page; any other type up to `max_bytes`
## (one byte more, which says that the body was cut).
def read_limit(settings: Settings, type: String) -> Int
  if html?(type)
    settings.max_parse_bytes + 1
  else
    settings.max_bytes + 1
  end
end

def html?(type: String) -> Bool = type == "text/html" or type == "application/xhtml+xml"

def read(stream: HttpClient.Stream, limit: Int, deadline: Int) -> Result[Bytes]
  pieces: List[Bytes] = []
  size = 0
  while size < limit
    left = deadline - Time.monotonic_ms()
    return error("timeout: the body did not arrive in time", kind: "net.timeout") if left < 1

    case stream.body.recv(left)
      ok(ok(piece)) ->
        pieces = pieces.push(piece)
        size += piece.size
      ok(error(e)) -> return error(e)
      error(e) if e.is_a?("channel.closed") -> break
      error(e) -> return error(e)
    end
  end

  ok(Bytes.concat(pieces).take(limit))
end

def shaped(settings: Settings, stream: HttpClient.Stream, content: Bytes) -> Page
  type = content_type(stream.headers)
  processed = process(content.take(read_limit(settings, type) - 1).scrub, type, html?(type))
  cap = settings.max_chars.unwrap_or(settings.max_bytes)
  cut = processed.text.length > cap
  text = processed.text
  if cut
    text = text.slice(0, cap)
  end

  Page(
    status: stream.status,
    headers: first_headers(stream.headers),
    body: text,
    content_type: type,
    truncated: content.size > settings.max_bytes,
    truncated_chars: cut,
    processor_used: processed.name,
  )
end

def process(text: String, type: String, html: Bool) -> Processed
  return Processed(text: text, name: "none") if html or type == "application/json" or type.end_with?("+json")

  words = Regex.split(text, /\s+/).select { |word| not word.empty? }
  Processed(text: words.join(" "), name: "plain")
end

def content_type(headers: List[HTTP.Header]) -> String
  value = HTTP.header_values(headers, "content-type").join(",")
  value.split(";").take(1).join("").strip.downcase
end

def first_headers(headers: List[HTTP.Header]) -> Map[String, String]
  shown: Map[String, String] = {}
  for header in headers.take(MAX_HEADERS)
    shown = shown.put(header.name, header.value)
  end

  shown
end
