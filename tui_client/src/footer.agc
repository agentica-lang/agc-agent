## The two rows under the editor, as pi draws them: where the session is (its folder, the git branch and its first
## message), then the status (what the client waits for, the key hints that fit), the tokens and cost of the last
## model call, and the model with its thinking level on the right. Pure.

import Protocol from "pkg/protocol/protocol"
import Width from "width"

## The characters of the first message that name the session.
TITLE_CHARS = 40

## Where the session is: `cwd` with `home` as `~`, the branch in parentheses and the session's first message.
def place(cwd: String, home: String, branch: String, title: String, width: Int) -> String
  parts = [short_path(cwd, home)]
  if not branch.empty?
    parts = ["#{parts[0]} (#{branch})"]
  end

  name = title.split("\n")[0].strip
  if name.length > TITLE_CHARS
    name = "#{name.slice(0, TITLE_CHARS - 1)}…"
  end

  if not name.empty?
    parts = parts.push(name)
  end

  padded(" #{parts.join(" · ")}", width)
end

## The status row: `state` (as `ready`), then the counts of `usage`, then the `hints` that fit before `right`, which
## ends the row.
def status(
  state: List[String],
  usage: Optional[Protocol.Usage],
  hints: List[String],
  right: String,
  width: Int,
) -> String
  parts = state
  for used in option_list(usage)
    parts = parts.push(counts(used))
  end

  text = " #{parts.join(" · ")}"
  room = width - Width.text(right) - 2
  for hint in hints
    more = "#{text} · #{hint}"
    if text == " "
      more = " #{hint}"
    end

    break if Width.text(more) > room

    text = more
  end

  return padded(text, width) if right.empty? or Width.text(text) + Width.text(right) + 2 > width

  text + " " * (width - Width.text(text) - Width.text(right) - 1) + right + " "
end

## `↑input ↓output`, the cache read and the part of the prompt it was, the session's cost and the context as a part
## of the window (or in tokens while the window is not known).
def counts(usage: Protocol.Usage) -> String
  parts = ["↑#{tokens(usage.input)}", "↓#{tokens(usage.output)}"]
  if usage.cache_read > 0
    parts = parts.push("R#{tokens(usage.cache_read)}")
    if usage.context > 0
      parts = parts.push("#{usage.cache_read * 100 / usage.context}% cached")
    end
  end

  for cost in option_list(usage.session_cost)
    parts = parts.push(money(cost))
  end

  case usage.window
    some(window) if window > 0 -> parts.push("#{tenths(usage.context * 1000 / window)}%/#{tokens(window)}").join(" ")
    _ -> parts.push("#{tokens(usage.context)} ctx").join(" ")
  end
end

## A count of tokens as `950`, `1.2k`, `12k` or `1.2M`.
def tokens(count: Int) -> String
  return count.to_s if count < 1000
  return "#{tenths(count / 100)}k" if count < 10_000
  return "#{(count + 500) / 1000}k" if count < 1_000_000

  "#{tenths(count / 100_000)}M"
end

## Dollars with three decimals: `$0.012`.
def money(usd: Float) -> String
  millis = (usd * 1000.0).round
  "$#{millis / 1000}.#{(millis % 1000 + 1000).to_s.slice(1, 3)}"
end

## `provider/model` as `(provider) model`, with the thinking level after it when one is set.
def model(serving: String, level: Optional[String]) -> String
  shown = case serving.index_of("/")
    some(at) -> "(#{serving.slice(0, at)}) #{serving.slice(at + 1, serving.length - at - 1)}"
    none -> serving
  end

  for name in option_list(level)
    return "#{shown} · #{name}"
  end

  shown
end

private

def short_path(cwd: String, home: String) -> String
  return "~" if not home.empty? and cwd == home
  return "~#{cwd.slice(home.length, cwd.length - home.length)}" if not home.empty? and cwd.start_with?("#{home}/")

  cwd
end

# `tenths` of a whole as `1.5`; `15.0` of 150.
def tenths(count: Int) -> String = "#{count / 10}.#{count % 10}"

def padded(text: String, width: Int) -> String
  cut = Width.cut(text, width)[0]
  cut + " " * [width - Width.text(cut), 0].max.unwrap!
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
