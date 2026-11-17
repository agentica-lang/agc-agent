import Git from "../src/git"

# The branch comes from the first line of `.git/HEAD` of the checkout a folder is in, from a folder under it too; a
# worktree's `.git` file points to its HEAD; a detached head is its short commit; another ref is named whole; outside
# a checkout, and for an empty, short or long HEAD or one that is not a file, there is none.
def test_the_branch_of_a_checkout_a_worktree_and_a_detached_head() -> Result[Void]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/tui-git-#{Random.int(0, 999999999)}"
  result = branches(dir)
  _ = Path.remove(dir)
  result
end

def branches(dir: String) -> Result[Void]
  try Dir.mkdir("#{dir}/repo/.git/worktrees/wt")
  try Dir.mkdir("#{dir}/repo/src/deep")
  try Dir.mkdir("#{dir}/wt")
  try Dir.mkdir("#{dir}/other-ref/.git")
  try Dir.mkdir("#{dir}/none")
  for sub in ["empty", "short", "junk", "folder/.git/HEAD", "long"]
    try Dir.mkdir("#{dir}/#{sub}/.git")
  end

  try File.write_text("#{dir}/empty/.git/HEAD", "")
  try File.write_text("#{dir}/short/.git/HEAD", "abc\n")
  try File.write_text("#{dir}/junk/.git/HEAD", "ref: refs/heads/main\n#{String.from_code(27)}[31mred\n")
  try File.write_text("#{dir}/long/.git/HEAD", "ref: refs/heads/#{"b" * 300}\n")
  try File.write_text("#{dir}/repo/.git/HEAD", "ref: refs/heads/feat/footer\n")
  try File.write_text("#{dir}/repo/.git/worktrees/wt/HEAD", "0123456789abcdef0123456789abcdef01234567\n")
  try File.write_text("#{dir}/wt/.git", "gitdir: ../repo/.git/worktrees/wt\n")
  try File.write_text("#{dir}/other-ref/.git/HEAD", "ref: refs/remotes/origin/main\n")
  found = ["repo", "repo/src/deep", "wt", "other-ref", "none", "empty", "short", "junk", "folder"].map { |sub|
    Git.branch("#{dir}/#{sub}")
  }

  try Test.eq(found, ["feat/footer", "feat/footer", "0123456", "refs/remotes/origin/main", "", "", "", "main", ""])
  Test.eq(Git.branch("#{dir}/long"), "b" * 256)
end
