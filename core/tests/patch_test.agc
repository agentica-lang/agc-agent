# `apply_patch`: offered to models on the Responses API as a custom tool with its grammar, approved as one call, and
# the Codex patch format as models write it.

import Protocol from "pkg/protocol/protocol"
import Approval from "../src/approval/approval"
import Patch from "../src/tools/patch"
import Tools from "../src/tools/tools"
import H from "support/harness"

def test_a_model_on_the_responses_api_patches_files() -> Result[Void]
  H.using(H.Setup(api: "openai_responses", replies: ["apply_patch.sse", "text.sse"])) do |h|
    try File.write_text("#{h.work}/notes.txt", "one\ntwo\nthree\n")
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Fix the notes.")
    a = try H.until(a, Protocol.EventKind.ApprovalRequested)
    asked = try H.approval(a)
    try Test.eq(asked.preview, "notes.txt, hello.txt")
    try Test.assert(asked.detail.start_with?("*** Begin Patch\n*** Update File: notes.txt"), asked.detail)
    _ = try H.approve(h, id, asked.approval_id, Protocol.Decision.Allow)
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    try Test.eq(File.read_text("#{h.work}/notes.txt"), ok("one\nTWO\nthree\n"))
    try Test.eq(File.read_text("#{h.work}/hello.txt"), ok("hello\n"))
    first = try JSON.parse((try H.next_request(h)).body)
    patch = (try JSON.list(try JSON.get(first, "tools"))).select { |t| text(t, "name") == "apply_patch" }
    formats = patch.map { |t| [text(t, "type"), text(JSON.get(t, "format").unwrap_or(JSON.null()), "syntax")] }
    try Test.eq(formats, [["custom", "lark"]])
    second = try JSON.parse((try H.next_request(h)).body)
    items = try JSON.list(try JSON.get(second, "input"))
    Test.eq(text(items.last, "output"), "Done. The files changed:\nM notes.txt\nA hello.txt")
  end
end

# A patch is checked whole: one hunk that does not apply leaves every file as it was.
def test_a_patch_applies_whole_or_not_at_all() -> Result[Void]
  dir = try fresh()
  try File.write_text("#{dir}/a.py", "def f():\n    x = 1\n    return x\n\ndef g():\n    x = 1\n    return x\n")
  try File.write_text("#{dir}/old.txt", "bye\n")
  ctx = try Tools.context(dir, ->(_n: String) { error("unset") }, true)
  bad = run(ctx, "*** Begin Patch\n*** Delete File: old.txt\n*** Update File: a.py\n-missing\n*** End Patch")
  try Test.eq(bad.is_error, true)
  try Test.eq(File.read_text("#{dir}/old.txt"), ok("bye\n"))
  patch = (
    "*** Begin Patch\n*** Update File: a.py\n*** Move to: src/b.py\n@@ def g():\n-    x = 1\n+    x = 2  \n" +
    "     return x\n*** End of File\n*** Delete File: old.txt\n*** End Patch\n"
  )

  good = run(ctx, patch)
  b = File.read_text("#{dir}/src/b.py")
  gone = [File.stat("#{dir}/a.py").ok?, File.stat("#{dir}/old.txt").ok?]
  entries = try Dir.list(dir) + try Dir.list("#{dir}/src")
  _ = Path.remove(dir)
  try Test.eq(entries.select { |name| name.include?(".finn-patch-") }, [])
  try Test.eq(good, Tools.Output(text: "Done. The files changed:\nM a.py -> src/b.py\nD old.txt", is_error: false))
  try Test.eq(b, ok("def f():\n    x = 1\n    return x\n\ndef g():\n    x = 2  \n    return x\n"))
  Test.eq(gone, [false, false])
end

# On chat completions `apply_patch` is not offered, and a call of it by name is refused.
def test_apply_patch_is_refused_as_a_function_call() -> Result[Void]
  H.using(H.Setup(replies: ["apply_patch.sse", "text.sse"])) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Add hello.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    first = try JSON.parse((try H.next_request(h)).body)
    names = (try JSON.list(try JSON.get(first, "tools"))).map { |t|
      text(JSON.get(t, "function").unwrap_or(JSON.null()), "name")
    }

    try Test.eq(names.include?("apply_patch"), false)
    messages = try JSON.list(try JSON.get(try JSON.parse((try H.next_request(h)).body), "messages"))
    try Test.eq(text(messages.last, "content"), "Error: unknown tool: apply_patch")
    Test.eq(File.stat("#{h.work}/hello.txt").ok?, false)
  end
end

# Changes land where they belong whatever the order of the chunks: an add with no context goes to the end, one after
# a context line goes after it, a context moves the search past an earlier copy of a line, and lines match with spaces
# at their end, then at both ends. CRLF files keep CRLF.
def test_chunks_land_in_place() -> Result[Void]
  dir = try fresh()
  ctx = try plain(dir)
  ten = (0...10).map { |i| "l#{i}" }
  try File.write_text("#{dir}/f.txt", "#{ten.join("\n")}\n")
  try File.write_text("#{dir}/g.txt", "a\nx\nb\nx\n")
  try File.write_text("#{dir}/h.txt", "a  \n  b\n")
  try File.write_text("#{dir}/crlf.txt", "a\r\nb\r\n")
  outputs = [
    run(ctx, update("f.txt", "@@\n+appended\n@@\n-l2\n+X\n+Y\n+Z\n@@ l5\n+after5")),
    run(ctx, update("g.txt", "@@ b\n-x\n+Y")),
    run(ctx, update("h.txt", "@@\n-a\n+A\n@@\n-b\n+B")),
    run(ctx, update("crlf.txt", "@@\n-a\n+A")),
  ]

  files = ["f.txt", "g.txt", "h.txt", "crlf.txt"].map { |name| File.read_text("#{dir}/#{name}").unwrap_or("") }
  _ = Path.remove(dir)
  try Test.eq(outputs.select { |o| o.is_error }.map { |o| o.text }, [])
  expected = ["l0", "l1", "X", "Y", "Z", "l3", "l4", "l5", "after5", "l6", "l7", "l8", "l9", "appended"]
  Test.eq(files, ["#{expected.join("\n")}\n", "a\nx\nb\nY\n", "A\nB\n", "A\r\nb\r\n"])
end

# Patches that cannot apply are refused before any file changes, quickly even for a line of many spaces.
def test_bad_patches_are_refused() -> Result[Void]
  dir = try fresh()
  ctx = try plain(dir)
  try File.write_text("#{dir}/a.txt", "one\n")
  try File.write_text("#{dir}/b.txt", "two\n")
  try Dir.mkdir("#{dir}/sub")
  many = (0..1000).map { |_i| "-x" }.join("\n")
  bad = [
    "*** Update File: a.txt\n-one\n+ONE\n*** End Patch",
    "*** Begin Patch\n*** Update File: a.txt\n-one\n+ONE",
    "*** Begin Patch\n*** Update File: a.txt\n*** End Patch",
    "*** Begin Patch\n*** Add File: new.txt\n*** End Patch",
    "*** Begin Patch\n*** Add File: a.txt\n+x\n*** End Patch",
    "*** Begin Patch\n*** Update File: a.txt\n*** Move to: b.txt\n-one\n+ONE\n*** End Patch",
    "*** Begin Patch\n*** Update File: sub\n-one\n+ONE\n*** End Patch",
    "*** Begin Patch\n*** Update File: a.txt\n-one\n+ONE\n*** Delete File: a.txt\n*** End Patch",
    "*** Begin Patch\n*** Update File: a.txt\n-missing\n+x\n*** End Patch",
    "*** Begin Patch\n*** Update File: a.txt\n#{many}\n*** End Patch",
    "*** Begin Patch\n*** Update File: a.txt\n-y#{" " * 400_000}\n+x\n*** End Patch",
  ]

  outputs = bad.map { |patch| run(ctx, patch) }
  files = [File.read_text("#{dir}/a.txt"), File.read_text("#{dir}/b.txt")]
  new = File.stat("#{dir}/new.txt").ok?
  _ = Path.remove(dir)
  try Test.eq(outputs.select { |o| not o.is_error }.map { |o| o.text }, [])
  Test.eq([files, [ok(new.to_s)]], [[ok("one\n"), ok("two\n")], [ok("false")]])
end

# Without the confinement a patch reaches outside the folder: it asks (there is no rule for that folder), the files are
# made with their folders, and a failed step removes the folders it made there too.
def test_an_unconfined_patch_reaches_outside_asks_and_rolls_back_its_new_folders() -> Result[Void]
  dir = try fresh()
  base = try fresh()
  outside = "#{base}/outside"
  try Dir.mkdir(outside)
  ctx = try Tools.context(dir, ->(_n: String) { error("unset") }, false)
  patch = "*** Begin Patch\n*** Add File: #{outside}/new/deep/x.txt\n+x\n*** End Patch"
  rules = try Approval.parse_rules(["allow apply_patch(*)"])
  asked = Approval.verdict(rules, ctx, "apply_patch", input(patch))
  allowed = try Approval.parse_rules(["allow apply_patch(*)", "allow external_directory(#{outside}/*)"])
  folder_rule = Approval.verdict(
    allowed,
    ctx,
    "apply_patch",
    input("*** Begin Patch\n*** Add File: #{outside}/y.txt\n+x\n*** End Patch"),
  )

  made = run(ctx, patch)
  kept = File.read_text("#{outside}/new/deep/x.txt")
  failing = (
    "*** Begin Patch\n*** Add File: #{outside}/other/z.txt\n+z\n*** Update File: missing.txt\n-a\n+b\n*** End Patch"
  )

  failed = run(ctx, failing)
  left = Dir.list(outside)
  _ = Path.remove(dir)
  _ = Path.remove(base)
  try Test.eq([asked, folder_rule], [Tools.Verdict.Ask, Tools.Verdict.Allow])
  try Test.eq(made.is_error, false)
  try Test.eq(kept, ok("x\n"))
  try Test.eq(failed.is_error, true)
  Test.eq(left, ok(["new"]))
end

# A write or a delete that fails midway puts back the files written before it, removes the files and folders it
# added, and gives a deleted file back with its mode.
def test_a_failed_step_restores_the_files() -> Result[Void]
  dir = try fresh()
  ctx = try plain(dir)
  try File.write_text("#{dir}/a.txt", "one\n")
  try File.write_text("#{dir}/run.sh", "echo hi\n")
  _ = try H.run("chmod", ["754", "#{dir}/run.sh"])
  try Dir.mkdir("#{dir}/ro")
  try File.write_text("#{dir}/ro/keep.txt", "keep\n")
  _ = try H.run("chmod", ["555", "#{dir}/ro"])
  writable = File.write_text("#{dir}/ro/probe", "x").ok?
  changes = "*** Update File: a.txt\n-one\n+ONE\n*** Add File: new/deep/x.txt\n+x\n*** Delete File: run.sh\n"
  outputs = [
    run(ctx, "*** Begin Patch\n#{changes}*** Add File: ro/new.txt\n+x\n*** End Patch"),
    run(ctx, "*** Begin Patch\n#{changes}*** Delete File: ro/keep.txt\n*** End Patch"),
  ]

  files = [File.read_text("#{dir}/a.txt"), File.read_text("#{dir}/run.sh"), File.read_text("#{dir}/ro/keep.txt")]
  mode = (try File.stat("#{dir}/run.sh")).mode
  entries = Dir.list(dir)
  _ = H.run("chmod", ["755", "#{dir}/ro"])
  _ = Path.remove(dir)
  return error("this test needs a user that a 555 folder stops, not root") if writable

  try Test.eq(outputs.select { |o| not (o.is_error and o.text.include?("no file was changed")) }, [])
  try Test.eq(files, [ok("one\n"), ok("echo hi\n"), ok("keep\n")])
  try Test.eq(mode, 0o754)
  Test.eq(entries, ok(["a.txt", "ro", "run.sh"]))
end

# The rollback removes only the new folders that are empty: one that gained a file stays.
def test_a_new_folder_that_gained_a_file_stays() -> Result[Void]
  dir = try fresh()
  try Dir.mkdir("#{dir}/new/sub")
  try File.write_text("#{dir}/new/sub/keep.txt", "keep\n")
  try Dir.mkdir("#{dir}/empty")
  failed = Patch.cleared(["#{dir}/new/sub", "#{dir}/new", "#{dir}/empty"])
  entries = Dir.list(dir)
  _ = Path.remove(dir)
  try Test.eq(failed, [])
  Test.eq(entries, ok(["new"]))
end

# The caps that keep one call short: the size of the patch, the old lines of a change, the line comparisons of the
# search, counted over the whole patch, so files that each fit can still be too much together, and the changes.
def test_a_patch_over_a_cap_is_refused() -> Result[Void]
  dir = try fresh()
  ctx = try plain(dir)
  long = (0...2000).map { |i| "l#{i}" }
  names = ["f0.txt", "f1.txt", "f2.txt"]
  for name in names
    try File.write_text("#{dir}/#{name}", "#{long.join("\n")}\n")
  end

  tail = "#{long.drop(1400).take(599).map { |line| " #{line}" }.join("\n")}\n-l1999\n+END"
  each = names.map { |name| "*** Update File: #{name}\n#{tail}" }
  many = (0..1000).map { |_i| "-x" }.join("\n")
  outputs = [
    run(ctx, "*** Begin Patch\n*** Add File: big.txt\n+#{"x" * 1_048_576}\n*** End Patch"),
    run(ctx, update("f0.txt", many)),
    run(ctx, "*** Begin Patch\n#{each.join("\n")}\n*** End Patch"),
    run(ctx, update("f0.txt", (0..1000).map { |_i| "@@\n+x" }.join("\n"))),
  ]

  untouched = names.map { |name| File.read_text("#{dir}/#{name}") == ok("#{long.join("\n")}\n") }
  one = run(ctx, "*** Begin Patch\n#{each.first}\n*** End Patch")
  _ = Path.remove(dir)
  wanted = [
    "is longer than 1048576 characters", "more than 1000 old lines", "more than 2000000 line comparisons",
    "more than 1000 changes",
  ]

  try Test.eq((0...4).select { |i| not (outputs[i].is_error and outputs[i].text.include?(wanted[i])) }, [])
  try Test.eq(untouched, [true, true, true])
  Test.eq(one.is_error, false)
end

# Each path decides as `edit_file` would: a path out of the folder or denied refuses the patch, `.git` asks.
def test_each_path_of_a_patch_is_approved_as_an_edit() -> Result[Void]
  dir = try fresh()
  rules = try Approval.parse_rules(["allow edit_file(*.txt)", "allow apply_patch(*)", "deny read_file(.env)"])
  ctx = try plain(dir)
  add = ->(path: String) { input("*** Begin Patch\n*** Add File: #{path}\n+x\n*** End Patch") }
  try Test.eq(Approval.verdict(rules, ctx, "apply_patch", add.call("a.txt")), Tools.Verdict.Allow)
  try Test.eq(Approval.verdict(rules, ctx, "apply_patch", add.call(".env")), Tools.Verdict.Deny)
  try Test.eq(Approval.verdict(rules, ctx, "apply_patch", add.call(".git/config")), Tools.Verdict.Ask)
  try Test.eq(Approval.verdict(rules, ctx, "apply_patch", add.call("../out.txt")), Tools.Verdict.Deny)
  asked = Approval.verdict(Approval.Rules(all: []), ctx, "apply_patch", add.call("a.txt"))
  _ = Path.remove(dir)
  Test.eq(asked, Tools.Verdict.Ask)
end

# An added file and a move target are writes (also denied by a deny rule of `edit_file`), a deleted file asks unless an
# `apply_patch` rule allows it.
def test_writes_and_deletes_follow_their_own_rules() -> Result[Void]
  dir = try fresh()
  try File.write_text("#{dir}/a.txt", "one\n")
  edits = try Approval.parse_rules([
    "allow edit_file(*)", "allow write_file(*)", "deny write_file(secret*)", "deny edit_file(frozen*)",
  ])

  ctx = try plain(dir)
  patches = [
    "*** Add File: secret.txt\n+x",
    "*** Update File: a.txt\n*** Move to: secret.txt\n-one\n+ONE",
    "*** Delete File: a.txt",
    "*** Add File: b.txt\n+x",
    "*** Update File: a.txt\n-one\n+ONE",
    "*** Add File: frozen.txt\n+x",
  ]

  verdicts = patches.map { |p|
    Approval.verdict(edits, ctx, "apply_patch", input("*** Begin Patch\n#{p}\n*** End Patch"))
  }

  patching = try Approval.parse_rules(["allow apply_patch(*.txt)"])
  delete = input("*** Begin Patch\n*** Delete File: a.txt\n*** End Patch")
  removed = Approval.verdict(patching, ctx, "apply_patch", delete)
  _ = Path.remove(dir)
  Test.eq(
    verdicts.push(removed),
    [
      Tools.Verdict.Deny, Tools.Verdict.Deny, Tools.Verdict.Ask, Tools.Verdict.Allow, Tools.Verdict.Allow,
      Tools.Verdict.Deny, Tools.Verdict.Allow,
    ],
  )
end

def update(path: String, body: String) -> String = "*** Begin Patch\n*** Update File: #{path}\n#{body}\n*** End Patch"

def plain(dir: String) -> Result[Tools.Context] = Tools.context(dir, ->(_n: String) { error("unset") }, true)

def run(ctx: Tools.Context, patch: String) -> Tools.Output = Tools.run(ctx, "apply_patch", input(patch))

def input(patch: String) -> JSON.Value = JSON.object({"input": JSON.from(patch)})

def text(json: JSON.Value, key: String) -> String
  JSON.string(JSON.get(json, key).unwrap_or(JSON.null())).unwrap_or("")
end

def fresh() -> Result[String]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/finn-patch-#{Random.int(0, 999_999_999)}"
  try Dir.mkdir(dir)
  Path.real(dir)
end
