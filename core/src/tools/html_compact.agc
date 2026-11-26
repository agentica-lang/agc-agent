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

# One piece of the page: a comment, a declaration, an end tag, a start tag (its quoted attribute values may hold `>`),
# text, or a `<` that opens none of them.
TOKEN = /<!--[\s\S]*?-->|<![^>]*>|<\?[^>]*>|<\/[a-zA-Z][^>]*>|<[a-zA-Z](?:"[^"]*"|'[^']*'|[^>"'])*>|[^<]+|</
TAG_NAME = /\A[^\s\/]+/
ATTRIBUTE = /([^\s"'<>\/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?/
SPACES = /[\s\x{A0}]+/

## What the reader holds while it goes through the tokens: the open elements (the root first), and the raw-text element
## whose end it waits for (`script` and `style` are dropped, a `textarea` keeps its text).
struct Reader
  open: List[Node]
  raw: String = ""
  raw_text: String = ""
end

def parse(html: String) -> Node
  reader = Reader(open: [Node(tag: "#root")])
  for found in Regex.find_all(html, TOKEN)
    reader = take(reader, found.text)
  end

  reader = end_raw(reader)
  while reader.open.size > 1
    reader = reader.with(open: pop(reader.open))
  end

  reader.open[0]
end

def take(reader: Reader, token: String) -> Reader
  if reader.raw != ""
    return reader.with(raw_text: reader.raw_text + token) if end_name(token) != reader.raw

    return end_tag(end_raw(reader), reader.raw)
  end

  return reader if token.start_with?("<!") or token.start_with?("<?")
  return end_tag(reader, end_name(token)) if token.start_with?("</") and token.length > 2
  return start_tag(reader, token) if token.length > 2 and token.start_with?("<") and letter?(token.slice(1, 1))

  reader.with(open: add_text(reader.open, decode(token)))
end

def letter?(char: String) -> Bool
  code = char.code
  (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
end

## The name an end tag closes, in lower case; empty for a token that is no end tag.
def end_name(token: String) -> String
  return "" if not token.start_with?("</")

  inner = token.slice(2, token.length - 2)
  case Regex.match(inner, /\A[^\s\/>]+/)
    ok(found) -> found.text.downcase
    error(_) -> ""
  end
end

## The text a `textarea` collected goes in as its text.
def end_raw(reader: Reader) -> Reader
  return reader.with(raw: "", raw_text: "") if reader.raw_text == "" or reader.raw == "script" or reader.raw == "style"

  reader.with(open: add_text(reader.open, decode(reader.raw_text)), raw: "", raw_text: "")
end

def start_tag(reader: Reader, token: String) -> Reader
  inner = token.slice(1, token.length - 2)
  name = ""
  case Regex.match(inner, TAG_NAME)
    ok(found) -> name = found.text.downcase
    error(_) -> return reader
  end

  return reader.with(raw: name) if name == "script" or name == "style"

  open = implied(reader.open, name)
  node = Node(tag: name, attrs: attributes(inner.slice(name.length, inner.length - name.length)))
  return reader.with(open: add_child(open, node)) if VOID.include?(name)

  return reader.with(open: open) if open.size >= MAX_DEPTH

  reader.with(open: open.push(node), raw: raw_of(name))
end

def raw_of(name: String) -> String
  return "textarea" if name == "textarea"

  ""
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

## Text next to text is one node.
def add_text(open: List[Node], text: String) -> List[Node]
  last = open.size - 1
  top = open[last]
  size = top.children.size
  if size > 0 and top.children[size - 1].tag == "-text"
    joined = top.children[size - 1].with(text: top.children[size - 1].text + text)
    return open.take(last).push(top.with(children: top.children.take(size - 1).push(joined)))
  end

  add_child(open, Node(tag: "-text", text: text))
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
    texts = cells.map { |cell| collapse(render_children(cell, 0, [])) }
    if texts.all? { |text| text.some? }
      values = texts.map { |text| text.unwrap_or("") }.join(" | ")
      rows = rows.push("#{indent(depth + 1)}| #{values} |")
    elsif cells.size == 1
      rows = render_children(cells[0], depth + 1, rows)
    else
      rows = rows.push("#{indent(depth + 1)}tr")
      for cell in cells
        rows = nested_cell(cell, depth + 2, rows)
      end
    end
  end

  return out if rows.empty?

  append(out.push("#{indent(depth)}table"), rows)
end

## A cell that holds one element adds a level of nesting and no information.
def nested_cell(cell: Node, depth: Int, out: List[String]) -> List[String]
  sub = render_children(cell, depth, [])
  return append(out, sub) if sub.size == 1

  render(cell, depth, out)
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
    rendered = rendered.push(prefix + Regex.replace(line, /\s+\z/, "").unwrap_or(line))
  end

  rendered
end

def text_of(node: Node) -> String
  return node.text if node.tag == "-text"

  node.children.map { |child| text_of(child) }.join("")
end

def leaf_line(tag: String, attrs: Map[String, String], text: String) -> String
  case tag
    "a" -> join(["a", quote(text), attrs.get("href").unwrap_or("")])
    "button" -> join(["button", quote(either(text, attrs.get("value").unwrap_or("")))])
    "form" ->
      join(["form", either(attrs.get("method").unwrap_or(""), "GET").upcase, attrs.get("action").unwrap_or("")])
    "select" -> join(["select", attrs.get("name").unwrap_or("")] + flags(attrs))
    "option" -> join(["option", quote(text), value(attrs.get("value").unwrap_or(""))] + flags(attrs))
    "textarea" ->
      join(["textarea", attrs.get("name").unwrap_or(""), quote(either(attrs.get("placeholder").unwrap_or(""), text))])
    "video" -> join([tag, attrs.get("src").unwrap_or("")])
    "audio" -> join([tag, attrs.get("src").unwrap_or("")])
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
      either(attrs.get("type").unwrap_or(""), "text"),
      attrs.get("name").unwrap_or(""),
      quote(either(attrs.get("placeholder").unwrap_or(""), attrs.get("aria-label").unwrap_or(""))),
      value(attrs.get("value").unwrap_or("")),
    ] +
    flags(attrs),
  )
end

def img_line(attrs: Map[String, String]) -> String
  alt = quote(attrs.get("alt").unwrap_or(""))
  src = attrs.get("src").unwrap_or("")
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

## Whitespace runs are one space, and a double quote is a single quote: the quotes of a line are its own.
def norm(text: String) -> String = Regex.split(text.replace("\"", "'"), SPACES).select { |word| word != "" }.join(" ")

def indent(depth: Int) -> String = " " * depth
