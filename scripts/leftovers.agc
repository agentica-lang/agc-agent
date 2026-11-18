# Fails when a server that a test run started still runs after it: a process of this user with the run's
# `FINN_TEST_RUN` (the Makefile sets it for every test target) whose command line serves, the core
# (`core/main.agc serve`, or its bytecode) or the fake server of the cli tests. Each one is named and ended, so it does
# not stay either. Linux: it reads /proc.

RUN_ENV = "FINN_TEST_RUN"
STOP_MS = 3000
POLL_MS = 100
NUL = String.from_code(0)

struct Leftover
  pid: Int
  comm: String
  command: String
end

def main() -> Void
  run = System.env(RUN_ENV).unwrap_or("")
  if run == ""
    IO.warn("leftovers: #{RUN_ENV} is not set: nothing to check")
    return
  end

  if not File.stat("/proc/self").ok?
    puts("leftovers: skipped: this system has no /proc to look in")
    return
  end

  found = leftovers("#{RUN_ENV}=#{run}")
  if found.empty?
    puts("leftovers: no server of this test run is still running")
    return
  end

  for left in found
    IO.warn("leftovers: a server of this test run is still running: pid #{left.pid}: #{left.command}")
    ended(left)
  end

  System.exit(1)
end

private

def leftovers(marker: String) -> List[Leftover]
  found: List[Leftover] = []
  none_listed: List[String] = []
  names = Dir.list("/proc").unwrap_or(none_listed)
  for name in names
    pid = name.to_i.unwrap_or(0)
    next if pid <= 0 or pid == System.pid()

    case leftover(pid, marker)
      some(left) -> found = found.push(left)
      none -> nil
    end
  end

  found
end

def leftover(pid: Int, marker: String) -> Optional[Leftover]
  environ = File.read_text("/proc/#{pid}/environ").unwrap_or("")
  return none if not environ.split(NUL).include?(marker)

  words = File.read_text("/proc/#{pid}/cmdline").unwrap_or("").split(NUL).select { |word| not word.empty? }
  return none if not server?(words)

  comm = File.read_text("/proc/#{pid}/comm").unwrap_or("").strip
  some(Leftover(pid: pid, comm: comm, command: words.join(" ")))
end

def server?(words: List[String]) -> Bool
  core = words.include?("serve") and words.any? { |word| word.end_with?("core/main.agc") or word.end_with?(".agcb") }
  fake = words.any? { |word| word.end_with?("fake_main.agc") or word.end_with?("fake.agcb") }
  core or fake
end

# SIGTERM, then SIGKILL when it is still there after STOP_MS.
def ended(left: Leftover) -> Void
  _ = System.signal(left.pid, System.Signal.Term, left.comm)
  waited = 0
  while waited < STOP_MS and File.stat("/proc/#{left.pid}").ok?
    Task.sleep(POLL_MS)
    waited = waited + POLL_MS
  end

  if File.stat("/proc/#{left.pid}").ok?
    _ = System.signal(left.pid, System.Signal.Kill, left.comm)
  end
end
