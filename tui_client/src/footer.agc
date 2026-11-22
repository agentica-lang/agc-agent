## The two rows under the editor: where the session is (its folder, the git branch and its first message), then the
## status (what the client waits for, the key hints that fit), the tokens of the last model call and the session's
## cost, and the model with its thinking level on the right. Pure.
##
## The status row is a list of named spans: one per segment (`state`, `usage`, `rate`, `hints`, `model`,
## `chatgpt.quota` and an extension's names) with the separators, the leading space and the padding as unnamed
## spans. The theme draws an unnamed span in `footer.status` and a named one in its `footer-status-<name>` entry
## when one names it, else in `footer.status`. `status` and `custom` are the joined texts of `status_spans` and
## `custom_spans`, so the widths, the order, the skips and the clipping are the same either way.

import Protocol from "pkg/protocol/protocol"
import Width from "width"

## The characters of the first message that name the session.
TITLE_CHARS = 40
MAX_USD = 1_000_000.0

## One piece of the status row: `name` is the segment (`state`, `usage`, `rate`, `hints`, `model`,
## `chatgpt.quota` or an extension's name), or "" for a separator, the leading space and the padding.
struct Span
  name: String
  text: String
end

## The values available to a custom status layout.
struct Values
  state: List[String]
  usage: Optional[Protocol.Usage]
  hints: List[String]
  model: String
  rate: String
  segments: List[Protocol.StatusSegment] = []
end

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

## The status row: `state` (as `ready`), the counts of `usage`, the `rate` of the model's output, the `quota`, the
## `hints` that fit, and `right` (the model) at its end, two cells after them. When the row is too narrow, the quota
## goes first, then the rate, then the counts lose the part cached, then the window, then the cache read, and then
## `right` is cut, or left out when fewer than 2 cells are left for it.
def status(
  state: List[String],
  usage: Optional[Protocol.Usage],
  hints: List[String],
  right: String,
  width: Int,
  rate: String = "",
  quota: String = "",
) -> String
  spans_text(status_spans(state, usage, hints, right, width, rate, quota))
end

## The same row as named spans, with the separators and the padding unnamed.
def status_spans(
  state: List[String],
  usage: Optional[Protocol.Usage],
  hints: List[String],
  right: String,
  width: Int,
  rate: String = "",
  quota: String = "",
) -> List[Span]
  room = width - Width.text(right) - 3
  current = left_spans(state, usage, rate, quota, 0)
  for d in 1..MOST_DROPPED
    break if spans_width(current) <= room

    current = left_spans(state, usage, rate, quota, d)
  end

  text_spans = current
  model = right
  if spans_width(text_spans) > room
    model = cut(right, width - spans_width(text_spans) - 3)
  end

  room = width - Width.text(model) - 3
  for hint in hints
    candidate = text_spans + [Span(name: "", text: " · "), Span(name: "hints", text: hint)]
    if spans_text(text_spans) == " "
      candidate = [Span(name: "", text: " "), Span(name: "hints", text: hint)]
    end

    break if spans_width(candidate) > room

    text_spans = candidate
  end

  return padded_spans(text_spans, width) if model.empty?

  filler = width - spans_width(text_spans) - Width.text(model) - 1
  text_spans + [Span(name: "", text: " " * filler), Span(name: "model", text: model), Span(name: "", text: " ")]
end

## The segments of a `status_line` layout. When the row is too narrow, whole segments go, from the end of the right side,
## then from the end of the left; the last one is cut.
def custom(layout: Protocol.StatusLine, values: Values, width: Int) -> String
  spans_text(custom_spans(layout, values, width))
end

## The same segments as named spans, with the separators and the padding unnamed.
def custom_spans(layout: Protocol.StatusLine, values: Values, width: Int) -> List[Span]
  left = component_lists(layout.left, values)
  right = component_lists(layout.right, values)
  while cells_of(left, right) > width and left.size + right.size > 1
    if right.empty?
      left = left.take(left.size - 1)
    else
      right = right.take(right.size - 1)
    end
  end

  if cells_of(left, right) > width
    flat = flatten_comps(left + right)
    return padded_spans([Span(name: "", text: " ")] + cut_spans(flat, width - 1), width)
  end

  joined = flatten_comps(left)
  return padded_spans([Span(name: "", text: " ")] + joined, width) if right.empty?

  shown = flatten_comps(right)
  filler = width - spans_width(joined) - spans_width(shown) - 2
  [Span(name: "", text: " ")] + joined + [Span(name: "", text: " " * filler)] + shown + [Span(name: "", text: " ")]
end

## The joined text of `spans`.
def spans_text(spans: List[Span]) -> String = spans.map { |span| span.text }.join("")

## How many columns the joined text of `spans` takes.
def spans_width(spans: List[Span]) -> Int = Width.text(spans_text(spans))

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

# How many parts the status row drops at most: the quota, the rate, then those of `counts`.
MOST_DROPPED = 5

def left_spans(
  state: List[String],
  usage: Optional[Protocol.Usage],
  rate: String,
  quota: String,
  detail: Int,
) -> List[Span]
  parts: List[Span] = []
  for item in state
    if not item.empty?
      parts = parts.push(Span(name: "state", text: item))
    end
  end

  for item in option_list(usage)
    text = counts(item, [detail - 2, 0].max.unwrap!)
    if not text.empty?
      parts = parts.push(Span(name: "usage", text: text))
    end
  end

  if detail < 2 and not rate.empty?
    parts = parts.push(Span(name: "rate", text: rate))
  end

  if detail == 0 and not quota.empty?
    parts = parts.push(Span(name: Protocol.QUOTA_SEGMENT, text: quota))
  end

  return [Span(name: "", text: " ")] if parts.empty?

  out: List[Span] = [Span(name: "", text: " "), parts[0]]
  for part in parts.drop(1)
    out = out.push(Span(name: "", text: " · "))
    out = out.push(part)
  end

  out
end

def component_lists(names: List[String], values: Values) -> List[List[Span]]
  out: List[List[Span]] = []
  for name in names
    spans = component_spans(name, values).select { |span| not span.text.empty? }
    if not spans.empty?
      out = out.push(spans)
    end
  end

  out
end

def component_spans(name: String, values: Values) -> List[Span]
  case name
    "state" -> values.state.map { |item| Span(name: "state", text: item) }
    "usage" -> option_list(values.usage).map { |usage| Span(name: "usage", text: counts(usage)) }
    "rate" ->
      if values.rate.empty?
        []
      else
        [Span(name: "rate", text: values.rate)]
      end

    "hints" -> values.hints.map { |hint| Span(name: "hints", text: hint) }
    "model" ->
      if values.model.empty?
        []
      else
        [Span(name: "model", text: values.model)]
      end

    _ ->
      text = values.segments.select { |segment| segment.name == name }.map { |segment| segment.text }.join("")
      if text.empty?
        []
      else
        [Span(name: name, text: text)]
      end
  end
end

def flatten_comps(comps: List[List[Span]]) -> List[Span]
  all: List[Span] = []
  for comp in comps
    for span in comp
      all = all.push(span)
    end
  end

  return [] if all.empty?

  out: List[Span] = [all[0]]
  for span in all.drop(1)
    out = out.push(Span(name: "", text: " · "))
    out = out.push(span)
  end

  out
end

def cells_of(left: List[List[Span]], right: List[List[Span]]) -> Int
  return 1 + spans_width(flatten_comps(left)) if right.empty?

  spans_width(flatten_comps(left)) + spans_width(flatten_comps(right)) + 3
end

# `spans` cut to `cells` columns, the cut end replaced by `…` in the span it cuts; [] when there is no room.
def cut_spans(spans: List[Span], cells: Int) -> List[Span]
  return spans if spans_width(spans) <= cells
  return [] if cells < 2

  taken = take_spans(spans, cells - 1)
  used = 0
  name = ""
  for span in spans
    wide = Width.text(span.text)
    if used + wide > cells - 1
      name = span.name
      break
    end

    used = used + wide
  end

  taken.push(Span(name: name, text: "…"))
end

def take_spans(spans: List[Span], width: Int) -> List[Span]
  out: List[Span] = []
  used = 0
  for span in spans
    break if used >= width
    break if width <= 0

    remaining = width - used
    wide = Width.text(span.text)
    if wide <= remaining
      out = out.push(span)
      used = used + wide
    else
      out = out.push(Span(name: span.name, text: Width.cut(span.text, remaining)[0]))
      used = width
    end
  end

  out
end

def padded_spans(spans: List[Span], width: Int) -> List[Span]
  taken = take_spans(spans, width)
  used = spans_width(taken)
  return taken if used >= width

  taken.push(Span(name: "", text: " " * (width - used)))
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

# `text` in `cells` cells at most, its end replaced by `…` when cut; "" when there is no room.
def cut(text: String, cells: Int) -> String
  return text if Width.text(text) <= cells
  return "" if cells < 2

  "#{Width.cut(text, cells - 1)[0]}…"
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
