# The worker comes from a wheel served on 127.0.0.1: only its one member is extracted, and only when the hash matches.

import HTTP from "std/http"
import Monty from "../monty"

WHEEL = "tests/fixtures/fake_wheel.whl"
WHEEL_SHA256 = "28cc033157623df660aca31bcf78ddd5832263fae002e3cdf8e69fc71bcd8661"
MEMBER = "pydantic_monty_runtime-1.6.0.data/scripts/monty"

def test_the_worker_is_fetched_once_and_only_its_member_is_extracted() -> Result[Void]
  served = try serve()
  cache = try fresh_dir()
  url = "http://127.0.0.1:#{HTTP.local_port(served.server)}/monty.whl"
  path = try Monty.binary(cache, Monty.Wheel(url: url, sha256: WHEEL_SHA256))
  again = try Monty.binary(cache, Monty.Wheel(url: url, sha256: WHEEL_SHA256))
  process = try Process.spawn_captured(path, ["subprocess"])
  _ = try Process.wait(process, 5_000)
  output = try Process.output(process, 5_000)
  HTTP.close_server(served.server)
  try Test.eq([path, again], ["#{cache}/monty-1.6.0/#{MEMBER}", "#{cache}/monty-1.6.0/#{MEMBER}"])
  try Test.eq(output.stdout, "fake monty subprocess\n")
  try Test.eq(Dir.list("#{cache}/monty-1.6.0"), ok(["pydantic_monty_runtime-1.6.0.data"]))
  try Test.eq(Dir.list(cache), ok(["monty-1.6.0"]))
  try Test.eq(served.requests.recv(0), ok("/monty.whl"))
  try Test.error?(served.requests.recv(0))
  Path.remove(cache)
end

def test_a_wheel_with_another_hash_installs_nothing() -> Result[Void]
  served = try serve()
  cache = try fresh_dir()
  url = "http://127.0.0.1:#{HTTP.local_port(served.server)}/monty.whl"
  result = Monty.binary(cache, Monty.Wheel(url: url, sha256: "0" * 64))
  HTTP.close_server(served.server)
  try Test.eq(result.ok?, false)
  try Test.assert(result.message.include?("sha256"), "the hash is named: #{result.message}")
  try Test.eq(Dir.list(cache), ok([]))
  Path.remove(cache)
end

private

struct Served
  server: HTTP.Server
  requests: Channel[String]
end

def serve() -> Result[Served]
  body = try wheel_bytes()
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
  try Dir.mkdir(dir)
  ok(dir)
end
