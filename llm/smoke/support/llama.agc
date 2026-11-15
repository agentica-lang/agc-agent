## A llama.cpp `llama-server` for the smoke tests: the one at `LLAMA_URL` when it is set, else one started here on
## 127.0.0.1, port 0, and stopped at the end.
##
## Started: `LLAMA_SERVER` (the binary) with `LLAMA_MODEL`; `make smoke-llama` sets both. Its log goes to `LLAMA_LOG`
## (`_build/llama-server.log` by default).

import HTTP from "std/http"

STARTUP_MS = 120_000
POLL_MS = 200
STOP_MS = 10_000
LISTENING = "listening on http://127.0.0.1:"

## A server to call. `process` is `none` for a server this run did not start.
struct Server
  url: String
  process: Optional[Process]
end

## The server, ready to answer.
def start() -> Result[Server]
  case System.env("LLAMA_URL")
    ok(url) if not url.empty? -> return ok(Server(url: url.strip, process: none))
    _ -> nil
  end

  binary = try System.env("LLAMA_SERVER")
  model = try System.env("LLAMA_MODEL")
  log = System.env("LLAMA_LOG").unwrap_or("_build/llama-server.log")
  args = ["-m", model, "--host", "127.0.0.1", "--port", "0", "--jinja", "-c", "4096", "-t", "2", "--alias", "qwen"]
  process = try Process.spawn(binary, args, Process.Options(out: log, err: log, timeout_ms: STARTUP_MS))
  server = Server(url: "", process: some(process))
  case ready(log)
    ok(port) -> ok(server.with(url: "http://127.0.0.1:#{port}/v1"))
    error(e) ->
      stop(server)
      error(e)
  end
end

## Stops a server this run started (SIGTERM, then a kill after a while).
def stop(server: Server) -> Void
  case server.process
    some(process) ->
      _ = Process.signal(process, System.Signal.Term)
      _ = Process.wait(process, STOP_MS)
      Process.close(process)
    none -> nil
  end
end

private

# The port is in the log once the server listens; it answers `/health` with 200 once the model is loaded.
def ready(log: String) -> Result[Int]
  deadline = Time.monotonic_ms() + STARTUP_MS
  port = 0
  while port == 0
    return error("llama-server did not listen within #{STARTUP_MS} ms (log: #{log})") if Time.monotonic_ms() > deadline

    port = listening_port(File.read_text(log).unwrap_or(""))
    Task.sleep(POLL_MS)
  end

  while not healthy?(port)
    if Time.monotonic_ms() > deadline
      return error("llama-server did not load its model within #{STARTUP_MS} ms (log: #{log})")
    end

    Task.sleep(POLL_MS)
  end

  ok(port)
end

def listening_port(text: String) -> Int
  case text.index_of(LISTENING)
    some(at) ->
      rest = text.slice(at + LISTENING.length, text.length - at - LISTENING.length)
      digits = rest.split("").take_while { |c| "0123456789".include?(c) }.join("")
      digits.to_i.unwrap_or(0)
    none -> 0
  end
end

def healthy?(port: Int) -> Bool
  case HTTP.get_response("http://127.0.0.1:#{port}/health", HTTP.ClientOptions(timeout_ms: 5000))
    ok(response) -> response.status == 200
    error(_) -> false
  end
end
