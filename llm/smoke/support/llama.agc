## A llama.cpp `llama-server` for the smoke tests: the one at `LLAMA_URL` when it is set, else one started here on
## 127.0.0.1, port 0, and stopped at the end.
##
## Started: `LLAMA_SERVER` (the binary) with `LLAMA_MODEL`; `make smoke-llama` sets both. Each server logs to
## `llama-server-NAME.log` in `LLAMA_LOG_DIR` (else `TMPDIR`, else `/tmp`).

import HTTP from "std/http"

STARTUP_MS = 120_000
POLL_MS = 200
STOP_MS = 10_000
LOG_TAIL_CHARS = 2000
LISTENING = "listening on http://127.0.0.1:"
DIGITS = "0123456789"

## A server to call. `process` is `none` for a server this run did not start.
struct Server
  url: String
  process: Optional[Process]
end

## The server, ready to answer. `name` names its log.
def start(name: String) -> Result[Server]
  case System.env("LLAMA_URL")
    ok(url) if not url.empty? -> return ok(Server(url: url.strip, process: none))
    _ -> nil
  end

  binary = try System.env("LLAMA_SERVER")
  model = try System.env("LLAMA_MODEL")
  log = "#{log_dir()}/llama-server-#{name}.log"
  args = ["-m", model, "--host", "127.0.0.1", "--port", "0", "--jinja", "-c", "4096", "-t", "2", "--alias", "qwen"]
  process = try Process.spawn(binary, args, Process.Options(out: log, err: log))
  server = Server(url: "", process: some(process))
  case ready(process, log)
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

def log_dir() -> String
  for name in ["LLAMA_LOG_DIR", "TMPDIR"]
    case System.env(name)
      ok(dir) if not dir.empty? -> return dir
      _ -> nil
    end
  end

  "/tmp"
end

# The port is in the log once the server listens; it answers `/health` with 200 once the model is loaded. A server
# that exits on the way fails at once, with the end of its log.
def ready(process: Process, log: String) -> Result[Int]
  deadline = Time.monotonic_ms() + STARTUP_MS
  port = 0
  while port == 0
    try alive(process, log, deadline)
    port = listening_port(File.read_text(log).unwrap_or(""))
  end

  while not healthy?(port)
    try alive(process, log, deadline)
  end

  ok(port)
end

# Waits one poll for the process to exit: an exit, or the deadline, is the error.
def alive(process: Process, log: String, deadline: Int) -> Result[Void]
  case Process.wait(process, POLL_MS)
    ok(code) -> return error("llama-server exited with #{code} while starting:\n#{log_tail(log)}")
    error(_) -> nil
  end

  if Time.monotonic_ms() > deadline
    return error("llama-server was not ready within #{STARTUP_MS} ms:\n#{log_tail(log)}")
  end

  ok()
end

def log_tail(log: String) -> String
  text = File.read_text(log).unwrap_or("")
  start = [text.length - LOG_TAIL_CHARS, 0].max.unwrap!
  text.slice(start, text.length - start)
end

# The port counts only when a non-digit follows it: a read in the middle of the line gives no port yet.
def listening_port(text: String) -> Int
  case text.index_of(LISTENING)
    some(at) ->
      rest = text.slice(at + LISTENING.length, text.length - at - LISTENING.length)
      digits = rest.split("").take_while { |c| DIGITS.include?(c) }.join("")
      return 0 if digits.length == rest.length

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
