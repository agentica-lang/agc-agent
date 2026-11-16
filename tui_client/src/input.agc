## What the editor keeps beside its text: the large pastes behind their tokens, and the lists under it of the files
## that `@` completes and of the commands that `/` completes. Pure.

import Client from "pkg/client/client"
import Layout from "panel"
import Width from "width"

## A paste of more lines or characters than these stays one token in the prompt.
PASTE_LINES = 10
PASTE_CHARS = 1000
## The most files the `@` list shows.
MAX_MATCHES = 8

## What a list under the editor completes.
enum Source
  Files
  Commands
end

## The word that ends at the cursor, `@` and a path or `/` and a command: where it starts and what follows its mark.
struct Mention
  start: Int
  query: String
  source: Source = Source.Files
end

## One row of a list: what Tab puts in place of the word, and what the row shows.
struct Choice
  value: String
  label: String
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

## The command word at the start of the prompt, `/` and a name, while the cursor is at its end.
def command_word(text: String, cursor: Int) -> Optional[Mention]
  return none if not text.start_with?("/")

  word = text.split("\n")[0].split(" ")[0]
  return none if cursor != word.length

  some(Mention(start: 0, query: word.slice(1, word.length - 1), source: Source.Commands))
end

## The commands whose name starts with `/query`, each with its arguments and what it does, in a column. A command
## with arguments completes with a space after it.
def commands(table: List[Client.Usage], query: String) -> List[Choice]
  found = table.select { |usage| usage.name.start_with?("/#{query}") }
  heads = found.map { |usage| "#{usage.name} #{usage.args}".strip }
  column = heads.map { |head| head.length }.max.unwrap_or(0) + 2
  (0...found.size).to_a.map do |i|
    value = found[i].name
    if found[i].args != ""
      value = "#{value} "
    end

    Choice(value: value, label: "#{heads[i]}#{" " * (column - heads[i].length)}#{found[i].about}")
  end
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

## The text with the word replaced by the choice: `@path` and a space, or the command; the cursor goes after it.
def completed(text: String, cursor: Int, mention: Mention, value: String) -> String
  rest = text.slice(cursor, text.length - cursor)
  case mention.source
    Source.Files -> text.slice(0, mention.start) + "@#{value} " + rest
    # The rest starts with its own space.
    Source.Commands if rest != "" -> text.slice(0, mention.start) + value.strip + rest
    Source.Commands -> text.slice(0, mention.start) + value + rest
  end
end

## The rows of a list in `room` rows, the selected one marked and always among them.
def rows(found: List[Choice], selected: Int, width: Int, room: Int) -> List[Layout.Row]
  return [Layout.Row(text: " no file matches")].take(room) if found.empty?

  first = [selected - room + 1, 0].max.unwrap!
  (first...[first + room, found.size].min.unwrap!).to_a.map do |i|
    look = Layout.Look.Plain
    if i == selected
      look = Layout.Look.Selected
    end

    Layout.Row(text: Width.cut(" #{found[i].label}", width)[0], look: look)
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
