# `apply_patch`: offered to models on the Responses API as a custom tool with its grammar, approved as one call, and
# the Codex patch format as models write it.

import Protocol from "pkg/protocol/protocol"
import Approval from "../src/approval"
import Tools from "../src/tools"
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
  ctx = try Tools.context(dir, ->(_n: String) { error("unset") }, Tools.Rules(allow: [], deny: []))
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
  _ = Path.remove(dir)
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

# Patches that cannot apply are refused before any file changes.
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
  ]

  outputs = bad.map { |patch| run(ctx, patch) }
  files = [File.read_text("#{dir}/a.txt"), File.read_text("#{dir}/b.txt")]
  new = File.stat("#{dir}/new.txt").ok?
  _ = Path.remove(dir)
  try Test.eq(outputs.select { |o| not o.is_error }.map { |o| o.text }, [])
  Test.eq([files, [ok(new.to_s)]], [[ok("one\n"), ok("two\n")], [ok("false")]])
end

# A write that fails midway puts back the files written before it.
def test_a_failed_write_restores_the_files() -> Result[Void]
  dir = try fresh()
  ctx = try plain(dir)
  try File.write_text("#{dir}/a.txt", "one\n")
  try Dir.mkdir("#{dir}/ro")
  _ = try H.run("chmod", ["555", "#{dir}/ro"])
  writable = File.write_text("#{dir}/ro/probe", "x").ok?
  out = run(ctx, "*** Begin Patch\n*** Update File: a.txt\n-one\n+ONE\n*** Add File: ro/new.txt\n+x\n*** End Patch")
  a = File.read_text("#{dir}/a.txt")
  _ = H.run("chmod", ["755", "#{dir}/ro"])
  _ = Path.remove(dir)
  return ok() if writable

  try Test.assert(out.is_error and out.text.include?("no file was changed"), out.text)
  Test.eq(a, ok("one\n"))
end

# Each path decides as `edit_file` would: a path out of the folder or denied refuses the patch, `.git` asks.
def test_each_path_of_a_patch_is_approved_as_an_edit() -> Result[Void]
  dir = try fresh()
  rules = try Approval.parse_rules(["edit_file(*.txt)", "apply_patch(*)"], ["read_file(.env)"])
  ctx = try Tools.context(dir, ->(_n: String) { error("unset") }, rules)
  add = ->(path: String) { input("*** Begin Patch\n*** Add File: #{path}\n+x\n*** End Patch") }
  try Test.eq(Tools.verdict(ctx, "apply_patch", add.call("a.txt")), Tools.Verdict.Allow)
  try Test.eq(Tools.verdict(ctx, "apply_patch", add.call(".env")), Tools.Verdict.Deny)
  try Test.eq(Tools.verdict(ctx, "apply_patch", add.call(".git/config")), Tools.Verdict.Ask)
  try Test.eq(Tools.verdict(ctx, "apply_patch", add.call("../out.txt")), Tools.Verdict.Deny)
  asked = Tools.verdict(ctx.with(rules: Tools.Rules(allow: [], deny: [])), "apply_patch", add.call("a.txt"))
  _ = Path.remove(dir)
  Test.eq(asked, Tools.Verdict.Ask)
end

# An added file and a move target are writes, a deleted file asks unless an `apply_patch` rule allows it.
def test_writes_and_deletes_follow_their_own_rules() -> Result[Void]
  dir = try fresh()
  try File.write_text("#{dir}/a.txt", "one\n")
  edits = try Approval.parse_rules(["edit_file(*)", "write_file(*)"], ["write_file(secret*)"])
  ctx = try Tools.context(dir, ->(_n: String) { error("unset") }, edits)
  patches = [
    "*** Add File: secret.txt\n+x",
    "*** Update File: a.txt\n*** Move to: secret.txt\n-one\n+ONE",
    "*** Delete File: a.txt",
    "*** Add File: b.txt\n+x",
    "*** Update File: a.txt\n-one\n+ONE",
  ]

  verdicts = patches.map { |p| Tools.verdict(ctx, "apply_patch", input("*** Begin Patch\n#{p}\n*** End Patch")) }
  patching = ctx.with(rules: try Approval.parse_rules(["apply_patch(*.txt)"], []))
  removed = Tools.verdict(patching, "apply_patch", input("*** Begin Patch\n*** Delete File: a.txt\n*** End Patch"))
  _ = Path.remove(dir)
  Test.eq(
    verdicts.push(removed),
    [
      Tools.Verdict.Deny, Tools.Verdict.Deny, Tools.Verdict.Ask, Tools.Verdict.Allow, Tools.Verdict.Allow,
      Tools.Verdict.Allow,
    ],
  )
end

def update(path: String, body: String) -> String = "*** Begin Patch\n*** Update File: #{path}\n#{body}\n*** End Patch"

def plain(dir: String) -> Result[Tools.Context]
  Tools.context(dir, ->(_n: String) { error("unset") }, Tools.Rules(allow: [], deny: []))
end

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
