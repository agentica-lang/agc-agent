# The worker comes from a wheel served on 127.0.0.1: only its one member is extracted, and only when the hash matches.

import HTTP from "std/http"
import Monty from "../monty"

WHEEL = "tests/fixtures/fake_wheel.whl"
# Its worker exits 126 at once, as a binary for another libc does.
BROKEN_WHEEL = "tests/fixtures/broken_wheel.whl"
WHEEL_SHA256 = "28cc033157623df660aca31bcf78ddd5832263fae002e3cdf8e69fc71bcd8661"
MEMBER = "pydantic_monty_runtime-1.6.0.data/scripts/monty"

def test_the_worker_is_fetched_once_and_only_its_member_is_extracted() -> Result[Void]
  served = try serve()
  cache = try fresh_dir()
  checked = fetched_once(served, cache)
  HTTP.close_server(served.server)
  _ = HTTP.wait(served.server)
  _ = Path.remove(cache)
  checked
end

def fetched_once(served: Served, cache: String) -> Result[Void]
  url = "http://127.0.0.1:#{HTTP.local_port(served.server)}/monty.whl"
  path = try Monty.binary(cache, Monty.Wheel(url: url, sha256: WHEEL_SHA256))
  again = try Monty.binary(cache, Monty.Wheel(url: url, sha256: WHEEL_SHA256))
  process = try Process.spawn_captured(path, ["subprocess"])
  _ = try Process.wait(process, 5_000)
  output = try Process.output(process, 5_000)
  try Test.eq([path, again], ["#{cache}/monty-1.6.0/#{MEMBER}", "#{cache}/monty-1.6.0/#{MEMBER}"])
  try Test.eq(output.stdout, "fake monty subprocess\n")
  try Test.eq(Dir.list("#{cache}/monty-1.6.0"), ok(["pydantic_monty_runtime-1.6.0.data"]))
  try Test.eq(Dir.list(cache), ok(["monty-1.6.0"]))
  try Test.eq(served.requests.recv(0), ok("/monty.whl"))
  Test.error?(served.requests.recv(0))
end

def test_a_wheel_with_another_hash_installs_nothing() -> Result[Void]
  served = try serve()
  cache = try fresh_dir()
  url = "http://127.0.0.1:#{HTTP.local_port(served.server)}/monty.whl"
  result = Monty.binary(cache, Monty.Wheel(url: url, sha256: "0" * 64))
  HTTP.close_server(served.server)
  _ = HTTP.wait(served.server)
  try Test.eq(result.ok?, false)
  try Test.assert(result.message.include?("sha256"), "the hash is named: #{result.message}")
  try Test.eq(Dir.list(cache), ok([]))
  Path.remove(cache)
end

# A cache folder others can write to is refused: they could swap the worker.
def test_a_cache_folder_open_to_others_is_refused() -> Result[Void]
  cache = try fresh_dir()
  chmod = try Process.spawn("chmod", ["755", cache])
  try Test.eq(Process.wait(chmod, 5_000), ok(0))
  result = Monty.binary(cache, Monty.Wheel(url: "http://127.0.0.1:9/never", sha256: WHEEL_SHA256))
  _ = Path.remove(cache)
  try Test.eq(result.ok?, false)
  Test.assert(result.message.include?("chmod 700"), result.message)
end

# A worker already in a cache others can write, or one that is a link, is not run: another user could have put it
# there.
def test_a_planted_worker_is_refused() -> Result[Void]
  open = try fresh_dir()
  try plant(open, "#!/bin/sh\necho planted\n")
  try chmod("777", open)
  wide = Monty.binary(open, Monty.Wheel(url: "http://127.0.0.1:9/never", sha256: WHEEL_SHA256))
  linked = try fresh_dir()
  try plant(linked, "")
  worker = "#{linked}/monty-1.6.0/#{MEMBER}"
  try Path.rename(worker, "#{worker}.real")
  try symlink("#{worker}.real", worker)
  link = Monty.binary(linked, Monty.Wheel(url: "http://127.0.0.1:9/never", sha256: WHEEL_SHA256))
  _ = Path.remove(open)
  _ = Path.remove(linked)
  try Test.assert(wide.message.include?("open to others"), wide.message)
  Test.assert(link.message.include?("not safe to run"), link.message)
end

# A worker that does not run here (built for another libc) is not installed, and the error says code mode is not
# available.
def test_a_worker_that_does_not_run_is_not_installed() -> Result[Void]
  body = try File.open(BROKEN_WHEEL) do |file| File.read_bytes(file, 1_048_576) end
  sha = OpenSSL.Digest.hexencode(try File.sha256(BROKEN_WHEEL))
  served = try serve_bytes(body)
  cache = try fresh_dir()
  url = "http://127.0.0.1:#{HTTP.local_port(served.server)}/monty.whl"
  result = Monty.binary(cache, Monty.Wheel(url: url, sha256: sha))
  HTTP.close_server(served.server)
  _ = HTTP.wait(served.server)
  listed = Dir.list(cache)
  _ = Path.remove(cache)
  try Test.assert(result.message.include?("code mode isn't available on this system"), result.message)
  Test.eq(listed, ok([]))
end

private

struct Served
  server: HTTP.Server
  requests: Channel[String]
end

def plant(cache: String, text: String) -> Result[Void]
  scripts = "#{cache}/monty-1.6.0/pydantic_monty_runtime-1.6.0.data/scripts"
  for dir in ["#{cache}/monty-1.6.0", "#{cache}/monty-1.6.0/pydantic_monty_runtime-1.6.0.data", scripts]
    try Dir.mkdir_private(dir)
  end

  try File.write_text("#{scripts}/monty", text)
  chmod("700", "#{scripts}/monty")
end

def chmod(mode: String, path: String) -> Result[Void]
  process = try Process.spawn("chmod", [mode, path])
  Test.eq(Process.wait(process, 5_000), ok(0))
end

def symlink(target: String, path: String) -> Result[Void]
  process = try Process.spawn("ln", ["-s", target, path])
  Test.eq(Process.wait(process, 5_000), ok(0))
end

def serve() -> Result[Served] = serve_bytes(try wheel_bytes())

def serve_bytes(body: Bytes) -> Result[Served]
  requests: Channel[String] = Channel.new(16)
  handler = ->(request: HTTP.Request, _body: HTTP.RequestBody) {
    _ = requests.send(request.path, 0)
    ok(HTTP.Answer.Whole(HTTP.Response(status: 200, headers: [], body: body)))
  }

  server = try HTTP.serve("127.0.0.1", 0, handler)
  ok(Served(server: server, requests: requests))
end

def wheel_bytes() -> Result[Bytes] = File.open(WHEEL) do |file| File.read_bytes(file, 1_048_576) end

def fresh_dir() -> Result[String]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/monty-install-#{Random.int(0, 999_999_999)}"
  try Dir.mkdir_private(dir)
  ok(dir)
end
