## What the editor keeps beside its text: the large pastes behind their tokens and the files that `@` completes. Pure.

import Layout from "panel"
import Width from "width"

## A paste of more lines or characters than these stays one token in the prompt.
PASTE_LINES = 10
PASTE_CHARS = 1000
## The most files the `@` list shows.
MAX_MATCHES = 8

## The `@` word that ends at the cursor: where its `@` is and what follows it.
struct Mention
  start: Int
  query: String
end

def large?(text: String) -> Bool = text.split("\n").size > PASTE_LINES or text.length > PASTE_CHARS

## The token of the `number`th large paste.
def token(number: Int, text: String) -> String
  lines = text.split("\n").size
  return "[paste ##{number} #{text.length} chars]" if lines == 1

  "[paste ##{number} +#{lines} lines]"
end

## `text` with each token of `pastes` put back as the paste it stands for.
def expanded(text: String, pastes: List[String]) -> String
  out = text
  for i in 0...pastes.size
    out = out.replace(token(i + 1, pastes[i]), pastes[i])
  end

  out
end

## The `@` word the cursor ends, when the `@` starts a word and no space follows it.
def mention(text: String, cursor: Int) -> Optional[Mention]
  chars = text.slice(0, cursor).split("")
  at = chars.size - 1
  while at >= 0 and chars[at] != "@"
    return none if space?(chars[at])

    at -= 1
  end

  return none if at < 0 or (at > 0 and not space?(chars[at - 1]))

  some(Mention(start: at, query: chars.drop(at + 1).join("")))
end

## The files whose path has the letters of `query` in order (case aside), those that hold it whole first, then the
## shorter.
def matches(files: List[String], query: String) -> List[String]
  wanted = query.downcase
  found = files.select { |file| in_order?(file.downcase, wanted) }
  whole = found.select { |file| file.downcase.include?(wanted) }
  rest = found.select { |file| not file.downcase.include?(wanted) }
  (by_length(whole) + by_length(rest)).take(MAX_MATCHES)
end

## The text with the mention replaced by `@path` and a space; the cursor goes after it.
def completed(text: String, cursor: Int, mention: Mention, path: String) -> String
  text.slice(0, mention.start) + "@#{path} " + text.slice(cursor, text.length - cursor)
end

## The rows of the `@` list, the selected one marked.
def rows(found: List[String], selected: Int, width: Int) -> List[Layout.Row]
  return [Layout.Row(text: " no file matches")] if found.empty?

  (0...found.size).to_a.map do |i|
    look = Layout.Look.Plain
    if i == selected
      look = Layout.Look.Selected
    end

    Layout.Row(text: Width.cut(" #{found[i]}", width)[0], look: look)
  end
end

private

def space?(c: String) -> Bool = c == " " or c == "\n" or c == "\t"

def in_order?(text: String, wanted: String) -> Bool
  at = 0
  for c in wanted.split("")
    rest = text.slice(at, text.length - at)
    found = rest.index_of(c)
    return false if found.none?

    at = at + found.unwrap! + 1
  end

  true
end

def by_length(files: List[String]) -> List[String] = files.sort_by { |file| file.length }
