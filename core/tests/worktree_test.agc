## Managed Git worktrees and explicit working folders of subagents (`Core.Host.create` with `cwd` or `worktree`):
## two writers get distinct branches and directories and leave the parent checkout clean, rejected folders and refs
## leave no partial allocation, and stopping, deleting or restarting the server keeps the writers' work. The
## repositories are disposable local ones and the model is faked, so nothing reaches the network. The `agent` tool
## itself names the worktree path and branch of each task in its answers.

import Agents from "../src/ext/agents"
import Protocol from "pkg/protocol/protocol"
import Core from "../core"
import Sandbox from "../src/tools/sandbox"
import Spec from "../src/tools/spec"
import Worktree from "../src/tools/worktree"
import H from "support/harness"

ANSWER = "Hello! It's a pleasure to meet you."

# Two writers get distinct branches and directories, and the parent checkout stays clean. Stopping and deleting the
# children, and restarting the server, keep their work.
def test_two_writers_get_distinct_branches_and_keep_the_parent_clean() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "text.sse", "text.sse"]
  setup = trusted_setup(replies, some(with_spawn(calls)))
  H.using(setup) do |h|
    try init_repo(h.work)
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    host = try host_of(calls)
    one = try host.create.call(Core.NewChild(worktree: some(Spec.Worktree())))
    two = try host.create.call(Core.NewChild(worktree: some(Spec.Worktree())))
    first = (try host.snapshot.call(one)).cwd
    second = (try host.snapshot.call(two)).cwd
    try Test.assert(first != second, "the writers share #{first}")
    for root in [first, second]
      here = "#{h.work}/.finn/worktrees/"
      try Test.assert(root.start_with?(here), "the worktree is not under the repository: #{root}")
    end

    branches = try git(h.work, ["branch", "--list", "finn/*"])
    lines = branches.split("\n").select { |line| not line.strip.empty? }
    try Test.eq(lines.size, 2)
    try Test.assert(lines.all? { |line| line.include?("finn/") }, "no finn branches: #{branches}")
    listed = try git(h.work, ["worktree", "list", "--porcelain"])
    try Test.assert(listed.include?(first) and listed.include?(second), "the worktrees are not listed: #{listed}")
    first_sub = try H.subscribe(h, one)
    second_sub = try H.subscribe(h, two)
    _ = try host.send.call(one, "Hi.")
    _ = try host.send.call(two, "Hi.")
    first_sub = try H.until(first_sub, Protocol.EventKind.TurnFinished)
    H.close(first_sub)
    second_sub = try H.until(second_sub, Protocol.EventKind.TurnFinished)
    H.close(second_sub)
    for id in [one, two]
      texts = H.said((try H.session(h, id)).history).map { |m| m.text }
      try Test.assert(texts.include?(ANSWER), "the writer at #{(try host.snapshot.call(id)).cwd} gave no answer")
    end

    try File.write_text("#{first}/writer.txt", "one\n")
    try File.write_text("#{second}/writer.txt", "two\n")
    try Test.eq(try host.stop.call(one), false)
    try host.delete.call(one)
    try host.delete.call(two)
    try Test.eq(try File.read_text("#{first}/writer.txt"), "one\n")
    try Test.eq(try File.read_text("#{second}/writer.txt"), "two\n")
    kept = try git(h.work, ["worktree", "list", "--porcelain"])
    try Test.assert(kept.include?(first) and kept.include?(second), "a delete removed a worktree: #{kept}")
    try Test.eq(try File.read_text("#{h.work}/base.txt"), "base\n")
    H.restarted(h, setup, "") do |r|
      again = try git(r.work, ["worktree", "list", "--porcelain"])
      try Test.assert(again.include?(first) and again.include?(second), "a restart removed a worktree: #{again}")
      try Test.eq(try File.read_text("#{first}/writer.txt"), "one\n")
      Test.eq(try File.read_text("#{second}/writer.txt"), "two\n")
    end
  end
end

# Rejected folders and refs fail the child and leave no worktree, branch or directory behind. A confined session
# keeps its folder, an untrusted one never moves under a trusted folder, and nothing starts outside a repository.
def test_rejected_folders_and_refs_leave_no_partial_allocation() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse"]
  setup = trusted_setup(replies, some(with_spawn(calls)))
  H.using(setup) do |h|
    try init_repo(h.work)
    try Dir.mkdir("#{h.work}/sub")
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    host = try host_of(calls)
    before_branches = try git(h.work, ["branch", "--list"])
    before_trees = try git(h.work, ["worktree", "list", "--porcelain"])
    for ref in ["no-such-ref", "--help", "../escape", "a b", "", "main..other", "HEAD@{1}"]
      refused = host.create.call(Core.NewChild(worktree: some(Spec.Worktree(base_ref: some(ref)))))
      try refused_child(refused, "a worktree started on #{ref.inspect}")
    end

    for dir in ["#{h.work}/no-such-dir", "#{h.work}/base.txt", ""]
      refused = host.create.call(Core.NewChild(cwd: some(dir)))
      try refused_child(refused, "a child started in #{dir.inspect}")
    end

    both = host.create.call(Core.NewChild(cwd: some("#{h.work}/sub"), worktree: some(Spec.Worktree())))
    try refused_child(both, "a child started with both `cwd` and `worktree`")
    try Test.eq(try git(h.work, ["branch", "--list"]), before_branches)
    try Test.eq(try git(h.work, ["worktree", "list", "--porcelain"]), before_trees)
    try Test.assert(not File.lstat("#{h.work}/.finn").ok?, "a rejected child allocated #{h.work}/.finn")
    sub = try Path.real("#{h.work}/sub")
    try Test.eq((try host.snapshot.call(try host.create.call(Core.NewChild(cwd: some(sub))))).cwd, sub)
    missing = Worktree.resolve_child([], h.base, false, "s1", none, some(Spec.Worktree()), &env)
    try refused_child(missing, "a worktree started outside a repository")
    confined = Worktree.resolve_child([], h.work, true, "s1", some(h.base), none, &env)
    try refused_child(confined, "a confined child left its folder")
    confined_tree = Worktree.resolve_child([], h.work, true, "s1", none, some(Spec.Worktree()), &env)
    try refused_child(confined_tree, "a confined child took a worktree")
    trusted = Worktree.resolve_child(["#{h.work}/sub"], h.work, false, "s1", some("#{h.work}/sub"), none, &env)
    try refused_child(trusted, "an untrusted child moved under a trusted folder")
    Test.eq((try Worktree.resolve_child([], h.work, false, "s1", some(sub), none, &env)).root, sub)
  end
end

# The model names a worktree and a folder per task, and the answers carry their paths and branches while the parent
# checkout stays clean.
def test_agent_tasks_name_their_worktrees_and_folders() -> Result[Void]
  replies = ["agent_worktree.sse", "text.sse", "text.sse", "text.sse"]
  H.using(trusted_setup(replies, none)) do |h|
    try init_repo(h.work)
    try Dir.mkdir("#{h.work}/sub")
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    _ = try H.next_request(h)
    _ = try H.next_request(h)
    _ = try H.next_request(h)
    body = (try H.next_request(h)).body
    try Test.assert(body.include?("worktree: #{h.work}/.finn/worktrees/"), "no worktree path: #{body}")
    try Test.assert(body.include?("(branch finn/"), "no worktree branch: #{body}")
    try Test.assert(body.include?("cwd: #{h.work}/sub"), "no explicit folder: #{body}")
    try Test.assert(body.include?(ANSWER), "no answers: #{body}")
    tracked = try git(h.work, ["status", "--porcelain", "--untracked-files=no"])
    Test.assert(tracked.strip.empty?, "the parent checkout moved: #{tracked}")
  end
end

# An async start answers with the child's id, worktree path and branch on one line; the child keeps its worktree
# after its turn.
def test_an_async_start_names_the_worktree_in_its_id_line() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse", "text.sse"]
  setup = trusted_setup(replies, some(with_spawn(calls)))
  H.using(setup) do |h|
    try init_repo(h.work)
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    host = try host_of(calls)
    turns: ATS[String, String] = ATS.new()
    waits: ATS[String, Address[Agents.Heard]] = ATS.new()
    wakes: ATS[String, String] = ATS.new()
    names: ATS[String, String] = ATS.new()
    locks: ATS[String, Bool] = ATS.new()
    tools = Agents.tools(
      -> { [] },
      Agents.Limits(max: 0, timeout_ms: 0),
      turns,
      waits,
      wakes,
      names,
      locks,
      Agents.Saving(port: none, wanted: ATS.new()),
    )

    ctx = Spec.Context(
      root: h.work,
      env: ->(name: String) { H.fake_env(name) },
      host: some(host),
      session: some(parent),
    )

    line = try tools[0].run.call(
      ctx,
      try JSON.parse("{\"tasks\": [{\"prompt\": \"Say hi.\", \"worktree\": {}}], \"wait\": false}"),
    )

    try Test.assert(line.include?("worktree: #{h.work}/.finn/worktrees/"), "no worktree path: #{line}")
    try Test.assert(line.include?("(branch finn/"), "no worktree branch: #{line}")
    id = line.split(" ")[0]
    c = try H.subscribe(h, id)
    c = try H.until(c, Protocol.EventKind.TurnFinished)
    H.close(c)
    listed = try git(h.work, ["worktree", "list", "--porcelain"])
    Test.assert(listed.include?((try host.snapshot.call(id)).cwd), "the async child kept no worktree: #{listed}")
  end
end

# Only plain branches, tags, commits and HEAD start a worktree: flags, traversals, expansions and shell tricks do
# not, whatever Git itself would make of them.
def test_only_plain_refs_start_a_worktree() -> Result[Void]
  for ref in ["main", "HEAD", "v1.2.3", "feature/x-y_z", "0123456789abcdef0123456789abcdef01234567"]
    try Test.assert(Worktree.valid_ref?(ref), "#{ref.inspect} starts no worktree")
  end

  for ref in ["", "--help", "-x", "../escape", "a b", "a@{1}", "/abs", ".dot", "a..b", "x.lock", "a:b", "a~1", "a^"]
    try Test.assert(not Worktree.valid_ref?(ref), "#{ref.inspect} starts a worktree")
  end

  ok()
end

# A managed worktree starts only in an explicitly trusted repository: without trust the child fails and leaves no
# worktree, branch or directory behind.
def test_a_worktree_starts_only_in_a_trusted_repository() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse"]
  setup = H.Setup(replies: replies, registry: some(with_spawn(calls)), approvals: false)
  H.using(setup) do |h|
    try init_repo(h.work)
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    host = try host_of(calls)
    before_branches = try git(h.work, ["branch", "--list"])
    case host.create.call(Core.NewChild(worktree: some(Spec.Worktree())))
      ok(_) -> return error("a worktree started in a repository that is not trusted")
      error(e) -> try Test.assert(e.message.include?("not trusted"), "unexpected refusal: #{e.message}")
    end

    try Test.eq(try git(h.work, ["branch", "--list"]), before_branches)
    try Test.assert(not File.lstat("#{h.work}/.finn").ok?, "an untrusted child allocated #{h.work}/.finn")
    ok()
  end
end

# A confined parent keeps a confined child: the child inherits the parent's effective confinement at creation (a
# `PATCH` before the call counts, the server's default stays off), a relative `cwd` resolves against the parent's
# folder, and the child's file tools refuse a path outside its folder.
def test_a_confined_parent_keeps_a_confined_child() -> Result[Void]
  calls: Channel[Core.Call] = Channel.new(4)
  replies = ["spawn.sse", "text.sse"]
  setup = trusted_setup(replies, some(with_spawn(calls)))
  H.using(setup) do |h|
    try init_repo(h.work)
    try Dir.mkdir("#{h.work}/sub")
    parent = try H.new_session(h)
    a = try H.subscribe(h, parent)
    _ = try H.send(h, parent, "Go.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    host = try host_of(calls)
    free = try host.create.call(Core.NewChild(cwd: some("#{h.work}/sub")))
    try Test.eq((try host.snapshot.call(free)).confine, false)
    changed = try H.call(
      h,
      "PATCH",
      Protocol.session_path(parent),
      Protocol.encode_update_session(Protocol.UpdateSession(confine: some(true))),
      H.auth(h),
    )

    try Test.eq(changed.status, 200)
    child = try host.create.call(Core.NewChild(cwd: some("sub")))
    snapshot = try host.snapshot.call(child)
    try Test.eq(snapshot.cwd, try Path.real("#{h.work}/sub"))
    try Test.eq(snapshot.confine, true)
    outside = Sandbox.reach(snapshot.cwd, h.base, snapshot.confine)
    try Test.assert(not outside.ok?, "the confined child reaches #{h.base}")
    Test.eq((try host.snapshot.call(try host.create.call(Core.NewChild()))).confine, true)
  end
end

# A repository that defines an externally executing checkout filter allocates nothing: the refusal happens before any
# checkout runs, so no worktree, branch or directory is left behind. The driver value is inert (`cat`).
def test_a_checkout_filter_refuses_a_worktree_before_any_checkout_runs() -> Result[Void]
  H.using(H.Setup(replies: [])) do |h|
    try init_repo(h.work)
    try File.write_text("#{h.work}/note.inert-test", "plain\n")
    try File.write_text("#{h.work}/.gitattributes", "*.inert-test filter=inerttest\n")
    try git(h.work, ["add", ".gitattributes", "note.inert-test"])
    try git(h.work, ["-c", "commit.gpgsign=false", "commit", "-qm", "attributes"])
    try git(h.work, ["config", "filter.inerttest.smudge", "cat"])
    before_branches = try git(h.work, ["branch", "--list"])
    case Worktree.resolve_child([h.work], h.work, false, "s1", none, some(Spec.Worktree()), &env)
      ok(_) -> return error("a worktree started with a checkout filter defined")
      error(e) -> try Test.assert(e.message.include?("checkout filter"), "unexpected refusal: #{e.message}")
    end

    try Test.eq(try git(h.work, ["branch", "--list"]), before_branches)
    try Test.assert(not File.lstat("#{h.work}/.finn").ok?, "a refused filter allocated #{h.work}/.finn")
    ok()
  end
end

# When the Git configuration cannot be inspected, no worktree starts: the inspection failure refuses the allocation
# instead of reading an empty listing as clean, and leaves no worktree, branch or directory behind. The stub fails
# only `config --list` with an inert message; every other Git call runs the real binary.
def test_a_config_inspection_failure_refuses_a_worktree() -> Result[Void]
  H.using(H.Setup(replies: [])) do |h|
    try init_repo(h.work)
    stub = "#{h.work}/stub-bin"
    try Dir.mkdir(stub)
    script = "#{stub}/git"
    text = (
      "#!/bin/sh\n" +
      "saw_config=false\nsaw_list=false\n" +
      "for arg in \"$@\"; do\n" +
      "if [ \"$arg\" = \"config\" ]; then saw_config=true; fi\n" +
      "if [ \"$arg\" = \"--list\" ]; then saw_list=true; fi\n" +
      "done\n" +
      "if $saw_config && $saw_list; then\n" +
      "echo \"injected config inspection failure\" >&2\nexit 1\n" +
      "fi\n" +
      "exec /usr/bin/git \"$@\"\n"
    )

    try File.write_text(script, text)
    try Test.eq(try H.run("chmod", ["755", script]), 0)
    path = try System.env("PATH")
    before_branches = try git(h.work, ["branch", "--list"])
    stubbed = ->(name: String) { stub_env(stub, path, name) }
    case Worktree.resolve_child([h.work], h.work, false, "s1", none, some(Spec.Worktree()), stubbed)
      ok(_) -> return error("a worktree started when the Git configuration could not be inspected")
      error(e) -> try Test.assert(e.message.include?("cannot inspect"), "unexpected refusal: #{e.message}")
    end

    try Test.eq(try git(h.work, ["branch", "--list"]), before_branches)
    try Test.assert(not File.lstat("#{h.work}/.finn").ok?, "a refused inspection allocated #{h.work}/.finn")
    ok()
  end
end

# Ambient repository configuration never runs during allocation: hooks and the filesystem monitor stay disabled, so a
# repository that names them still allocates.
def test_ambient_git_configuration_never_runs_during_allocation() -> Result[Void]
  H.using(H.Setup(replies: [])) do |h|
    try init_repo(h.work)
    try Dir.mkdir("#{h.work}/hooks-dir")
    try git(h.work, ["config", "core.hooksPath", "#{h.work}/hooks-dir"])
    placed = try Worktree.resolve_child([h.work], h.work, false, "s1", none, some(Spec.Worktree()), &env)
    try Test.assert(File.lstat(placed.root).ok?, "no worktree directory: #{placed.root}")
    listed = try git(h.work, ["worktree", "list", "--porcelain"])
    try Test.assert(listed.include?(placed.root), "the worktree is not listed: #{listed}")
    ok()
  end
end

private

# A server setup whose work folder counts as trusted, so managed worktrees may start there.
def trusted_setup(replies: List[String], registry: Optional[Core.Registry]) -> H.Setup
  H.Setup(replies: replies, registry: registry, approvals: false, skills: true, trust: some(["work"]))
end

def with_spawn(calls: Channel[Core.Call]) -> Core.Registry = Core.registry() |> Core.add_tool(spawn_tool(calls))

def spawn_tool(calls: Channel[Core.Call]) -> Core.Tool
  Core.Tool(
    name: "spawn",
    description: "Gives the test the call.",
    input_schema: JSON.object({"type": JSON.from("object")}),
    asks: false,
    run: ->(call: Core.Call) {
      _ = calls.send(call, 1000)
      ok("ok")
    },
    target: ->(_call: Core.Call) { ok("") },
  )
end

def host_of(calls: Channel[Core.Call]) -> Result[Core.Host]
  call = try calls.recv(5000)
  call.host.to_result("the call has no host")
end

def refused_child[T](result: Result[T], complaint: String) -> Result[Void]
  case result
    ok(_) -> error(complaint)
    error(_) -> ok()
  end
end

def env(name: String) -> Result[String] = System.env(name)

def stub_env(stub: String, path: String, name: String) -> Result[String]
  return ok("#{stub}:#{path}") if name == "PATH"

  System.env(name)
end

def git(dir: String, args: List[String]) -> Result[String]
  options = Process.Options(chdir: dir, pgroup: true, timeout_ms: 10000)
  process = try Process.spawn_captured("/usr/bin/env", ["GIT_TERMINAL_PROMPT=0", "git"] + args, options)
  result = finish_git(process, args)
  Process.close(process)
  result
end

def finish_git(process: Process, args: List[String]) -> Result[String]
  case Process.output(process, 10000)
    ok(out) -> report_git(out, Process.wait(process, 5000), args)
    error(e) ->
      _ = Process.signal_group(process, System.Signal.Kill)
      error("git #{args.join(" ")}: #{e.message}")
  end
end

def report_git(out: Process.Output, exit: Result[Int], args: List[String]) -> Result[String]
  case exit
    ok(0) -> ok(out.stdout.strip)
    ok(status) -> error("git #{args.join(" ")}: exit #{status}\n#{out.stderr}")
    error(e) -> error("git #{args.join(" ")}: #{e.message}")
  end
end

def init_repo(dir: String) -> Result[Void]
  try git(dir, ["init", "-q"])
  try git(dir, ["config", "user.email", "test@example.com"])
  try git(dir, ["config", "user.name", "Test"])
  try File.write_text("#{dir}/base.txt", "base\n")
  try git(dir, ["add", "base.txt"])
  try git(dir, ["-c", "commit.gpgsign=false", "commit", "-qm", "base"])
  ok()
end
