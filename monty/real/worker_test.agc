# The real worker: `make smoke-monty` downloads the pinned wheel of this platform into .tools/ (or takes MONTY_BIN),
# then runs scripts in it. Not hermetic (PyPI): never part of `make unit`.

import Monty from "../monty"

def test_the_real_worker_runs_a_script_that_calls_the_host() -> Result[Void]
  binary = try worker()
  script = "import json\nfound = grep(pattern='TODO')\nprint(json.dumps({'n': len(found)}))\nopen('/etc/hosts')\n"
  outcome = try Monty.run(Monty.command(binary), script, ["grep"], &host)
  try Test.eq(outcome.output, "{\"n\": 6}\n")
  Test.eq(outcome.error, some("PermissionError: Permission denied: '/etc/hosts' (line 4)"))
end

def worker() -> Result[String]
  case System.env("MONTY_BIN")
    ok(path) if path != "" -> ok(path)
    _ ->
      wheel = try Monty.wheel(try Monty.platform())
      Monty.binary(try Path.resolve("../.tools/cache"), wheel)
  end
end

def host(call: Monty.Call) -> Monty.Answer
  return Monty.Answer.Raise("RuntimeError", "unexpected #{call.name}") if call.name != "grep"

  Monty.Answer.Value("a TODO")
end
