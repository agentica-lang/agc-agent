import Git from "../src/git"

# The branch comes from `.git/HEAD` of the checkout a folder is in, from a folder under it too; a worktree's `.git`
# file points to its HEAD; a detached head is its short commit; outside a checkout there is none.
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
  try Dir.mkdir("#{dir}/bare/.git")
  try Dir.mkdir("#{dir}/none")
  try File.write_text("#{dir}/repo/.git/HEAD", "ref: refs/heads/feat/footer\n")
  try File.write_text("#{dir}/repo/.git/worktrees/wt/HEAD", "0123456789abcdef0123456789abcdef01234567\n")
  try File.write_text("#{dir}/wt/.git", "gitdir: ../repo/.git/worktrees/wt\n")
  try File.write_text("#{dir}/bare/.git/HEAD", "ref: refs/remotes/origin/main\n")
  found = ["repo", "repo/src/deep", "wt", "bare", "none"].map { |sub| Git.branch("#{dir}/#{sub}") }
  Test.eq(found, ["feat/footer", "feat/footer", "0123456", "refs/remotes/origin/main", ""])
end
