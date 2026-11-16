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
    try Test.eq(names, ["echo", "fail", "big", "greeting", "probe", "image", "grandchild", "crash", "hang"])
    try Test.eq(echo, ok(Mcp.Output(text: "hello", is_error: false)))
    try Test.eq(failed, ok(Mcp.Output(text: "it failed", is_error: true)))
    try Test.eq(image, ok(Mcp.Output(text: "a picture:\n[image image/png]", is_error: false)))
    try Test.eq(greeting, ok(Mcp.Output(text: "hi there", is_error: false)))
    try Test.eq(error_of(unknown), ["mcp.rpc", "-32602"])
    try Test.eq(starts(dir), 1)
    # What the client sent: `initialized` after `initialize`, `{}` for the server's ping and -32601 for its other
    # request.
    sent = (try File.read_text("#{dir}/seen"))
      .split("\n")
      .select { |l| not l.empty? }
      .map { |l| JSON.parse(l).unwrap! }

    methods = sent.map { |j| JSON.string(JSON.get(j, "method").unwrap_or(JSON.from(""))).unwrap_or("") }
    try Test.eq(methods.take(3), ["initialize", "notifications/initialized", "tools/list"])
    try Test.eq(answer_to(sent, "srv-1"), JSON.parse("{\"jsonrpc\": \"2.0\", \"id\": \"srv-1\", \"result\": {}}"))
    Test.eq(JSON.get(JSON.get(answer_to(sent, "srv-2").unwrap!, "error").unwrap!, "code"), ok(JSON.from(-32601)))
  end
end

# An answer with another id is not the answer of the call.
def test_answers_are_matched_by_id() -> Result[Void]
  within_dir do |dir|
    client = Mcp.start(try fake(dir, {"FAKE_MCP_MODE": "shuffle"}))
    echo = Mcp.call(client, "echo", JSON.object({"text": JSON.from("mine")}))
    Mcp.stop(client)
    Test.eq(echo, ok(Mcp.Output(text: "mine", is_error: false)))
  end
end

# A server that always gives the same next cursor ends the list at once.
def test_a_cursor_seen_before_ends_the_list() -> Result[Void]
  within_dir do |dir|
    client = Mcp.start(try fake(dir, {"FAKE_MCP_MODE": "loop"}))
    began = Time.monotonic_ms()
    tools = Mcp.tools(client)
    took = Time.monotonic_ms() - began
    Mcp.stop(client)
    try Test.assert(took < 10_000, "the list took #{took} ms")
    lists = (try File.read_text("#{dir}/seen")).split("\n").select { |l| l.include?("tools/list") }.size
    try Test.eq(lists, 2)
    Test.eq((try tools).size, 2)
  end
end

# A server that never stops giving new cursors is read for 100 pages.
def test_the_list_stops_after_100_pages() -> Result[Void]
  within_dir do |dir|
    client = Mcp.start(try fake(dir, {"FAKE_MCP_MODE": "endless"}))
    tools = Mcp.tools(client)
    Mcp.stop(client)
    lists = (try File.read_text("#{dir}/seen")).split("\n").select { |l| l.include?("tools/list") }.size
    try Test.eq(lists, 100)
    Test.eq((try tools).size, 100)
  end
end

# The server runs in its own process group: a stop ends what it started too.
def test_a_stop_ends_the_programs_the_server_started() -> Result[Void]
  within_dir do |dir|
    client = Mcp.start(try fake(dir, {}))
    pid = (try Mcp.call(client, "grandchild", JSON.object({}))).text.strip
    try Test.assert(not pid.empty? and alive?(pid), "no grandchild: #{pid.inspect}")
    Mcp.stop(client)
    deadline = Time.monotonic_ms() + 5000
    while alive?(pid) and Time.monotonic_ms() < deadline
      Task.sleep(50)
    end

    Test.assert(not alive?(pid), "the grandchild #{pid} still runs")
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
      env: env.put("FAKE_MCP_STARTS", "#{dir}/starts").put("FAKE_MCP_SEEN", "#{dir}/seen"),
      log: "#{dir}/stderr.log",
    ),
  )
end

# A process that exited but was not reaped yet is a zombie: it counts as gone.
def alive?(pid: String) -> Bool
  case File.read_text("/proc/#{pid}/stat")
    ok(stat) -> not stat.include?(") Z ")
    error(_) -> false
  end
end

def answer_to(sent: List[JSON.Value], id: String) -> Result[JSON.Value]
  case (sent.find { |j| JSON.string(JSON.get(j, "id").unwrap_or(JSON.from(0))) == ok(id) })
    ok(found) -> ok(found)
    error(_) -> error("no answer to #{id}")
  end
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
