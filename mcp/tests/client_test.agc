import Mcp from "../mcp"

FAKES = ["tests/support/fake_server.agc", "mcp/tests/support/fake_server.agc"]

def test_lists_the_tools_and_calls_them() -> Result[Void]
  within_dir do |dir|
    client = Mcp.start(try fake(dir, {"FAKE_MCP_GREETING": "hi there"}))
    names = (try Mcp.tools(client)).map { |t| t.name }
    echo = Mcp.call(client, "echo", JSON.object({"text": JSON.from("hello")}))
    failed = Mcp.call(client, "fail", JSON.object({}))
    image = Mcp.call(client, "image", JSON.object({}))
    greeting = Mcp.call(client, "greeting", JSON.object({}))
    unknown = Mcp.call(client, "nope", JSON.object({}))
    Mcp.stop(client)
    try Test.eq(names, ["echo", "fail", "big", "greeting", "image", "crash", "hang"])
    try Test.eq(echo, ok(Mcp.Output(text: "hello", is_error: false)))
    try Test.eq(failed, ok(Mcp.Output(text: "it failed", is_error: true)))
    try Test.eq(image, ok(Mcp.Output(text: "a picture:\n[image image/png]", is_error: false)))
    try Test.eq(greeting, ok(Mcp.Output(text: "hi there", is_error: false)))
    try Test.eq(error_of(unknown), ["mcp.rpc", "-32602"])
    Test.eq(starts(dir), 1)
  end
end

def test_a_crashed_server_starts_again_on_the_next_use() -> Result[Void]
  within_dir do |dir|
    client = Mcp.start(try fake(dir, {}))
    crashed = Mcp.call(client, "crash", JSON.object({}))
    again = Mcp.call(client, "echo", JSON.object({"text": JSON.from("back")}))
    Mcp.stop(client)
    try Test.eq(error_of(crashed)[0], "mcp.unavailable")
    try Test.eq(again, ok(Mcp.Output(text: "back", is_error: false)))
    Test.eq(starts(dir), 2)
  end
end

def test_a_hung_server_is_stopped_and_starts_again() -> Result[Void]
  within_dir do |dir|
    client = Mcp.start(try fake(dir, {}), Mcp.Options(timeout_ms: 1000))
    began = Time.monotonic_ms()
    hung = Mcp.call(client, "hang", JSON.object({}))
    took = Time.monotonic_ms() - began
    again = Mcp.call(client, "echo", JSON.object({"text": JSON.from("back")}))
    Mcp.stop(client)
    try Test.eq(error_of(hung)[0], "mcp.unavailable")
    try Test.assert(took < 5000, "the hung call took #{took} ms")
    try Test.eq(again, ok(Mcp.Output(text: "back", is_error: false)))
    Test.eq(starts(dir), 2)
  end
end

def test_a_server_that_cannot_start_is_unavailable() -> Result[Void]
  client = Mcp.start(Mcp.Server(name: "none", command: "/nonexistent/mcp-server"))
  result = Mcp.tools(client)
  Mcp.stop(client)
  Test.eq(error_of(result)[0], "mcp.unavailable")
end

private

def fake(dir: String, env: Map[String, String]) -> Result[Mcp.Server]
  main = try Path.resolve(try existing(FAKES))
  ok(
    Mcp.Server(
      name: "fake",
      command: binary(),
      args: [main],
      env: env.put("FAKE_MCP_STARTS", "#{dir}/starts"),
      log: "#{dir}/stderr.log",
    ),
  )
end

def starts(dir: String) -> Int
  File.read_text("#{dir}/starts").unwrap_or("").split("\n").select { |l| l == "start" }.size
end

def error_of[T](result: Result[T]) -> List[String]
  case result
    ok(_) -> ["ok", ""]
    error(e) -> [e.kind, e.code.map { |c| c.to_s }.unwrap_or("")]
  end
end

def within_dir(body: Fn[String, Result[Void]]) -> Result[Void]
  tmp = System.env("TMPDIR").unwrap_or("/tmp")
  dir = "#{tmp}/mcp-test-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  result = body.call(dir)
  _ = Path.remove(dir)
  result
end

def binary() -> String
  case System.env("AGENTICA")
    ok(path) if path != "" -> path
    _ -> "agentica"
  end
end

def existing(paths: List[String]) -> Result[String]
  case (paths.find { |path| File.stat(path).ok? })
    ok(path) -> ok(path)
    error(_) -> error("none of #{paths.join(", ")} exists")
  end
end
