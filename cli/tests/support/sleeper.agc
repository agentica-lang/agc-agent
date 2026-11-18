## An Agentica program that serves nothing: it prints `ready PID` and waits a minute. The cleanup tests check that it is
## never stopped.

WAIT_MS = 60_000

def main() -> Void
  puts("ready #{System.pid()}")
  IO.flush()
  Task.sleep(WAIT_MS)
end
