## A page of HTML as compact, indented text for a model: a port of minibot's `html_to_compact`. It keeps what an agent
## acts on (links with their targets, forms, inputs, headings, lists, tables) and drops the presentation (classes,
## styles, `data-*`, scripts, SVG, comments, hidden nodes). A line is a tag and its text in quotes (`a "Foo" /foo`,
## `form POST /login`, `input email email "Email"`); text that has no tag of its own is a quoted line; a table of plain
## cells is rows of pipes; `pre` keeps its lines. The depth of a line is its indent, one space per level, and tags that
## carry no meaning (`div`, `span`, `b`, `tbody`, ...) add none.
##
## The reader is lenient as a browser is: an unclosed or stray tag never fails, the end tags that HTML implies (`<li>`,
## `<p>`, `<td>`, `<option>`) are supplied, and nesting is held to `MAX_DEPTH` open elements (a deeper element is read
## as text of its parent). It never fails: the answer is a string, empty for a page with nothing in it.

import HTML from "std/html"
import Regex from "std/regex"

MAX_DEPTH = 256
## How many of the innermost open elements an implied or explicit end tag looks at, so that markup nested to the depth
## limit costs a bounded time for each tag.
SCAN = 32
DROP = ["script", "style", "noscript", "template", "svg", "canvas", "iframe", "meta", "link", "base"]
TRANSPARENT = [
  "html", "head", "body", "div", "span", "center", "font", "small", "b", "i", "u", "em", "strong", "mark", "picture",
  "figure", "label", "tbody", "thead", "tfoot", "colgroup", "fieldset", "dl",
]
VOID = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
BOOLEAN_ATTRS = ["checked", "selected", "disabled", "required"]
## The tags that end an open `p` when they start.
ENDS_P = [
  "address", "article", "aside", "blockquote", "div", "dl", "fieldset", "footer", "form", "h1", "h2", "h3", "h4", "h5",
  "h6", "header", "hr", "main", "nav", "ol", "p", "pre", "section", "table", "ul",
]
## The names of the characters that pages write most, read as `HTML.unescape` cannot.
ENTITIES = {
  "&nbsp;": " ", "&copy;": "©", "&reg;": "®", "&trade;": "™", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
  "&laquo;": "«", "&raquo;": "»", "&lsquo;": "‘", "&rsquo;": "’", "&ldquo;": "“", "&rdquo;": "”", "&bull;": "•",
  "&middot;": "·", "&euro;": "€", "&pound;": "£", "&yen;": "¥", "&cent;": "¢", "&deg;": "°", "&plusmn;": "±",
  "&times;": "×", "&divide;": "÷", "&para;": "¶", "&sect;": "§", "&larr;": "←", "&rarr;": "→", "&uarr;": "↑",
  "&darr;": "↓",
}

## A node of the page: an element (`tag` in lower case) or a piece of text (`tag` is `-text`, and `text` is it).
struct Node
  tag: String
  text: String = ""
  attrs: Map[String, String] = {}
  children: List[Node] = []
end

## The compact text of `html`.
def compact(html: String) -> String
  return "" if html.strip.empty?

  root = parse(html)
  render_children(root, 0, []).join("\n")
end

private

TAG_NAME = /\A[^\s\/]+/
VALID_NAME = /\A[a-z][a-z0-9:_.\-]*\z/
ATTRIBUTE = /([^\s"'<>\/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?/
# The end of an attribute value or of a tag: a quote or a `>`.
MARKS = /["'>]/
# Whitespace and every control character: a run of them is one space, so that no line break of the page reaches
# the text.
SPACES = /[\x{0}-\x{20}\x{7F}\x{85}\x{A0}\x{2028}\x{2029}]+/
# A control character of a line of `pre` that is not a tab.
CONTROLS = /[\x{0}-\x{8}\x{B}-\x{1F}\x{7F}\x{85}\x{2028}\x{2029}]/
## How much of a tag is read for its attributes, and how much of a tag is looked at in one piece.
MAX_ATTRIBUTES = 16384
WINDOW = 4096

## What the reader holds while it goes through the page: the open elements (the root first), and the text since the last
## tag, in pieces that are joined once.
struct Reader
  open: List[Node]
  text: List[String]
end

## The reader after a piece of the page, and the piece to go on at.
struct Step
  reader: Reader
  next: Int
end

## A tag found: its text between `<` and `>` (a `>` inside quotes does not end it), the piece that held its `>`, and the
## text after it in that piece.
struct Scanned
  inner: String
  last: Int
  after: String
end

## Where a text was found: in which piece, and at which character.
struct Found
  piece: Int
  at: Int
end

# The page is cut at each `<`: a piece is what follows one, and holds a tag, a comment, a declaration or text.
# The reader
# never goes back: what a piece takes (a comment, a tag, a script) is skipped, and one that cannot end (a comment or
# a tag
# with no end) is the end of the page, as in a browser, so the time is in proportion to the size of the page.
def parse(html: String) -> Node
  pieces = html.split("<")
  reader = Reader(open: [Node(tag: "#root")], text: [decode(pieces[0])])
  at = 1
  while at < pieces.size
    stepped = step(reader, pieces, at)
    reader = stepped.reader
    at = stepped.next
  end

  reader = flush(reader)
  while reader.open.size > 1
    reader = reader.with(open: pop(reader.open))
  end

  reader.open[0]
end

def step(reader: Reader, pieces: List[String], at: Int) -> Step
  piece = pieces[at]
  return comment(reader, pieces, at) if piece.start_with?("!--")
  return declaration(reader, pieces, at) if piece.start_with?("!") or piece.start_with?("?")
  if (
    piece != "" and
    (letter?(piece.slice(0, 1)) or (piece.start_with?("/") and piece.length > 1 and letter?(piece.slice(1, 1))))
  )
    return tag(reader, pieces, at)
  end

  Step(reader: reader.with(text: reader.text.push("<" + decode(piece))), next: at + 1)
end

def letter?(char: String) -> Bool
  return false if char == ""

  code = char.code
  (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
end

## The text before a tag or a comment is a node of its own.
def flush(reader: Reader) -> Reader
  text = reader.text.join("")
  return reader.with(text: []) if text == ""

  reader.with(open: add_child(reader.open, Node(tag: "-text", text: text)), text: [])
end

## The first `needle` from the character `offset` of the piece `at`, then in the pieces after it.
def find(pieces: List[String], at: Int, offset: Int, needle: String) -> Optional[Found]
  first = pieces[at]
  case first.slice(offset, first.length - offset).index_of(needle)
    some(found) -> return some(Found(piece: at, at: offset + found))
    none -> nil
  end

  next = at + 1
  while next < pieces.size
    case pieces[next].index_of(needle)
      some(found) -> return some(Found(piece: next, at: found))
      none -> nil
    end

    next += 1
  end

  none
end

## What comes after `needle` where `found` says, as text, and the piece to go on at; none when there was no end, which
## is the end of the page.
def after_end(reader: Reader, pieces: List[String], found: Optional[Found], length: Int) -> Step
  case found
    some(at) ->
      piece = pieces[at.piece]
      after = piece.slice(at.at + length, piece.length - at.at - length)
      Step(reader: reader.with(text: [decode(after)]), next: at.piece + 1)
    none -> Step(reader: reader, next: pieces.size)
  end
end

## A comment ends at `-->` (`<!-->` and `<!--->` end at once); one that is not closed takes the rest of the page.
def comment(reader: Reader, pieces: List[String], at: Int) -> Step
  flushed = flush(reader)
  rest = pieces[at].slice(3, pieces[at].length - 3)
  if rest.start_with?(">") or rest.start_with?("->")
    skip = 1
    if rest.start_with?("->")
      skip = 2
    end

    return Step(reader: flushed.with(text: [decode(rest.slice(skip, rest.length - skip))]), next: at + 1)
  end

  after_end(flushed, pieces, find(pieces, at, 3, "-->"), 3)
end

## `<!DOCTYPE ...>` and `<?...>` end at the first `>`.
def declaration(reader: Reader, pieces: List[String], at: Int) -> Step
  after_end(flush(reader), pieces, find(pieces, at, 1, ">"), 1)
end

## A start tag or an end tag.
def tag(reader: Reader, pieces: List[String], at: Int) -> Step
  case scan_tag(pieces, at)
    none -> Step(reader: reader, next: pieces.size)
    some(scanned) ->
      flushed = flush(reader)
      if pieces[at].start_with?("/")
        ended = end_tag(flushed, end_name(scanned.inner))
        return Step(reader: ended.with(text: [decode(scanned.after)]), next: scanned.last + 1)
      end

      opened = start_tag(flushed, scanned.inner)
      name = tag_name(scanned.inner)
      if name == "script" or name == "style" or name == "textarea" or name == "title"
        return raw_text(opened, pieces, scanned, name)
      end

      Step(reader: opened.with(text: [decode(scanned.after)]), next: scanned.last + 1)
  end
end

## The tag that starts at the piece `at`, up to the first `>` that is not in quotes. A tag that has none before the end of
## the page is dropped, as a browser does.
def scan_tag(pieces: List[String], at: Int) -> Optional[Scanned]
  quote = ""
  held: List[String] = []
  piece = at
  while piece < pieces.size
    seg = pieces[piece]
    start = 0
    while start < seg.length
      size = [WINDOW, seg.length - start].min.unwrap!
      for found in Regex.find_all(seg.slice(start, size), MARKS)
        mark = found.text
        if quote == ""
          if mark == ">"
            stop = start + found.start
            inner = seg.slice(0, stop)
            if not held.empty?
              inner = held.join("<") + "<" + inner
            end

            return some(Scanned(inner: inner, last: piece, after: seg.slice(stop + 1, seg.length - stop - 1)))
          end

          quote = mark
        elsif mark == quote
          quote = ""
        end
      end

      start += size
    end

    held = held.push(seg)
    piece += 1
  end

  none
end

## The name of a start tag in lower case, or none when it is not a name that a page uses.
def tag_name(inner: String) -> String
  case Regex.match(inner, TAG_NAME)
    ok(found) ->
      name = found.text.downcase
      if Regex.match?(name, VALID_NAME)
        name
      else
        ""
      end

    error(_) -> ""
  end
end

## The name an end tag closes, in lower case; empty when it is not a name that a page uses.
def end_name(inner: String) -> String = tag_name(inner.slice(1, inner.length - 1).replace(">", " "))

## `script` and `style` hold text that is not markup, up to their end tag, and are dropped; a `textarea` and a `title` hold
## text that is. The page goes on at the end tag; with none, the text takes the rest of the page.
def raw_text(reader: Reader, pieces: List[String], scanned: Scanned, name: String) -> Step
  keep = name == "textarea" or name == "title"
  held = [scanned.after]
  stop = scanned.last + 1
  while stop < pieces.size and not closes?(pieces[stop], name)
    if keep
      held = held.push(pieces[stop])
    end

    stop += 1
  end

  return Step(reader: reader, next: stop) if not keep

  Step(reader: reader.with(text: [decode(held.join("<"))]), next: stop)
end

def closes?(piece: String, name: String) -> Bool
  return false if piece.length < name.length + 1 or piece.slice(0, name.length + 1).downcase != "/#{name}"
  return true if piece.length == name.length + 1

  rest = piece.slice(name.length + 1, 1)
  rest == ">" or rest == "/" or rest.strip == ""
end

def start_tag(reader: Reader, inner: String) -> Reader
  name = tag_name(inner)
  return reader if name == ""

  open = implied(reader.open, name)
  attrs = attributes(inner.slice(name.length, [inner.length, MAX_ATTRIBUTES].min.unwrap! - name.length))
  node = Node(tag: name, attrs: attrs)
  return reader.with(open: add_child(open, node)) if VOID.include?(name)

  return reader.with(open: open) if open.size >= MAX_DEPTH

  reader.with(open: open.push(node))
end

def attributes(text: String) -> Map[String, String]
  found: Map[String, String] = {}
  for match in Regex.find_all(text, ATTRIBUTE)
    name = match.groups[1].text.downcase
    next if found.has_key?(name)

    value = ""
    for group in match.groups.drop(2)
      if group.matched
        value = decode(group.text)
      end
    end

    found = found.put(name, value)
  end

  found
end

def decode(text: String) -> String
  return text if not text.include?("&")

  named = ENTITIES.keys.reduce(text) do |current, name| current.replace(name, ENTITIES[name]) end
  HTML.unescape(named)
end

## The open elements after the end tags that the start of `name` implies.
def implied(open: List[Node], name: String) -> List[Node]
  case name
    "li" -> close_to(open, ["li"], ["ul", "ol", "menu"])
    "dt" -> close_to(open, ["dt", "dd"], ["dl"])
    "dd" -> close_to(open, ["dt", "dd"], ["dl"])
    "option" -> close_to(open, ["option"], ["select", "datalist"])
    "optgroup" -> close_to(open, ["option", "optgroup"], ["select"])
    "tr" -> close_to(open, ["tr"], ["table"])
    "td" -> close_to(open, ["td", "th"], ["tr", "table"])
    "th" -> close_to(open, ["td", "th"], ["tr", "table"])
    "thead" -> close_to(open, ["thead", "tbody", "tfoot"], ["table"])
    "tbody" -> close_to(open, ["thead", "tbody", "tfoot"], ["table"])
    "tfoot" -> close_to(open, ["thead", "tbody", "tfoot"], ["table"])
    _ ->
      if ENDS_P.include?(name)
        close_to(open, ["p"], ["td", "th", "table", "button", "caption", "object"])
      else
        open
      end
  end
end

def end_tag(reader: Reader, name: String) -> Reader = reader.with(open: close_to(reader.open, [name], stops(name)))

## The elements that an end tag does not reach past.
def stops(name: String) -> List[String]
  case name
    "table" -> []
    "tr" -> ["table"]
    "td" -> ["table"]
    "th" -> ["table"]
    "tbody" -> ["table"]
    "thead" -> ["table"]
    "tfoot" -> ["table"]
    "li" -> ["ul", "ol", "table"]
    _ -> ["table", "td", "th"]
  end
end

## Closes the nearest open element named in `names`, and what is open inside it, unless an element of `stops` comes
## first or it is not among the `SCAN` innermost; the root is never closed.
def close_to(open: List[Node], names: List[String], stops: List[String]) -> List[Node]
  at = open.size - 1
  floor = [1, open.size - SCAN].max.unwrap!
  while at >= floor
    tag = open[at].tag
    if names.include?(tag)
      closed = open
      while closed.size > at
        closed = pop(closed)
      end

      return closed
    end

    return open if stops.include?(tag)

    at -= 1
  end

  open
end

## The open elements without the innermost, which goes into the one before it.
def pop(open: List[Node]) -> List[Node]
  last = open.size - 1
  add_child(open.take(last), open[last])
end

def add_child(open: List[Node], child: Node) -> List[Node]
  last = open.size - 1
  top = open[last]
  open.take(last).push(top.with(children: top.children.push(child)))
end

def render(node: Node, depth: Int, out: List[String]) -> List[String]
  tag = node.tag
  return out if DROP.include?(tag) or hidden?(node)
  return text_line(node, depth, out) if tag == "-text"
  return render_children(node, depth, out) if TRANSPARENT.include?(tag)
  return render_table(node, depth, out) if tag == "table"
  return render_pre(node, depth, out) if tag == "pre"

  return out.push(indent(depth) + input_line(node.attrs)) if tag == "input"

  if tag == "img"
    line = img_line(node.attrs)
    return out if line == ""

    return out.push(indent(depth) + line)
  end

  sub = render_children(node, depth + 1, [])
  case collapse(sub)
    some(text) ->
      line = leaf_line(tag, node.attrs, text)
      if line == ""
        out
      else
        out.push(indent(depth) + line)
      end

    none ->
      header = leaf_line(tag, node.attrs, "")
      if header == ""
        header = tag
      end

      append(out.push(indent(depth) + header), sub)
  end
end

def text_line(node: Node, depth: Int, out: List[String]) -> List[String]
  text = norm(node.text)
  return out if text == ""

  out.push(indent(depth) + quote(text))
end

def render_children(node: Node, depth: Int, out: List[String]) -> List[String]
  rendered = out
  for child in node.children
    rendered = render(child, depth, rendered)
  end

  rendered
end

def append(out: List[String], more: List[String]) -> List[String]
  appended = out
  for line in more
    appended = appended.push(line)
  end

  appended
end

def render_table(node: Node, depth: Int, out: List[String]) -> List[String]
  grid = table_rows(node).map { |row| row.children.select { |cell| cell.tag == "td" or cell.tag == "th" } }
  grid = grid.select { |cells| not cells.empty? }
  return render_children(grid[0][0], depth, out) if grid.size == 1 and grid[0].size == 1

  rows: List[String] = []
  for cells in grid
    # A cell is rendered once, at depth 0; each way to show it is that text moved to its depth.
    bodies = cells.map { |cell| render_children(cell, 0, []) }
    texts = bodies.map { |body| collapse(body) }
    if texts.all? { |text| text.some? }
      values = texts.map { |text| text.unwrap_or("") }.join(" | ")
      rows = rows.push("#{indent(depth + 1)}| #{values} |")
    elsif cells.size == 1
      rows = append(rows, moved(bodies[0], depth + 1))
    else
      rows = rows.push("#{indent(depth + 1)}tr")
      for at in 0..(cells.size - 1)
        rows = nested_cell(cells[at], bodies[at], depth + 2, rows)
      end
    end
  end

  return out if rows.empty?

  append(out.push("#{indent(depth)}table"), rows)
end

## `lines`, rendered at depth 0, at `depth`.
def moved(lines: List[String], depth: Int) -> List[String]
  prefix = indent(depth)
  lines.map { |line| prefix + line }
end

## A cell that holds one line adds a level of nesting and no information; any other is shown as an element, which is its
## text when that is plain and else its own line over its lines. `body` is what the cell holds, rendered at depth 0.
def nested_cell(cell: Node, body: List[String], depth: Int, out: List[String]) -> List[String]
  return append(out, moved(body, depth)) if body.size == 1
  return out if hidden?(cell)

  case collapse(body)
    some(text) ->
      line = leaf_line(cell.tag, cell.attrs, text)
      if line == ""
        out
      else
        out.push(indent(depth) + line)
      end

    none ->
      header = leaf_line(cell.tag, cell.attrs, "")
      if header == ""
        header = cell.tag
      end

      append(out.push(indent(depth) + header), moved(body, depth + 1))
  end
end

## The rows of this table, not those of a table inside it.
def table_rows(node: Node) -> List[Node]
  rows: List[Node] = []
  for child in node.children
    if child.tag == "tr"
      rows = rows.push(child)
    elsif child.tag == "thead" or child.tag == "tbody" or child.tag == "tfoot"
      for row in child.children.select { |inner| inner.tag == "tr" }
        rows = rows.push(row)
      end
    end
  end

  rows
end

## Preformatted text keeps its own line breaks: collapsing them would destroy code.
def render_pre(node: Node, depth: Int, out: List[String]) -> List[String]
  text = Regex.replace(text_of(node), /\A\n+|\n+\z/, "").unwrap_or("")
  return out if text.strip.empty?

  lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
  prefix = indent(depth + 1)
  rendered = out.push("#{indent(depth)}pre")
  for line in lines
    rendered = rendered.push(prefix + pre_line(line))
  end

  rendered
end

## A line of `pre` with no control character but the tab, and no space at its end.
def pre_line(line: String) -> String
  plain = Regex.replace(line, CONTROLS, " ").unwrap_or(line)
  Regex.replace(plain, /\s+\z/, "").unwrap_or(plain)
end

def text_of(node: Node) -> String
  return node.text if node.tag == "-text"

  node.children.map { |child| text_of(child) }.join("")
end

def leaf_line(tag: String, attrs: Map[String, String], text: String) -> String
  case tag
    "a" -> join(["a", quote(text), attr(attrs, "href")])
    "button" -> join(["button", quote(either(text, attrs.get("value").unwrap_or("")))])
    "form" -> join(["form", either(attr(attrs, "method"), "GET").upcase, attr(attrs, "action")])
    "select" -> join(["select", attr(attrs, "name")] + flags(attrs))
    "option" -> join(["option", quote(text), value(attrs.get("value").unwrap_or(""))] + flags(attrs))
    "textarea" -> join(["textarea", attr(attrs, "name"), quote(either(attrs.get("placeholder").unwrap_or(""), text))])
    "video" -> join([tag, attr(attrs, "src")])
    "audio" -> join([tag, attr(attrs, "src")])
    _ ->
      label = quote(either(text, either(attrs.get("aria-label").unwrap_or(""), attrs.get("title").unwrap_or(""))))
      if label == ""
        ""
      else
        join([tag, label])
      end
  end
end

def input_line(attrs: Map[String, String]) -> String
  join(
    [
      "input",
      either(attr(attrs, "type"), "text"),
      attr(attrs, "name"),
      quote(either(attrs.get("placeholder").unwrap_or(""), attrs.get("aria-label").unwrap_or(""))),
      value(attrs.get("value").unwrap_or("")),
    ] +
    flags(attrs),
  )
end

def img_line(attrs: Map[String, String]) -> String
  alt = quote(attrs.get("alt").unwrap_or(""))
  src = attr(attrs, "src")
  return "" if alt == "" and src == ""

  join(["img", alt, src])
end

## The text of the lines when each is a quoted text, else none: a child with a structure of its own keeps its lines.
def collapse(lines: List[String]) -> Optional[String]
  parts: List[String] = []
  for line in lines
    stripped = line.strip
    return none if not (stripped.start_with?("\"") and stripped.end_with?("\""))

    if stripped.length > 1
      parts = parts.push(stripped.slice(1, stripped.length - 2))
    end
  end

  some(parts.select { |part| part != "" }.join(" "))
end

def hidden?(node: Node) -> Bool
  attrs = node.attrs
  return true if attrs.has_key?("hidden") and node.tag != "input"
  return true if attrs.get("aria-hidden") == some("true")

  style = attrs.get("style").unwrap_or("").replace(" ", "").downcase
  style.include?("display:none") or style.include?("visibility:hidden")
end

def flags(attrs: Map[String, String]) -> List[String] = BOOLEAN_ATTRS.select { |name| attrs.has_key?(name) }

def value(text: String) -> String
  normal = norm(text)
  if normal == ""
    ""
  else
    "=#{normal}"
  end
end

def quote(text: String) -> String
  normal = norm(text)
  if normal == ""
    ""
  else
    "\"#{normal}\""
  end
end

def either(first: String, second: String) -> String
  if first == ""
    second
  else
    first
  end
end

def join(parts: List[String]) -> String = parts.select { |part| part != "" }.join(" ")

## An attribute as the text of a line: whitespace and control characters, line breaks among them, are one space.
def attr(attrs: Map[String, String], name: String) -> String = clean(attrs.get(name).unwrap_or(""))

def clean(text: String) -> String = Regex.split(text, SPACES).select { |word| word != "" }.join(" ")

## The same, and a double quote is a single quote: the quotes of a line are its own.
def norm(text: String) -> String = clean(text.replace("\"", "'"))

def indent(depth: Int) -> String = " " * depth
