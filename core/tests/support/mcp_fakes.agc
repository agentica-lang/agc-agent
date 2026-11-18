## What the tests of the MCP servers share: a folder of their own, the config that names the fake server of the `mcp`
## package, and the paths to find it from the package or from the repository.

FAKES = ["../mcp/tests/support/fake_server.agc", "mcp/tests/support/fake_server.agc"]

def within_dir(body: Fn[String, Result[Void]]) -> Result[Void]
  tmp = System.env("TMPDIR").unwrap_or("/tmp")
  dir = "#{tmp}/core-mcp-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  result = body.call(dir)
  _ = Path.remove(dir)
  result
end

def write_config(dir: String, servers: Map[String, JSON.Value]) -> Result[Void]
  File.write_text("#{dir}/mcp.json", JSON.encode(JSON.object({"mcpServers": JSON.object(servers)})))
end

def fake_server(env: JSON.Value) -> Result[JSON.Value]
  main = try Path.resolve(try existing(FAKES))
  ok(JSON.object({"command": JSON.from(binary()), "args": JSON.from([main]), "env": env}))
end

def config_env(dir: String, name: String) -> Result[String]
  return ok("#{dir}/mcp.json") if name == "FINN_MCP_CONFIG"

  System.env(name)
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
