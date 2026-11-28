## A subagent's Markdown deliverable: a task or follow-up with `deliverable: true` saves the child's whole
## answer as a session artifact of the parent and answers with a bounded preview and a stable reference the
## coordinator reads back with `read_tool_output`. The reference survives the child's deletion and a server
## restart, and no sibling or stranger can read it.

import Protocol from "pkg/protocol/protocol"
import Agents from "../src/ext/agents"
import Spec from "../src/tools/spec"
import Spill from "../src/tools/spill"
import Store from "../src/session/store"
import H from "support/harness"

## The sha256 of the answer `long_markdown.sse` streams, and its length in characters.
DELIVERABLE_ID = "f861e833c231a9f1bd580b677f5521e02071391fdf84a127da7f2b41ecc4f438"
ANSWER_CHARS = 11664
## The sha256 of the child's prompt, which a timed-out deliverable saves as the part of the answer there is.
PARTIAL_ID = "fffdb5c2dd9f68e9c82547f52c31c52aa686a41617ac9da12f6de6a894310968"

# A waited `deliverable` task saves the long Markdown answer the child reports, and the result carries the
# reference with a bounded preview instead of the whole text. The child is deleted with its answer, but the
# deliverable stays: the coordinator reads the whole answer back with `read_tool_output`, also after a restart,
# while a stranger's read of the same id is refused.
def test_waited_deliverable_saves_and_reads_back_after_restart_and_deletion() -> Result[Void]
  replies = [
    "agent_deliverable.sse", "long_markdown.sse", "text.sse", "read_deliverable.sse", "text.sse",
    "read_deliverable.sse", "text.sse", "read_deliverable.sse", "text.sse",
  ]

  H.using(H.Setup(replies: replies, approvals: false)) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    _ = try H.next_request(h)
    _ = try H.next_request(h)
    body = (try H.next_request(h)).body
    try Test.assert(body.include?("build (local/"), "no headed answer: #{clipped(body)}")
    try Test.assert(body.include?(": end_turn"), "the answer names no stop reason")
    try Test.assert(
      body.include?("[deliverable: #{DELIVERABLE_ID}] #{ANSWER_CHARS} bytes"),
      "no deliverable reference: #{clipped(body)}",
    )

    try Test.assert(body.include?("read_tool_output"), "the reference names no reading tool")
    try Test.assert(body.include?("# Field report"), "no bounded preview")
    try Test.assert(body.include?("[tool output artifact:"), "the long result is not spilled")
    try Test.assert(not body.include?("Finding 64"), "the whole answer leaked inline")
    # The child is gone with its answer, but its deliverable stays in the parent's store.
    child = try child_from_file(h, parent)
    try Test.eq((try H.get(h, Protocol.session_path(child))).status, 404)
    try Test.assert(File.stat(artifact_file(h, parent)).ok?, "the deliverable is not saved")
    # The coordinator reads the whole answer back through the existing artifact tool.
    try finished(h, parent, "Read the whole report.")
    _ = try H.next_request(h)
    first = (try H.next_request(h)).body
    try Test.assert(first.include?("# Field report"), "no readback page: #{clipped(first)}")
    try Test.assert(
      first.include?("[characters 0–4096 of #{ANSWER_CHARS}; next offset: 4096]"),
      "no paginated readback",
    )

    # The reference survives a server restart, and a stranger cannot read it.
    H.restarted(h, H.Setup(replies: replies, approvals: false), "") do |r|
      try finished(r, parent, "Read it again.")
      _ = try H.next_request(r)
      again = (try H.next_request(r)).body
      try Test.assert(again.include?("# Field report"), "no readback after the restart")
      stranger = try H.new_session(r)
      try finished(r, stranger, "Snoop on it.")
      _ = try H.next_request(r)
      refused = (try H.next_request(r)).body
      Test.assert(refused.include?("not available in this session"), "a stranger read it: #{clipped(refused)}")
    end
  end
end

# An async `deliverable` task answers with the child id at once, and the wake carries the reference with the
# bounded preview. The child stays open, and the coordinator reads the whole answer back afterwards.
def test_async_deliverable_wakes_with_the_reference() -> Result[Void]
  replies = ["agent_deliverable_nowait.sse", "long_markdown.sse", "text.sse", "read_deliverable.sse", "text.sse"]
  setup = H.Setup(replies: replies, approvals: false, max_rounds: some(1))
  H.using(setup) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    b = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(b)
    texts = (try H.session(h, parent)).history.map { |m| m.text }.join("\n")
    try Test.assert(texts.include?("[deliverable: #{DELIVERABLE_ID}]"), "the wake carries no reference")
    try Test.assert(texts.include?("# Field report"), "the wake carries no preview")
    try Test.assert(not texts.include?("Finding 64"), "the wake leaked the whole answer")
    child = try child_from_file(h, parent)
    try Test.eq((try H.get(h, Protocol.session_path(child))).status, 200)
    _ = try H.next_request(h)
    _ = try H.next_request(h)
    _ = try H.next_request(h)
    c = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Read the whole report.")
    c = try H.until(c, Protocol.EventKind.TurnFinished)
    H.close(c)
    _ = try H.next_request(h)
    d = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "And?")
    d = try H.until(d, Protocol.EventKind.TurnFinished)
    H.close(d)
    page = (try H.next_request(h)).body
    Test.assert(page.include?("[characters 0–4096 of #{ANSWER_CHARS}; next offset: 4096]"), "no readback")
  end
end

# A timed-out `deliverable` task still saves the part of the answer there is (here the prompt, nothing answered yet)
# with the timeout in the head. The child stays open for follow-up.
def test_timeout_saves_a_partial_deliverable() -> Result[Void]
  replies = ["agent_deliverable.sse", "long_markdown.sse@1500", "text.sse"]
  setup = H.Setup(replies: replies, approvals: false, subagent_timeout_ms: 500)
  H.using(setup) do |h|
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    _ = try H.next_request(h)
    _ = try H.next_request(h)
    body = (try H.next_request(h)).body
    try Test.assert(body.include?("timed out after 500 ms"), "the result names no timeout")
    try Test.assert(body.include?("[deliverable: #{PARTIAL_ID}] 23 bytes"), "no partial reference: #{clipped(body)}")
    Test.assert(File.stat(partial_file(h, parent)).ok?, "the partial deliverable is not saved")
  end
end

# A waited `deliverable` task through the tools alone saves the whole answer before the reference is answered, and
# exactly one duplicate finish saves nothing again: one save, tables empty, the reference reads back. The child runs
# until the test fires its finish, so the waiter's answer cannot slip past the wait.
def test_direct_waited_deliverable_saves_once() -> Result[Void]
  answer = long_answer()
  rig = try rig_manual(answer)
  input = try JSON.parse("{\"tasks\": [{\"prompt\": \"Write it.\", \"deliverable\": true}], \"wait\": true}")
  call = Task.spawn(-> { rig.tools[0].run.call(rig.ctx, input) })
  handler = try rig.handlers.recv(5000)
  _ = rig.handlers.send(handler, 0)
  fire(rig, "child-1", "turn-1")
  text = try awaited(Task.await(call, 5000))

  id = OpenSSL.Digest.sha256_hexdigest(answer.bytes)
  try Test.assert(text.include?("[deliverable: #{id}]"), "no reference: #{clipped(text)}")
  try Test.assert(text.include?(answer.slice(0, 8000)), "no bounded preview")
  try Test.assert(not text.include?("UNIQUE-TAIL-XYZ"), "the whole answer leaked inline")
  try Test.eq(try rig.port.read.call(id), answer)
  try Test.eq(rig.saves.get("n").unwrap_or(0), 1)
  fire(rig, "child-1", "turn-1")
  try Test.assert(not rig.woken.recv(0).ok?, "a duplicate finish woke")
  try Test.eq(rig.saves.get("n").unwrap_or(0), 1)
  try Test.assert(rig.saving.wanted.keys().empty?, "a flag is left behind")
  Test.assert(rig.turns.keys().empty?, "a turn is left behind")
end

# An async `deliverable` start whose child finishes at once wakes exactly once with the reference, and the artifact
# is already readable when the wake lands.
def test_direct_async_deliverable_wakes_once_with_a_readable_reference() -> Result[Void]
  answer = long_answer()
  rig = try rig_with(answer)
  input = try JSON.parse("{\"tasks\": [{\"prompt\": \"Write it.\", \"deliverable\": true}], \"wait\": false}")
  try Test.eq(try rig.tools[0].run.call(rig.ctx, input), "child-1")
  id = OpenSSL.Digest.sha256_hexdigest(answer.bytes)
  woke = try rig.woken.recv(5000)
  try Test.eq(woke.id, "parent")
  try Test.assert(woke.text.include?("[deliverable: #{id}]"), "the wake carries no reference: #{clipped(woke.text)}")
  try Test.eq(try rig.port.read.call(id), answer)
  try Test.eq(rig.saves.get("n").unwrap_or(0), 1)
  fire(rig, "child-1", "turn-1")
  try Test.assert(not rig.woken.recv(0).ok?, "a duplicate finish woke again")
  try Test.eq(rig.saves.get("n").unwrap_or(0), 1)
  try Test.assert(rig.saving.wanted.keys().empty?, "a flag is left behind")
  Test.assert(rig.turns.keys().empty?, "a turn is left behind")
end

# Two tasks of one async call each get their own answer, but only the one with `deliverable` saves a reference.
def test_direct_async_call_saves_only_the_opted_in_task() -> Result[Void]
  answer = long_answer()
  rig = try rig_counted(answer)
  input = try JSON.parse(
    "{\"tasks\": [{\"prompt\": \"Plain.\"}, {\"prompt\": \"Write it.\", \"deliverable\": true}], \"wait\": false}",
  )

  listed = (try rig.tools[0].run.call(rig.ctx, input)).split("\n")
  try Test.eq(listed.size, 2)
  id = OpenSSL.Digest.sha256_hexdigest(answer.bytes)
  first = try rig.woken.recv(5000)
  second = try rig.woken.recv(5000)
  refs = [first.text.include?("[deliverable: #{id}]"), second.text.include?("[deliverable: #{id}]")]
  try Test.eq(refs.select { |r| r }.size, 1)
  try Test.eq(try rig.port.read.call(id), answer)
  Test.eq(rig.saves.get("n").unwrap_or(0), 1)
end

# A waited `agent_send` follow-up with `deliverable` saves the follow-up answer; the child stays open.
def test_direct_send_deliverable_saves_the_followup() -> Result[Void]
  answer = long_answer()
  rig = try rig_with(answer)
  rig.names.put("child-1", "build")
  input = try JSON.parse("{\"id\": \"child-1\", \"text\": \"More.\", \"deliverable\": true}")
  text = try rig.tools[1].run.call(rig.ctx, input)
  id = OpenSSL.Digest.sha256_hexdigest(answer.bytes)
  try Test.assert(text.include?("[deliverable: #{id}]"), "no reference: #{clipped(text)}")
  try Test.eq(try rig.port.read.call(id), answer)
  try Test.assert(rig.saving.wanted.keys().empty?, "a flag is left behind")
  Test.eq((try rig.host.snapshot.call("child-1")).id, "child-1")
end

# Without the flag nothing is saved and the answer reads as before: no reference, no failure note.
def test_direct_answer_without_deliverable_is_unchanged() -> Result[Void]
  answer = long_answer()
  rig = try rig_manual(answer)
  input = try JSON.parse("{\"tasks\": [{\"prompt\": \"Write it.\"}], \"wait\": true}")
  call = Task.spawn(-> { rig.tools[0].run.call(rig.ctx, input) })
  handler = try rig.handlers.recv(5000)
  _ = rig.handlers.send(handler, 0)
  fire(rig, "child-1", "turn-1")
  text = try awaited(Task.await(call, 5000))
  try Test.assert(not text.include?("[deliverable:"), "an unasked reference: #{clipped(text)}")
  try Test.assert(not text.include?("was not saved"), "an unasked failure note")
  try Test.eq(rig.saves.get("n").unwrap_or(0), 0)
  Test.assert(text.include?(answer.slice(0, 8000)), "no ordinary preview")
end

# A deliverable nobody can read back is not saved: without `read_tool_output` in the turn's tools the result
# carries a failure note and no reference.
def test_direct_deliverable_without_the_reading_tool_is_not_saved() -> Result[Void]
  answer = long_answer()
  rig = try rig_manual(answer)
  plain = rig.ctx.with(tools: [])
  input = try JSON.parse("{\"tasks\": [{\"prompt\": \"Write it.\", \"deliverable\": true}], \"wait\": true}")
  call = Task.spawn(-> { rig.tools[0].run.call(plain, input) })
  handler = try rig.handlers.recv(5000)
  _ = rig.handlers.send(handler, 0)
  fire(rig, "child-1", "turn-1")
  text = try awaited(Task.await(call, 5000))
  try Test.assert(not text.include?("[deliverable:"), "an unreadable reference: #{clipped(text)}")
  try Test.assert(text.include?("was not saved"), "no failure note: #{clipped(text)}")
  try Test.eq(rig.saves.get("n").unwrap_or(0), 0)
  Test.assert(text.include?(answer.slice(0, 8000)), "no preview past the failure")
end

# A deliverable that does not fit the artifact size limit is not claimed: the result names the failure and carries
# no reference, with the bounded preview of what there is.
def test_direct_oversized_deliverable_is_not_claimed() -> Result[Void]
  rig = try rig_manual("tiny")
  big = "x" * (1_048_576 + 1)
  rig.answers.put("child-1", big)
  input = try JSON.parse("{\"tasks\": [{\"prompt\": \"Write it.\", \"deliverable\": true}], \"wait\": true}")
  call = Task.spawn(-> { rig.tools[0].run.call(rig.ctx, input) })
  handler = try rig.handlers.recv(5000)
  _ = rig.handlers.send(handler, 0)
  fire(rig, "child-1", "turn-1")
  text = try awaited(Task.await(call, 5000))
  try Test.assert(not text.include?("[deliverable:"), "an unsaved reference: #{clipped(text)}")
  try Test.assert(text.include?("was not saved"), "no failure note: #{clipped(text)}")
  Test.assert(text.include?("exceeds the artifact size limit"), "no reason: #{clipped(text)}")
end

# A full artifact quota fails the deliverable the same way: no reference, the reason named, the preview kept.
def test_direct_full_quota_deliverable_is_not_claimed() -> Result[Void]
  answer = long_answer()
  rig = try rig_manual(answer)
  for i in 0...256
    id = OpenSSL.Digest.sha256_hexdigest("filler #{i}".bytes)
    try rig.file.port.create.call("#{rig.file.path}.tool-#{id}", "filler #{i}")
  end

  input = try JSON.parse("{\"tasks\": [{\"prompt\": \"Write it.\", \"deliverable\": true}], \"wait\": true}")
  call = Task.spawn(-> { rig.tools[0].run.call(rig.ctx, input) })
  handler = try rig.handlers.recv(5000)
  _ = rig.handlers.send(handler, 0)
  fire(rig, "child-1", "turn-1")
  text = try awaited(Task.await(call, 5000))
  try Test.assert(not text.include?("[deliverable:"), "an unsaved reference: #{clipped(text)}")
  try Test.assert(text.include?("quota is full"), "no reason: #{clipped(text)}")
  Test.assert(text.include?(answer.slice(0, 8000)), "no preview past the failure")
end

# An empty answer with `deliverable` saves nothing: no reference and no failure note, and no artifact quota
# consumed. The flag is still consumed, so no later completion can save an unasked deliverable.
def test_direct_empty_deliverable_saves_nothing() -> Result[Void]
  rig = try rig_manual("")
  input = try JSON.parse("{\"tasks\": [{\"prompt\": \"Write it.\", \"deliverable\": true}], \"wait\": true}")
  call = Task.spawn(-> { rig.tools[0].run.call(rig.ctx, input) })
  handler = try rig.handlers.recv(5000)
  _ = rig.handlers.send(handler, 0)
  fire(rig, "child-1", "turn-1")
  text = try awaited(Task.await(call, 5000))
  try Test.assert(not text.include?("[deliverable:"), "an empty reference: #{clipped(text)}")
  try Test.assert(not text.include?("was not saved"), "an unasked failure note: #{clipped(text)}")
  try Test.eq(rig.saves.get("n").unwrap_or(0), 0)
  try Test.assert(rig.saving.wanted.keys().empty?, "a flag is left behind")
  Test.assert(rig.turns.keys().empty?, "a turn is left behind")
end

# A store that fails the write fails the deliverable but keeps the answer: no reference, the reason named.
def test_direct_write_failure_keeps_the_answer_without_a_reference() -> Result[Void]
  answer = long_answer()
  rig = try rig_broken(answer)
  input = try JSON.parse("{\"tasks\": [{\"prompt\": \"Write it.\", \"deliverable\": true}], \"wait\": true}")
  call = Task.spawn(-> { rig.tools[0].run.call(rig.ctx, input) })
  handler = try rig.handlers.recv(5000)
  _ = rig.handlers.send(handler, 0)
  fire(rig, "child-1", "turn-1")
  text = try awaited(Task.await(call, 5000))
  try Test.assert(not text.include?("[deliverable:"), "an unsaved reference: #{clipped(text)}")
  try Test.assert(text.include?("was not saved"), "no failure note: #{clipped(text)}")
  try Test.assert(text.include?("disk full"), "no reason: #{clipped(text)}")
  Test.assert(text.include?(answer.slice(0, 8000)), "no preview past the failure")
end

# With cap 1 two waited `deliverable` tasks each save their own artifact: freeing a finished child's cap slot never
# consumes its deliverable flag, so the first reference still reads back. Each child ends while the cap is
# re-evaluated for the next task, and its finish lands only after: the waiter still owns the answer then.
def test_waited_deliverables_survive_the_cap_with_delayed_finishes() -> Result[Void]
  answer1 = long_answer()
  answer2 = long_answer() + "\nSECOND-CHILD\n"
  rig = try rig_capped(answer1, answer2)
  input = try JSON.parse(
    "{\"tasks\": [{\"prompt\": \"First.\", \"deliverable\": true}, {\"prompt\": \"Second.\", \"deliverable\": true}], \"wait\": true}",
  )

  call = Task.spawn(-> { rig.tools[0].run.call(rig.ctx, input) })
  # Land each finish once it is safe: the release names each start and the idle cap check, and a finish fires only
  # after its start (its waiter is registered) or the idle check (its answer already waits).
  release = try release_of(rig)
  case release.recv(10000)
    ok(tag) if tag == "sent:child-1" -> nil
    ok(tag) -> return error("the first release is #{tag}")
    error(_) -> return error("the first start never released")
  end

  case release.recv(10000)
    ok(tag) if tag == "idle:child-1" -> fire_once(rig.handlers, "child-1", "turn-1")
    ok(tag) -> return error("the second release is #{tag}")
    error(_) -> return error("the first finish never released")
  end

  case release.recv(10000)
    ok(tag) if tag == "sent:child-2" -> fire_once(rig.handlers, "child-2", "turn-1")
    ok(tag) -> return error("the third release is #{tag}")
    error(_) -> return error("the second finish never released")
  end

  text = try awaited(Task.await(call, 5000))
  id1 = OpenSSL.Digest.sha256_hexdigest(answer1.bytes)
  id2 = OpenSSL.Digest.sha256_hexdigest(answer2.bytes)
  try Test.assert(text.include?("[deliverable: #{id1}]"), "the first reference is lost: #{clipped(text)}")
  try Test.assert(text.include?("[deliverable: #{id2}]"), "the second reference is lost: #{clipped(text)}")
  try Test.eq(try rig.port.read.call(id1), answer1)
  try Test.eq(try rig.port.read.call(id2), answer2)
  try Test.eq(rig.saves.get("n").unwrap_or(0), 2)
  try Test.assert(rig.saving.wanted.keys().empty?, "a flag is left behind")
  Test.assert(rig.turns.keys().empty?, "a turn is left behind")
end

# A dropped watcher event still saves the deliverable: with nothing overdue the bounded heartbeat reaps the idle
# child from its snapshot, collecting (and so saving) before clearing. The host drops every finish; its first two
# snapshots still run the turn (the start and its check), later ones are idle with the answer. The 50 ms heartbeat
# is the timeout under test, not a wait for something else.
def test_dropped_event_reaps_and_saves_the_deliverable() -> Result[Void]
  answer = long_answer()
  rig = try rig_dropped(answer)
  input = try JSON.parse("{\"tasks\": [{\"prompt\": \"Write it.\", \"deliverable\": true}], \"wait\": true}")
  call = Task.spawn(-> { rig.tools[0].run.call(rig.ctx, input) })
  text = try awaited(Task.await(call, 5000))
  id = OpenSSL.Digest.sha256_hexdigest(answer.bytes)
  try Test.assert(text.include?("[deliverable: #{id}]"), "the reaped reference is lost: #{clipped(text)}")
  try Test.eq(try rig.port.read.call(id), answer)
  try Test.eq(rig.saves.get("n").unwrap_or(0), 1)
  fire(rig, "child-1", "turn-1")
  try Test.assert(not rig.woken.recv(0).ok?, "a stale finish woke")
  try Test.eq(rig.saves.get("n").unwrap_or(0), 1)
  try Test.assert(rig.saving.wanted.keys().empty?, "a flag is left behind")
  Test.assert(rig.turns.keys().empty?, "a turn is left behind")
end

# A stopped async child still completes: its finish wakes once with the saved reference.
def test_direct_stopped_async_child_still_delivers_once() -> Result[Void]
  answer = long_answer()
  rig = try rig_manual(answer)
  input = try JSON.parse("{\"tasks\": [{\"prompt\": \"Write it.\", \"deliverable\": true}], \"wait\": false}")
  try Test.eq(try rig.tools[0].run.call(rig.ctx, input), "child-1")
  try Test.eq(try rig.host.stop.call("child-1"), true)
  fire(rig, "child-1", "turn-1")
  woke = try rig.woken.recv(5000)
  id = OpenSSL.Digest.sha256_hexdigest(answer.bytes)
  try Test.assert(woke.text.include?("[deliverable: #{id}]"), "the wake carries no reference")
  try Test.eq(try rig.port.read.call(id), answer)
  fire(rig, "child-1", "turn-1")
  try Test.assert(not rig.woken.recv(0).ok?, "a duplicate finish woke again")
  Test.eq(rig.saves.get("n").unwrap_or(0), 1)
end

private

## A wake the stub host recorded: the session it woke and the text it carried.
struct Woke
  id: String
  text: String
end

## A direct run of the subagent tools: the channels the stub host fires and records on, the counting artifact store
## and the tools with their context.
struct Rig
  handlers: Channel[Fn[Spec.Seen, Void]]
  woken: Channel[Woke]
  host: Spec.Host
  answers: ATS[String, String]
  file: Store.Ref
  port: Spill.Port
  bare: Spill.Port
  saves: ATS[String, Int]
  saving: Agents.Saving
  turns: ATS[String, String]
  tools: List[Spec.Tool]
  ctx: Spec.Context
  names: ATS[String, String]
  release: Optional[Channel[String]]
end

def finished(h: H.Harness, id: String, text: String) -> Result[Void]
  a = try H.subscribe(h, id, some((try H.session(h, id)).last_event_id))
  _ = try H.send(h, id, text)
  ended = try H.until(a, Protocol.EventKind.TurnFinished)
  H.close(ended)
  Test.eq(H.stop_reason(ended), "end_turn")
end

# The child id the parent's file names besides its own: the forwarded events carry it.
def child_from_file(h: H.Harness, parent: String) -> Result[String]
  text = try File.read_text(H.session_file(h, parent))
  for piece in text.split("\"")
    return ok(piece) if piece.start_with?("s") and piece.include?("-") and piece.length < 20 and piece != parent
  end

  error("the parent's file names no child")
end

def artifact_file(h: H.Harness, parent: String) -> String = "#{H.session_file(h, parent)}.tool-#{DELIVERABLE_ID}"

def partial_file(h: H.Harness, parent: String) -> String = "#{H.session_file(h, parent)}.tool-#{PARTIAL_ID}"

def awaited(waited: Await[Result[String]]) -> Result[String]
  case waited
    Await.Done(found) -> found
    _ -> error("the agent call did not answer")
  end
end

def clipped(text: String) -> String = text.slice(0, [text.length, 300].min.unwrap!)

# A long Markdown answer, past the 8000-character inline limit, with numbered sections and a unique tail.
def long_answer() -> String
  body = "# Report\n\n"
  for i in 1..25
    body = body + "## Section #{i}\n\n" + "Finding #{i}: the northern fence holds against the wind. " * 6 + "\n\n"
  end

  body + "UNIQUE-TAIL-XYZ\n"
end

# A rig whose child answers `answer` at once: `send` fires the watcher's `turn_finished` before it answers, so the
# completion lands before the send is registered, and the snapshot already holds the answer.
def rig_with(answer: String) -> Result[Rig]
  handlers: Channel[Fn[Spec.Seen, Void]] = Channel.new(1)
  woken: Channel[Woke] = Channel.new(4)
  answers: ATS[String, String] = ATS.new()
  answers.put("child-1", answer)
  rigged(handlers, woken, answers, at_once_host(handlers, woken, answers))
end

# The same rig, but the child runs until the test fires its finish by hand.
def rig_manual(answer: String) -> Result[Rig]
  handlers: Channel[Fn[Spec.Seen, Void]] = Channel.new(1)
  woken: Channel[Woke] = Channel.new(4)
  answers: ATS[String, String] = ATS.new()
  answers.put("child-1", answer)
  rigged(handlers, woken, answers, manual_host(handlers, woken, answers))
end

# The same rig, with one child per created id, for a two-task async call.
def rig_counted(answer: String) -> Result[Rig]
  handlers: Channel[Fn[Spec.Seen, Void]] = Channel.new(1)
  woken: Channel[Woke] = Channel.new(8)
  answers: ATS[String, String] = ATS.new()
  answers.put("child-1", answer)
  answers.put("child-2", answer)
  made: ATS[String, Int] = ATS.new()
  rigged(handlers, woken, answers, counted_host(handlers, woken, answers, made))
end

# The same rig, but every write fails.
def rig_broken(answer: String) -> Result[Rig]
  rig = try rig_manual(answer)
  failed = Spill.Port(save: ->(_text) { error("disk full") }, read: rig.bare.read)
  counting = Spill.Port(
    save: ->(text) {
      _ = rig.saves.add("n", 1)
      failed.save.call(text)
    },
    read: rig.bare.read,
  )

  saving = Agents.Saving(port: some(counting), wanted: ATS.new())
  waits: ATS[String, Address[Agents.Heard]] = ATS.new()
  wakes: ATS[String, String] = ATS.new()
  locks: ATS[String, Bool] = ATS.new()
  tools = Agents.tools(
    -> { [] },
    Agents.Limits(max: 0, timeout_ms: 0),
    rig.turns,
    waits,
    wakes,
    rig.names,
    locks,
    saving,
  )

  ok(rig.with(saving: saving, tools: tools))
end

# The same rig with cap 1, whose children end while the cap is re-evaluated and whose finishes land only after:
# the first two snapshots of a child still run its turn (the start and its check), the third is idle and releases
# its delayed finish, later ones are idle with the answer.
def rig_capped(answer1: String, answer2: String) -> Result[Rig]
  handlers: Channel[Fn[Spec.Seen, Void]] = Channel.new(4)
  woken: Channel[Woke] = Channel.new(8)
  answers: ATS[String, String] = ATS.new()
  answers.put("child-1", answer1)
  answers.put("child-2", answer2)
  made: ATS[String, Int] = ATS.new()
  seen: ATS[String, Int] = ATS.new()
  release: Channel[String] = Channel.new(4)
  rig = try rigged_limits(
    handlers,
    woken,
    answers,
    capped_host(handlers, woken, answers, made, seen, release),
    Agents.Limits(max: 1, timeout_ms: 0),
  )

  ok(rig.with(release: some(release)))
end

# The same rig, but the watcher never fires: the child's turn ends unseen, so the bounded heartbeat reaps it from
# its snapshot. The first two snapshots still run the turn (the start and its check); later ones are idle.
def rig_dropped(answer: String) -> Result[Rig]
  handlers: Channel[Fn[Spec.Seen, Void]] = Channel.new(1)
  woken: Channel[Woke] = Channel.new(4)
  answers: ATS[String, String] = ATS.new()
  answers.put("child-1", answer)
  seen: ATS[String, Int] = ATS.new()
  rigged_limits(
    handlers,
    woken,
    answers,
    dropped_host(handlers, answers, seen),
    Agents.Limits(max: 0, timeout_ms: 0, heartbeat_ms: 50),
  )
end

def rigged(
  handlers: Channel[Fn[Spec.Seen, Void]],
  woken: Channel[Woke],
  answers: ATS[String, String],
  host: Spec.Host,
) -> Result[Rig]
  rigged_limits(handlers, woken, answers, host, Agents.Limits(max: 0, timeout_ms: 0))
end

def rigged_limits(
  handlers: Channel[Fn[Spec.Seen, Void]],
  woken: Channel[Woke],
  answers: ATS[String, String],
  host: Spec.Host,
  limits: Agents.Limits,
) -> Result[Rig]
  file = try Store.create(Store.memory(["/data"]), "/data", header())
  bare = Store.artifacts(file)
  saves: ATS[String, Int] = ATS.new()
  counting = Spill.Port(
    save: ->(text) {
      _ = saves.add("n", 1)
      bare.save.call(text)
    },
    read: bare.read,
  )

  turns: ATS[String, String] = ATS.new()
  waits: ATS[String, Address[Agents.Heard]] = ATS.new()
  wakes: ATS[String, String] = ATS.new()
  names: ATS[String, String] = ATS.new()
  locks: ATS[String, Bool] = ATS.new()
  saving = Agents.Saving(port: some(counting), wanted: ATS.new())
  tools = Agents.tools(-> { [] }, limits, turns, waits, wakes, names, locks, saving)
  ctx = Spec.Context(
    root: "/tmp",
    env: ->(_name: String) { error("no env") },
    host: some(host),
    session: some("parent"),
    tools: [Spill.tool(bare)],
  )

  ok(
    Rig(
      handlers: handlers,
      woken: woken,
      host: host,
      answers: answers,
      file: file,
      port: counting,
      bare: bare,
      saves: saves,
      saving: saving,
      turns: turns,
      tools: tools,
      ctx: ctx,
      names: names,
      release: none,
    ),
  )
end

def release_of(rig: Rig) -> Result[Channel[String]]
  case rig.release
    some(release) -> ok(release)
    none -> error("the rig has no release channel")
  end
end

# A handle whose children end while the cap is re-evaluated and whose finishes land only after: `send` answers
# with the running turn, and the third snapshot of a child releases its delayed finish to its own watcher.
def capped_host(
  handlers: Channel[Fn[Spec.Seen, Void]],
  woken: Channel[Woke],
  answers: ATS[String, String],
  made: ATS[String, Int],
  seen: ATS[String, Int],
  release: Channel[String],
) -> Spec.Host
  Spec.Host(
    create: ->(_child: Spec.NewChild) {
      n = made.get("n").unwrap_or(0) + 1
      made.put("n", n)
      ok("child-#{n}")
    },
    send: ->(id: String, text: String) {
      if id.start_with?("child-")
        _ = release.send("sent:#{id}", 5000)
        return ok(Protocol.MessageAccepted(turn_id: "turn-1"))
      end

      _ = woken.send(Woke(id: id, text: text), 1000)
      ok(Protocol.MessageAccepted(turn_id: "wake-turn"))
    },
    stop: ->(_id: String) { ok(false) },
    delete: ->(_id: String) { ok() },
    snapshot: ->(id: String) {
      if id.start_with?("child-")
        n = seen.get(id).unwrap_or(0) + 1
        seen.put(id, n)
        if n == 3
          _ = release.send("idle:#{id}", 5000)
        end

        return ok(child_session(answers, id, some("turn-1"))) if n <= 2

        return ok(child_session(answers, id, none))
      end

      ok(parent_session(id))
    },
    watch: ->(_id: String, _names: List[String], handler: Fn[Spec.Seen, Void]) {
      _ = handlers.send(handler, 0)
      ok()
    },
  )
end

# Fires the watcher kept for `child` once, consuming it: each delayed finish pairs with the watcher its own start
# registered, since the earlier child is collected before the later one starts.
def fire_once(handlers: Channel[Fn[Spec.Seen, Void]], child: String, turn: String) -> Void
  case handlers.recv(5000)
    ok(handler) -> handler.call(finish_seen(child, turn))
    error(_) -> nil
  end
end

# A handle that drops every finish: `send` answers with the running turn but fires nothing, so the watcher never
# learns the turn ended. The snapshots after the start are idle with the answer.
def dropped_host(
  handlers: Channel[Fn[Spec.Seen, Void]],
  answers: ATS[String, String],
  seen: ATS[String, Int],
) -> Spec.Host
  Spec.Host(
    create: ->(_child: Spec.NewChild) { ok("child-1") },
    send: ->(id: String, _text: String) {
      return ok(Protocol.MessageAccepted(turn_id: "turn-1")) if id == "child-1"

      error("no parent send here")
    },
    stop: ->(_id: String) { ok(false) },
    delete: ->(_id: String) { ok() },
    snapshot: ->(id: String) {
      if id == "child-1"
        n = seen.get("n").unwrap_or(0) + 1
        seen.put("n", n)
        return ok(child_session(answers, id, some("turn-1"))) if n <= 2

        return ok(child_session(answers, id, none))
      end

      ok(parent_session(id))
    },
    watch: ->(_id: String, _names: List[String], handler: Fn[Spec.Seen, Void]) {
      _ = handlers.send(handler, 0)
      ok()
    },
  )
end

def header() -> Store.Header = Store.Header(id: "parent", cwd: "/tmp", model: "m", created_ms: 0)

def answer_of(answers: ATS[String, String], id: String) -> String = answers.get(id).unwrap_or("")

def child_session(answers: ATS[String, String], id: String, turn: Optional[String]) -> Protocol.Session
  Protocol.Session(
    id: id,
    cwd: "/tmp",
    model: "m",
    last_event_id: 0,
    turn_id: turn,
    turn_from_event_id: none,
    pending_approvals: [],
    history: [Protocol.Message(role: Protocol.Role.Assistant, text: answer_of(answers, id))],
    provider: "local",
  )
end

def parent_session(id: String) -> Protocol.Session
  Protocol.Session(
    id: id,
    cwd: "/tmp",
    model: "m",
    last_event_id: 0,
    turn_id: none,
    turn_from_event_id: none,
    pending_approvals: [],
    history: [],
    provider: "local",
  )
end

def finish_seen(child: String, turn: String) -> Spec.Seen
  Spec.Seen(
    session: child,
    root: "/tmp",
    name: "turn_finished",
    data: JSON.object({"turn_id": JSON.from(turn), "stop_reason": JSON.from("end_turn")}),
    parent: none,
  )
end

def fire_now(handlers: Channel[Fn[Spec.Seen, Void]], child: String, turn: String) -> Void
  case handlers.recv(0)
    ok(handler) ->
      _ = handlers.send(handler, 1000)
      handler.call(finish_seen(child, turn))
    error(_) -> nil
  end
end

def fire(rig: Rig, child: String, turn: String) -> Void
  fire_now(rig.handlers, child, turn)
end

def at_once_host(
  handlers: Channel[Fn[Spec.Seen, Void]],
  woken: Channel[Woke],
  answers: ATS[String, String],
) -> Spec.Host
  Spec.Host(
    create: ->(_child: Spec.NewChild) { ok("child-1") },
    send: ->(id: String, text: String) {
      if id == "child-1"
        fire_now(handlers, id, "turn-1")
        return ok(Protocol.MessageAccepted(turn_id: "turn-1"))
      end

      _ = woken.send(Woke(id: id, text: text), 1000)
      ok(Protocol.MessageAccepted(turn_id: "wake-turn"))
    },
    stop: ->(_id: String) { ok(false) },
    delete: ->(_id: String) { ok() },
    snapshot: ->(id: String) {
      return ok(child_session(answers, id, none)) if id == "child-1"

      ok(parent_session(id))
    },
    watch: ->(_id: String, _names: List[String], handler: Fn[Spec.Seen, Void]) {
      _ = handlers.send(handler, 0)
      ok()
    },
  )
end

def counted_host(
  handlers: Channel[Fn[Spec.Seen, Void]],
  woken: Channel[Woke],
  answers: ATS[String, String],
  made: ATS[String, Int],
) -> Spec.Host
  Spec.Host(
    create: ->(_child: Spec.NewChild) {
      n = made.get("n").unwrap_or(0) + 1
      made.put("n", n)
      id = "child-#{n}"
      answers.put(id, answers.get("child-1").unwrap_or(""))
      ok(id)
    },
    send: ->(id: String, text: String) {
      if id.start_with?("child-")
        fire_now(handlers, id, "turn-1")
        return ok(Protocol.MessageAccepted(turn_id: "turn-1"))
      end

      _ = woken.send(Woke(id: id, text: text), 1000)
      ok(Protocol.MessageAccepted(turn_id: "wake-turn"))
    },
    stop: ->(_id: String) { ok(false) },
    delete: ->(_id: String) { ok() },
    snapshot: ->(id: String) {
      return ok(child_session(answers, id, none)) if id.start_with?("child-")

      ok(parent_session(id))
    },
    watch: ->(_id: String, _names: List[String], handler: Fn[Spec.Seen, Void]) {
      _ = handlers.send(handler, 0)
      ok()
    },
  )
end

def manual_host(
  handlers: Channel[Fn[Spec.Seen, Void]],
  woken: Channel[Woke],
  answers: ATS[String, String],
) -> Spec.Host
  Spec.Host(
    create: ->(_child: Spec.NewChild) { ok("child-1") },
    send: ->(id: String, text: String) {
      return ok(Protocol.MessageAccepted(turn_id: "turn-1")) if id == "child-1"

      _ = woken.send(Woke(id: id, text: text), 1000)
      ok(Protocol.MessageAccepted(turn_id: "wake-turn"))
    },
    stop: ->(_id: String) { ok(true) },
    delete: ->(_id: String) { ok() },
    snapshot: ->(id: String) {
      return ok(child_session(answers, id, some("turn-1"))) if id == "child-1"

      ok(parent_session(id))
    },
    watch: ->(_id: String, _names: List[String], handler: Fn[Spec.Seen, Void]) {
      _ = handlers.send(handler, 0)
      ok()
    },
  )
end
