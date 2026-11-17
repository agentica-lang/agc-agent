## What the editor keeps beside its text: the large pastes behind their tokens, and the lists under it of the files
## that `@` completes, of the commands that `/` completes and of their arguments. Pure.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import Layout from "panel"
import Width from "width"

## A paste of more lines or characters than these stays one token in the prompt.
PASTE_LINES = 10
PASTE_CHARS = 1000
## The most files the `@` list shows.
MAX_MATCHES = 8
## The commands whose argument the list completes.
ARGUMENT_COMMANDS = ["/model", "/resume", "/tree", "/fork", "/thinking", "/profile"]

## What a list under the editor completes.
enum Source
  Files
  Commands
  Arguments
end

## The word that ends at the cursor, `@` and a path, `/` and a command, or a command's argument: where it starts and
## what follows its mark (all of an argument).
struct Mention
  start: Int
  query: String
  source: Source = Source.Files
  ## The command of an argument.
  command: String = ""
end

## The choices of a command's argument, as the server listed them; `tree` the session tree that `/tree N` numbers.
struct Arguments
  command: String
  choices: List[Choice]
  tree: Optional[Protocol.SessionTree] = none
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

## `text` with the first copy of each token of `pastes` put back as the paste it stands for, in one pass over `text`:
## a token inside a paste stays as it is.
def expanded(text: String, pastes: List[String]) -> String
  found: List[List[Int]] = []
  for i in 0...pastes.size
    case text.index_of(token(i + 1, pastes[i]))
      some(at) -> found = found.push([at, i])
      none -> nil
    end
  end

  out = ""
  from = 0
  for pair in (found.sort_by { |pair| pair[0] })
    next if pair[0] < from

    piece = token(pair[1] + 1, pastes[pair[1]])
    out = out + text.slice(from, pair[0] - from) + pastes[pair[1]]
    from = pair[0] + piece.length
  end

  out + text.slice(from, text.length - from)
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

## The argument of `/model`, `/resume`, `/tree`, `/fork`, `/thinking` or `/profile` on the first line, while the cursor ends the
## line.
def argument_word(text: String, cursor: Int) -> Optional[Mention]
  line = text.split("\n")[0]
  return none if cursor != line.length

  name = line.split(" ")[0]
  return none if not ARGUMENT_COMMANDS.include?(name) or line.length <= name.length

  argument = line.slice(name.length + 1, line.length - name.length - 1)
  return none if argument.include?(" ")

  some(Mention(start: name.length + 1, query: argument, source: Source.Arguments, command: name))
end

## The choices that start with `query`, or whose row holds it, in any case.
def argument_matches(choices: List[Choice], query: String) -> List[Choice]
  wanted = query.downcase
  choices.select { |c| c.value.downcase.start_with?(wanted) or c.label.downcase.include?(wanted) }
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
    Source.Arguments -> text.slice(0, mention.start) + value + rest
  end
end

## The first of `size` choices that `room` rows show: `top` moved only as far as the selected one needs to be among
## them, and no further than the end allows.
def window(top: Int, selected: Int, room: Int, size: Int) -> Int
  shown = [[top, selected].min.unwrap!, selected - room + 1].max.unwrap!
  [[shown, size - room].min.unwrap!, 0].max.unwrap!
end

## The rows of a list in `room` rows from choice `top`, the selected one marked.
def rows(found: List[Choice], selected: Int, top: Int, width: Int, room: Int) -> List[Layout.Row]
  return [Layout.Row(text: " no file matches")].take(room) if found.empty?

  (top...[top + room, found.size].min.unwrap!).to_a.map do |i|
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
