# The URL check of `web_fetch`, before any lookup: what the model may not hand over as a host, whatever the address
# behind it. The address rule itself (every range) is the `public_only` filter of http-client.

import WebUrl from "../src/tools/web_url"

PRIVATE = "web_fetch.private_address"
BAD_URL = "web_fetch.url"

def kind_of(url: String) -> String
  case WebUrl.check(url)
    ok(_) -> "ok"
    error(e) -> e.kind
  end
end

# An IP literal in any form but the strict one, `localhost` and what ends in `.localhost` never get to the resolver.
def test_numeric_hosts_and_localhost_are_refused() -> Result[Void]
  hosts = [
    "127.0.0.1.", "127.1", "127.0.1", "2130706433", "0x7f000001", "0X7F.0.0.1", "0x7f.1", "0177.0.0.1", "0177.1", "0",
    "00", "0x0", "0x", "1.2.3", "8.8.8.8.8", "08.8.8.8", "01.2.3.4", "256.1.1.1", "999.0.0.1", "1.2.3.256",
    "localhost", "LOCALHOST", "localhost.", "app.localhost", "A.B.Localhost.",
  ]

  for host in hosts
    try Test.eq("#{host} #{kind_of("http://#{host}/")}", "#{host} #{PRIVATE}")
  end

  ok()
end

# Strict dotted quads and IPv6 literals go on: the address filter of the client decides on them.
def test_hosts_that_the_address_filter_judges_pass() -> Result[Void]
  urls = [
    "http://8.8.8.8/", "http://10.0.0.1/x", "https://[2001:4860:4860::8888]/", "http://[::1]:8080/",
    "http://[::ffff:7f00:1]/", "https://example.com", "http://example.com:8080/a?b=c#d", "HTTP://Example.COM/",
    "http://a-b.example.org./", "http://localhost.example.com/", "http://notlocalhost/", "http://1.2.3.4.example.com/",
    "http://0x.example.com/", "http://127.0.0.1:80", "http://127.0.0.1?x",
  ]

  for url in urls
    try Test.eq("#{url} #{kind_of(url)}", "#{url} ok")
  end

  ok()
end

# Not an http or https URL, user info, no host, or a host with a character that no name has: a bad URL.
def test_a_malformed_url_is_refused() -> Result[Void]
  urls = [
    "", "example.com", "ftp://example.com/", "file:///etc/passwd", "gopher://example.com", "//example.com/", "http:/x",
    "http://", "http:///path", "http://:80/", "http://user@example.com/", "http://user:pass@example.com/",
    "http://@example.com/", "http://example.com@127.0.0.1/", "http://example.com:80@127.0.0.1/",
    "http://127.0.0.1\\@example.com/", "http://exa mple.com/", "http://exa%6Dple.com/", "http://%31%32%37.0.0.1/",
    "http://example.com:99999/", "http://example.com:/", "http://example.com:80:80/", "http://[::1/", "http://::1/",
    "http://[::1]x/", "http://[fe80::1%25eth0]/", "http://[zz::1]/", "http://[]/", "http://exa\tmple.com/",
    "http://example.com\n/", "http://ex_ample.com/", "http://-example.com/", "http://example..com/",
    "http://.example.com/", "http://münchen.de/", "http://example.com:+80/", "http://example.com:8o/",
  ]

  for url in urls
    try Test.eq("#{url} #{kind_of(url)}", "#{url} #{BAD_URL}")
  end

  ok()
end

# Spaces around the URL do not matter, and the URL that comes back is the one to request.
def test_the_url_is_stripped() -> Result[Void]
  try Test.eq(WebUrl.check("  https://example.com/a?c  "), ok("https://example.com/a?c"))
  try Test.eq(WebUrl.check("\nhttp://example.com\n"), ok("http://example.com"))
  ok()
end

# A control character anywhere (it would split a request line or a header) and a URL over 8 KiB are refused.
def test_control_characters_and_a_huge_url_are_refused() -> Result[Void]
  nul = String.from_code(0)
  urls = [
    "http://example.com/a\r\nHost: evil",
    "http://example.com/a\nb",
    "http://example.com/#{nul}",
    "http://example.com/\tx",
    "http://example.com/?q=a#{String.from_code(127)}",
    "http://example.com\r/",
    "http://exam#{nul}ple.com/",
  ]

  for url in urls
    try Test.eq("#{url.length} #{kind_of(url)}", "#{url.length} #{BAD_URL}")
  end

  try Test.eq(kind_of("http://example.com/" + "a" * (8192 - 19)), "ok")
  try Test.eq(kind_of("http://example.com/" + "a" * (8192 - 18)), BAD_URL)
  ok()
end

# What a rule matches: scheme and host in lower case, no trailing dot, no default port, a path always; the rest as
# it is.
def test_the_url_a_rule_matches_is_canonical() -> Result[Void]
  table = [
    ["HTTP://Example.COM:80/A?b#c", "http://example.com/A?b#c"],
    ["https://EXAMPLE.com.:443", "https://example.com/"],
    ["https://example.com:8443/x", "https://example.com:8443/x"],
    ["http://example.com:443/", "http://example.com:443/"],
    ["http://[2001:DB8::1]:80/p", "http://[2001:db8::1]/p"],
    ["http://[2001:db8::1]:8080", "http://[2001:db8::1]:8080/"],
    ["http://example.com?q=1", "http://example.com/?q=1"],
    ["http://example.com:0080/", "http://example.com/"],
    ["  https://a.example/Path%20X  ", "https://a.example/Path%20X"],
  ]

  for row in table
    try Test.eq(WebUrl.canonical(row[0]), ok(row[1]))
  end

  try Test.eq(WebUrl.canonical("http://127.1/").unwrap_or("refused"), "refused")
  ok()
end
