## A session's tree as clients draw it: the user messages depth-first, a branch one step in, and the numbers `/tree N`
## and `/fork N` take (`N+` is after the answer of message N). Pure.

import Protocol from "pkg/protocol/protocol"
import Commands from "commands"

## A message of the tree and how far in it is drawn.
struct TreeRow
  node: Protocol.TreeNode
  depth: Int
end

## Depth-first, in the order the messages were sent; a message with more than one next message puts each a step in.
def tree_rows(tree: Protocol.SessionTree) -> List[TreeRow]
  children: Map[Int, List[Protocol.TreeNode]] = {}
  for node in tree.nodes
    parent = node.parent.unwrap_or(-1)
    children = children.put(parent, children.get(parent, []).push(node))
  end

  rows: List[TreeRow] = []
  stack = in_order(children.get(-1, []), 0)
  while not stack.empty?
    row = stack.last
    stack = stack.take(stack.size - 1)
    rows = rows.push(row)
    stack = stack + in_order(children.get(row.node.id, []), row.depth)
  end

  rows
end

## One numbered line per message, `*` on the branch the session is on, with the start of its answer.
def tree_listing(tree: Protocol.SessionTree) -> List[String]
  rows = tree_rows(tree)
  (1..rows.size).to_a.map do |n|
    row = rows[n - 1]
    mark = " "
    if row.node.active
      mark = "*"
    end

    "#{n}. #{"  " * row.depth}#{mark} #{clipped(row.node.text)}  -> #{clipped(row.node.answer)}"
  end
end

## The entry `N` (before message N) or `N+` (after its answer) names, by the numbers of `tree_listing`.
def tree_entry(tree: Protocol.SessionTree, choice: String) -> Result[Int]
  rows = tree_rows(tree)
  after = choice.end_with?("+")
  number = choice
  if after
    number = choice.slice(0, choice.length - 1)
  end

  case number.to_i
    ok(n) if n >= 1 and n <= rows.size and after -> ok(rows[n - 1].node.last)
    ok(n) if n >= 1 and n <= rows.size -> ok(rows[n - 1].node.id)
    _ -> error("no message #{choice}: /tree lists them", kind: Commands.KIND_COMMAND)
  end
end

private

CLIP_CHARS = 60

# The children to push on the stack, the first on top; a step in when there is more than one.
def in_order(nodes: List[Protocol.TreeNode], depth: Int) -> List[TreeRow]
  step = 0
  if nodes.size > 1
    step = 1
  end

  nodes.reverse.map { |node| TreeRow(node: node, depth: depth + step) }
end

def clipped(text: String) -> String
  line = Commands.printable(text.split("\n")[0])
  return line if line.length <= CLIP_CHARS

  "#{line.slice(0, CLIP_CHARS)}…"
end
