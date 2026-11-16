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
