# Scripts against a fake worker that replays frames recorded from the real `monty subprocess` 1.6.0. The fake checks
# that each request is the recorded one byte for byte, so these tests also hold the requests to what the worker took.
# Record again with `MONTY_RECORD=path/to/monty agentica test tests/worker_test.agc`.

import Monty from "../monty"
import Rig from "support/rig"

TOOLS = (
  "text = read_file(path='notes.txt')\n" +
  "print('read', text)\n" +
  "try:\n" +
  "    bash(command='rm -r build')\n" +
  "except PermissionError as e:\n" +
  "    print('denied:', e)\n" +
  "{'size': len(text), 'items': [1, 2.5, None, True, ('x',)]}\n"
)

def test_a_script_calls_host_functions_and_a_denial_raises() -> Result[Void]
  outcome = try Monty.run(Rig.fake("tools.json"), TOOLS, ["read_file", "bash"], &host)
  try Test.eq(outcome.output, "read hello\ndenied: the user denied this call\n")
  try Test.eq(outcome.error, none)
  Test.eq(JSON.encode(outcome.value), "{\"items\":[1,2.5,null,true,[\"x\"]],\"size\":5}")
end

def test_the_sandbox_has_no_files_and_unknown_names_fail() -> Result[Void]
  script = "try:\n    open('/etc/passwd')\nexcept PermissionError as e:\n    print('blocked')\nwrite_file(path='x')\n"
  outcome = try Monty.run(Rig.fake("blocked.json"), script, ["read_file"], &host)
  try Test.eq(outcome.output, "blocked\n")
  Test.eq(outcome.error, some("NameError: name 'write_file' is not defined (line 5)"))
end

def test_memory_time_and_call_limits_end_the_script_with_an_error() -> Result[Void]
  limits = Monty.Limits(max_feed_ms: 300, max_calls: 2)
  memory = try Monty.run(Rig.fake("memory.json"), "x = 'a' * 1000\nwhile True:\n    x = x + x\n", [], &host, limits)
  try Test.assert(memory.error.unwrap_or("").start_with?("MemoryError"), "memory: #{memory.error}")
  time = try Monty.run(Rig.fake("time.json"), "while True:\n    pass\n", [], &host, limits)
  try Test.assert(time.error.unwrap_or("").start_with?("TimeoutError"), "time: #{time.error}")
  script = "for i in range(3):\n    read_file(path='a')\n"
  calls = try Monty.run(Rig.fake("calls.json"), script, ["read_file"], &host, limits)
  Test.eq(calls.error, some("RuntimeError: a script makes at most 2 tool calls (line 2)"))
end

def test_a_worker_that_does_not_answer_is_stopped() -> Result[Void]
  limits = Monty.Limits(wait_ms: 300)
  case Monty.run(Rig.silent(), "1", [], &host, limits)
    ok(outcome) -> error("a silent worker gave #{outcome}")
    error(e) -> Test.eq(e.kind, "monty.timeout")
  end
end

def host(call: Monty.Call) -> Monty.Answer
  case call.name
    "bash" -> Monty.Answer.Raise("PermissionError", "the user denied this call")
    _ -> Monty.Answer.Value("hello")
  end
end

# Frames a broken or hostile worker could send: each ends the script with an error, never a crash of the host. Two
# args that share a big node, and the long name of a function shared five times, count toward the cap on how far a
# value expands.
def test_bad_frames_are_protocol_errors() -> Result[Void]
  bad = [
    "negative_index.json", "negative_child.json", "expand.json", "frame_cap.json", "shared_args.json",
    "long_name.json",
  ]

  for name in bad
    case Monty.run(Rig.fake(name), "1", ["f"], &host)
      ok(outcome) -> return error("#{name} gave #{outcome}")
      error(e) -> try Test.eq([name, e.kind], [name, "monty.protocol"])
    end
  end

  ok()
end

def test_a_refused_session_is_fatal() -> Result[Void]
  case Monty.run(Rig.fake("refused.json"), "1", [], &host)
    ok(outcome) -> error("a refused session gave #{outcome}")
    error(e) ->
      try Test.eq(e.kind, "monty.fatal")
      Test.assert(e.message.include?("bad limits"), e.message)
  end
end
