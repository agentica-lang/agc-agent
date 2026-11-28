## Managed Git worktrees for subagents, and the explicit working folders they may name instead.
##
## A child works in the parent's folder unless its task names `cwd` (an existing folder) or `worktree` (a fresh Git
## worktree on `base_ref`, else on the parent's own commit). Either choice never widens what the child may do: a
## confined parent keeps its folder, and a folder under no trusted folder never moves under one, since the move would
## load that folder's skills, commands and project profile. A worktree isolates the Git changes, not the operating
## system access: the child's commands run as the server's user and reach what that user reaches.
##
## The worktree lives under `.finn/worktrees` of the repository the parent works in, on a branch `finn/SLUG` (with a
## number while it is taken), one per writer. Allocation is atomic against races: the branch and the directory are
## checked before `git worktree add` runs, and the loser of a race takes the next number. A rejected folder or ref
## changes nothing, so nothing is left behind; a `worktree add` that fails removes only the directory it started when
## nothing else claims it. Once a child's turn ran, nothing removes its worktree: no stop, failure, restart or delete
## merges or deletes unmerged work. Removing one is explicit and by hand: `git worktree remove PATH` (which refuses a
## dirty worktree) once its work is merged or gone, then `git branch -d BRANCH`.

import Protocol from "pkg/protocol/protocol"
import Sandbox from "sandbox"
import Shell from "shell"
import Spec from "spec"

## How long one Git command may take; every Git call runs with it, in its own process group, and is killed past it.
GIT_MS = 20000
## How many branch and directory numbers allocation tries before it gives up.
MAX_TRIES = 100
## The longest `base_ref` allocation resolves.
MAX_REF = 256
## What `git worktree list --porcelain` prints before a worktree's path.
LIST_PREFIX = "worktree "
## Where managed worktrees live, under the repository's top folder.
WORKTREES_DIR = ".finn/worktrees"

## Where the child works: its folder, and the branch when it is a managed worktree.
struct Placed
  root: String
  branch: Optional[String] = none
end

## Where the child of `parent_id` works: the parent's folder, `cwd` when given, or a managed worktree (`worktree`,
## never both). `trusted_dirs` are the workspace's trusted folders, `parent_confine` whether the parent's file tools
## stay in its folder, and `env` the server's environment for the Git calls.
def resolve_child(
  trusted_dirs: List[String],
  parent_root: String,
  parent_confine: Bool,
  parent_id: String,
  cwd: Optional[String],
  worktree: Optional[Spec.Worktree],
  env: Fn[String, Result[String]],
) -> Result[Placed]
  for dir in option_list(cwd)
    for _ in option_list(worktree)
      return error("a subagent takes either `cwd` or `worktree`, not both", kind: Protocol.KIND_INVALID)
    end

    return explicit_child(trusted_dirs, parent_root, parent_confine, dir)
  end

  for asked in option_list(worktree)
    return allocate(trusted_dirs, parent_root, parent_confine, parent_id, asked.base_ref, env)
  end

  ok(Placed(root: parent_root))
end

## Whether `ref` names a commit allocation may start a worktree on: a branch, a tag, a commit or `HEAD`, never empty,
## a flag, a traversal or a shell trick. Only Git itself resolves it; this only rejects what is malformed.
def valid_ref?(ref: String) -> Bool
  return false if ref.empty? or ref.length > MAX_REF
  return false if ref.start_with?("-") or ref.start_with?("/") or ref.start_with?(".")
  return false if ref.split("").any? { |c| not ref_char?(c) }
  return false if ref.include?("..") or ref.include?("@{")
  return false if ref.end_with?("/") or ref.end_with?(".lock")

  true
end

## The branch the worktree at `root` is on, none when it names none (a detached checkout).
def branch_of(root: String, env: Fn[String, Result[String]]) -> Result[String]
  branch = try git(root, ["rev-parse", "--abbrev-ref", "HEAD"], env)
  return error("the worktree at #{root} is on no branch") if branch == "HEAD"

  ok(branch)
end

## Removes the managed worktree at `root` with `branch`, but only when it is safe: a worktree Git refuses (dirty or
## with untracked files) stays, a directory Git does not list as a worktree stays unless it holds nothing but the
## checkout, and the branch stays when it is not fully merged. Never fails: rollback is best-effort.
def release(root: String, branch: String, env: Fn[String, Result[String]]) -> Void
  found = git(root, ["rev-parse", "--show-toplevel"], env)
  return if not found.ok?

  toplevel = found.unwrap_or("")

  worktrees = git(toplevel, ["worktree", "list", "--porcelain"], env).unwrap_or("")
  if worktrees.split("\n").any? { |line| line == "#{LIST_PREFIX}#{root}" }
    if git(toplevel, ["worktree", "remove", root], env).ok?
      _ = git(toplevel, ["branch", "-d", branch], env)
    end

    return
  end

  if File.lstat(root).ok? and inside_base?(toplevel, root) and checkout_only?(root)
    _ = Path.remove(root)
  end
end

private

## `dir` as a child folder: an existing folder, inside the confined parent and never newly trusted.
def explicit_child(
  trusted_dirs: List[String],
  parent_root: String,
  parent_confine: Bool,
  dir: String,
) -> Result[Placed]
  return invalid("empty `cwd`") if dir == ""
  return invalid("`cwd` has a control character") if control?(dir)

  opened = case Sandbox.open(dir)
    ok(found) -> ok(found)
    error(e) -> invalid("cannot use `cwd` #{dir.inspect}: #{e.message}")
  end

  root = try opened

  if parent_confine and not Sandbox.inside?(parent_root, root)
    return invalid("`cwd` #{root} is outside the confined session folder")
  end

  if Sandbox.trusted?(trusted_dirs, root) and not Sandbox.trusted?(trusted_dirs, parent_root)
    return invalid("`cwd` #{root} is trusted and the session folder is not")
  end

  ok(Placed(root: root))
end

## A fresh worktree of the repository `parent_root` works in, on `base_ref` (the parent's own commit when none): a
## distinct branch and directory per writer, returned through the child's folder.
def allocate(
  trusted_dirs: List[String],
  parent_root: String,
  parent_confine: Bool,
  parent_id: String,
  base_ref: Optional[String],
  env: Fn[String, Result[String]],
) -> Result[Placed]
  for ref in option_list(base_ref)
    return invalid("`base_ref` #{ref.inspect} is not a branch, tag or commit") if not valid_ref?(ref)
  end

  shown = case git(parent_root, ["rev-parse", "--show-toplevel"], env)
    ok(top) -> ok(top)
    error(_) -> invalid("the session folder is in no Git repository, so no worktree starts there")
  end

  top = try shown
  canonical = case Path.real(top)
    ok(real) -> ok(real)
    error(e) -> invalid("cannot use the repository at #{top}: #{e.message}")
  end

  toplevel = try canonical

  return invalid("a worktree leaves the confined session folder") if parent_confine

  if Sandbox.trusted?(trusted_dirs, base_of(toplevel)) and not Sandbox.trusted?(trusted_dirs, parent_root)
    return invalid("the repository #{toplevel} is trusted and the session folder is not")
  end

  commit = try base_commit(parent_root, base_ref, env)
  root = try worktree_root(toplevel)
  slug = slug_of(parent_id)
  tried = 0
  while tried < MAX_TRIES
    suffix = ""
    if tried > 0
      suffix = "-#{tried}"
    end

    branch = "finn/#{slug}#{suffix}"
    path = "#{root}/#{slug}#{suffix}"
    if not branch_taken?(toplevel, branch, env) and not File.lstat(path).ok?
      case git(toplevel, ["worktree", "add", "-b", branch, path, commit], env)
        ok(_) -> return ok(Placed(root: try verified(toplevel, path), branch: some(branch)))
        error(e) if taken_message?(e.message) -> nil
        error(e) ->
          rollback(toplevel, path, env)
          return error(e)
      end
    end

    tried = tried + 1
  end

  invalid("no free worktree directory under #{root}")
end

## The commit `base_ref` names in `dir` (the parent's own commit when none).
def base_commit(dir: String, base_ref: Optional[String], env: Fn[String, Result[String]]) -> Result[String]
  for ref in option_list(base_ref)
    resolved = case git(dir, ["rev-parse", "--verify", "#{ref}^{commit}"], env)
      ok(found) -> ok(found)
      error(_) -> invalid("unknown ref #{ref.inspect}")
    end

    return check_commit(ref, try resolved)
  end

  head = case git(dir, ["rev-parse", "--verify", "HEAD^{commit}"], env)
    ok(found) -> ok(found)
    error(_) -> invalid("the repository has no commit to start a worktree on")
  end

  check_commit("HEAD", try head)
end

## Whether `commit` is the commit `ref` resolved to.
def check_commit(ref: String, commit: String) -> Result[String]
  return ok(commit) if commit.length == 40 and commit.split("").all? { |c| hex?(c) }

  invalid("ref #{ref.inspect} resolved to #{commit.inspect}, not a commit")
end

## The folder managed worktrees of `toplevel` live in, made when missing: no link on the way out of the repository.
def worktree_root(toplevel: String) -> Result[String]
  for part in [".finn", WORKTREES_DIR]
    path = "#{toplevel}/#{part}"
    if File.lstat(path).ok?
      return invalid("#{path} is a link, not a folder") if linked?(path)

      info = case File.stat(path)
        ok(found) -> ok(found)
        error(e) -> invalid("cannot use #{path}: #{e.message}")
      end

      return invalid("#{path} is not a folder") if (try info).kind != "directory"
    else
      made = case Dir.mkdir(path)
        ok(_) -> ok()
        error(e) -> invalid("cannot make #{path}: #{e.message}")
      end

      try made
    end
  end

  resolved = case Path.real(base_of(toplevel))
    ok(found) -> ok(found)
    error(e) -> invalid("cannot use #{base_of(toplevel)}: #{e.message}")
  end

  real = try resolved

  return invalid("#{base_of(toplevel)} escapes the repository") if real != toplevel + "/#{WORKTREES_DIR}"

  ok(real)
end

def base_of(toplevel: String) -> String = "#{toplevel}/#{WORKTREES_DIR}"

## Whether `path` names a link.
def linked?(path: String) -> Bool
  case File.lstat(path)
    ok(found) -> found.kind == "link"
    error(_) -> false
  end
end

## Whether the branch `branch` already exists in `dir`.
def branch_taken?(dir: String, branch: String, env: Fn[String, Result[String]]) -> Bool
  git(dir, ["rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"], env).ok?
end

## Whether the failed `worktree add` lost a race: its branch or directory was taken between the check and the run.
def taken_message?(message: String) -> Bool = message.include?("already exists") or message.include?("already used")

## The worktree Git made at `path`: its real path, inside `toplevel`.
def verified(toplevel: String, path: String) -> Result[String]
  found = case Path.real(path)
    ok(real) -> ok(real)
    error(e) -> invalid("cannot use the worktree at #{path}: #{e.message}")
  end

  real = try found

  return invalid("the worktree at #{path} escapes the repository") if not Sandbox.inside?(toplevel, real)

  ok(real)
end

## Cleans a failed `worktree add` at `path`: only the directory it started, only when Git lists no worktree there.
def rollback(toplevel: String, path: String, env: Fn[String, Result[String]]) -> Void
  worktrees = git(toplevel, ["worktree", "list", "--porcelain"], env).unwrap_or("")
  return if worktrees.split("\n").any? { |line| line == "#{LIST_PREFIX}#{path}" }
  return if not File.lstat(path).ok?
  return if not checkout_only?(path)

  _ = Path.remove(path)
end

## Whether `path` holds nothing but the checkout Git started (its `.git` file) or nothing at all.
def checkout_only?(path: String) -> Bool
  case Dir.list(path)
    ok(names) -> names.all? { |name| name == ".git" }
    error(_) -> false
  end
end

## Whether `root` is the worktrees folder, which is `toplevel` or below it.
def inside_base?(toplevel: String, root: String) -> Bool = root == toplevel or Sandbox.inside?(toplevel, root)

## The slug a branch and directory of `id` are made of: letters, digits and `_` stay, `-` stays, the rest is `-`.
def slug_of(id: String) -> String
  slug = id.split("").map { |c| slug_char(c) }.join("")
  return slug.slice(0, 40) if slug.length > 40

  slug
end

def slug_char(c: String) -> String
  return c if ref_plain?(c) or c == "_"

  "-"
end

## Whether `c` is a letter or a digit.
def ref_plain?(c: String) -> Bool
  code = c.code
  return true if code >= 48 and code <= 57
  return true if code >= 65 and code <= 90
  return true if code >= 97 and code <= 122

  false
end

## Whether `c` may be in a ref: a letter, a digit, `_`, `-`, `.` or `/`.
def ref_char?(c: String) -> Bool
  return true if ref_plain?(c)

  c == "_" or c == "-" or c == "." or c == "/"
end

## Whether `c` is a hexadecimal digit.
def hex?(c: String) -> Bool
  code = c.code
  return true if code >= 48 and code <= 57
  return true if code >= 65 and code <= 70
  return true if code >= 97 and code <= 102

  false
end

## Whether `text` holds a control character.
def control?(text: String) -> Bool = text.split("").any? { |c| c.code < 32 or c.code == 127 }

## One Git command in `dir`: its standard output without the end of line, or its standard error.
def git(dir: String, args: List[String], env: Fn[String, Result[String]]) -> Result[String]
  options = Process.Options(chdir: dir, pgroup: true, timeout_ms: GIT_MS)
  words = ["-i", "--"] + Shell.environment(env) + ["GIT_TERMINAL_PROMPT=0", "git"] + args
  process = try Process.spawn_captured("/usr/bin/env", words, options)
  _ = Process.close_stdin(process, 1000)
  result = finish(process, GIT_MS)
  Process.close(process)
  result
end

def finish(process: Process, timeout_ms: Int) -> Result[String]
  case Process.output(process, timeout_ms)
    ok(out) -> report(out, Process.wait(process, 5000))
    error(_) ->
      _ = Process.signal_group(process, System.Signal.Kill)
      partial = Process.read_available(process, 1000).unwrap_or("")
      error("git timed out after #{timeout_ms} ms and was killed\n#{partial}")
  end
end

def report(out: Process.Output, exit: Result[Int]) -> Result[String]
  case exit
    ok(0) -> ok(out.stdout.strip)
    ok(_) -> error(out.stderr.strip)
    error(_) if out.stderr.strip != "" -> error(out.stderr.strip)
    error(e) -> error("git did not exit: #{e.message}")
  end
end

def invalid[T](message: String) -> Result[T] = error(message, kind: Protocol.KIND_INVALID)

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
