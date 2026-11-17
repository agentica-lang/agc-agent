## The two rows under the editor: where the session is (its folder, the git branch and its first message), then the
## status (what the client waits for, the key hints that fit), the tokens of the last model call and the session's
## cost, and the model with its thinking level on the right. Pure.

import Protocol from "pkg/protocol/protocol"
import Width from "width"

## The characters of the first message that name the session.
TITLE_CHARS = 40
MAX_USD = 1_000_000.0

## Where the session is: `cwd` with `home` as `~`, the branch in parentheses and `title`, one line.
def place(cwd: String, home: String, branch: String, title: String, width: Int) -> String
  parts = [short_path(cwd, home)]
  if not branch.empty?
    parts = ["#{parts[0]} (#{branch})"]
  end

  name = title.strip
  if name.length > TITLE_CHARS
    name = "#{name.slice(0, TITLE_CHARS - 1)}…"
  end

  if not name.empty?
    parts = parts.push(name)
  end

  padded(" #{parts.join(" · ")}", width)
end

## The status row: `state` (as `ready`), the counts of `usage`, the `hints` that fit, and `right` (the model) at its
## end, two cells after them. When the row is too narrow, the counts lose the part cached, then the window, then the
## cache read, and then `right` is cut, or left out when fewer than 2 cells are left for it.
def status(
  state: List[String],
  usage: Optional[Protocol.Usage],
  hints: List[String],
  right: String,
  width: Int,
) -> String
  room = width - Width.text(right) - 3
  text = left(state, usage, 0)
  for detail in 1..MOST_DROPPED
    break if Width.text(text) <= room

    text = left(state, usage, detail)
  end

  model = right
  if Width.text(text) > room
    model = cut(right, width - Width.text(text) - 3)
  end

  room = width - Width.text(model) - 3
  for hint in hints
    more = "#{text} · #{hint}"
    if text == " "
      more = " #{hint}"
    end

    break if Width.text(more) > room

    text = more
  end

  return padded(text, width) if model.empty?

  text + " " * (width - Width.text(text) - Width.text(model) - 1) + model + " "
end

## The last call: `↑` its whole prompt (cached included), `↓` its output, `R` the prompt read from the cache and the
## part of the prompt it was; then the session's cost, and the prompt as a part of the window (in tokens while the
## window is not known). Each `detail` drops one more part: the part cached, then the window, then the cache read.
def counts(usage: Protocol.Usage, detail: Int = 0) -> String
  parts = ["↑#{tokens(usage.context)}", "↓#{tokens(usage.call_output.unwrap_or(usage.output))}"]
  if usage.cache_read > 0 and detail < 3
    parts = parts.push("R#{tokens(usage.cache_read)}")
    if usage.context > 0 and detail < 1
      parts = parts.push("#{usage.cache_read * 100 / usage.context}% cached")
    end
  end

  for cost in option_list(usage.session_cost)
    parts = parts.push(money(cost))
  end

  return parts.join(" ") if detail >= 2

  case usage.window
    some(window) if window > 0 -> parts.push("#{tenths(usage.context * 1000 / window)}%/#{tokens(window)}").join(" ")
    _ -> parts.push("#{tokens(usage.context)} ctx").join(" ")
  end
end

## A count of tokens as `950`, `1.2k`, `12k` or `1.2M`.
def tokens(count: Int) -> String
  return count.to_s if count < 1000
  return "#{tenths((count + 50) / 100)}k" if count < 9950
  return "#{(count + 500) / 1000}k" if count < 999_500

  "#{tenths((count + 50_000) / 100_000)}M"
end

## Dollars with three decimals (`$0.012`), `<$0.001` for less, and at most `$1000000.000`.
def money(usd: Float) -> String
  return "$0.000" if not (usd > 0.0)
  return "<$0.001" if usd < 0.0005

  millis = ([usd, MAX_USD].min.unwrap! * 1000.0).round
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

# How many parts `counts` drops at most.
MOST_DROPPED = 3

def left(state: List[String], usage: Optional[Protocol.Usage], detail: Int) -> String
  " #{(state + option_list(usage).map { |u| counts(u, detail) }).join(" · ")}"
end

# `text` in `cells` cells at most, its end replaced by `…` when cut; "" when there is no room.
def cut(text: String, cells: Int) -> String
  return text if Width.text(text) <= cells
  return "" if cells < 2

  "#{Width.cut(text, cells - 1)[0]}…"
end

def short_path(cwd: String, given: String) -> String
  home = given
  while home.end_with?("/")
    home = home.slice(0, home.length - 1)
  end

  return cwd if home.empty?
  return "~" if cwd == home or cwd == "#{home}/"
  return "~#{cwd.slice(home.length, cwd.length - home.length)}" if cwd.start_with?("#{home}/")

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
