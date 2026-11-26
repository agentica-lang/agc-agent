# `HtmlCompact.compact`: a page as indented text that keeps what a model acts on (links with their targets, forms,
# inputs, headings, lists, tables) and drops the presentation (classes, styles, scripts, SVG). The cases are those of
# minibot's html_compact.

import HtmlCompact from "../src/tools/html_compact"

def check(table: List[List[String]]) -> Result[Void]
  for row in table
    try Test.eq("#{row[0]} => #{HtmlCompact.compact(row[0])}", "#{row[0]} => #{row[1]}")
  end

  ok()
end

# What is kept and how a line reads: text, links, images, headings, inline formatting, and the lists.
def test_a_page_keeps_its_text_links_and_structure() -> Result[Void]
  check([
    ["<p>Hello</p>", "p \"Hello\""],
    ["<a href=\"/foo\">Foo</a>", "a \"Foo\" /foo"],
    ["<img src=\"/a.png\" alt=\"Cat\" class=\"x\">", "img \"Cat\" /a.png"],
    ["<h1>Main</h1><h2>Section</h2><p>Text</p>", "h1 \"Main\"\nh2 \"Section\"\np \"Text\""],
    ["<p>Great <b>laptop</b> for work.</p>", "p \"Great laptop for work.\""],
    ["<ul><li>Fast</li><li>Light</li></ul>", "ul\n li \"Fast\"\n li \"Light\""],
    ["<div class=\"a\"><div class=\"b\"><div><span>Hello</span></div></div></div>", "\"Hello\""],
    ["<p>say \"hi\"   to\n  me</p>", "p \"say 'hi' to me\""],
  ])
end

# What is dropped: scripts, styles, SVG, comments, hidden nodes, and every attribute but the few that mean something.
def test_presentation_and_hidden_parts_are_dropped() -> Result[Void]
  check([
    ["<style>.a{color:red}</style><script>evil()</script><svg><path d=\"M0 0\"/></svg><p>Hello</p>", "p \"Hello\""],
    ["<script>if (a < b) { x = \"</p>\"; }</script><!-- a <b> comment --><p>kept</p>", "p \"kept\""],
    [
      "<a id=\"l\" class=\"btn\" style=\"color:red\" data-testid=\"go\" onclick=\"track()\" href=\"/go\">Go</a>",
      "a \"Go\" /go",
    ],
    [
      "<p style=\"display: none\">secret</p><p hidden>gone</p><p aria-hidden=\"true\">invisible</p><p>kept</p>",
      "p \"kept\"",
    ],
    ["<noscript>enable js</noscript><template><p>t</p></template><iframe src=\"/x\"></iframe><p>a</p>", "p \"a\""],
  ])
end

# A form keeps its action, method, inputs, selects and button; a hidden input stays, since it is part of the request.
def test_forms_keep_what_a_model_needs_to_fill_them() -> Result[Void]
  check([
    [
      "<form action=\"/login\" method=\"post\"><input type=\"email\" name=\"email\" placeholder=\"Email\">" +
      "<input type=\"password\" name=\"password\" required><input type=\"hidden\" name=\"csrf\" value=\"abc\">" +
      "<button>Login</button></form>",
      "form POST /login\n input email email \"Email\"\n input password password required\n input hidden csrf =abc\n button \"Login\"",
    ],
    [
      "<select name=\"size\"><option value=\"l\" selected>Large</option><option value=\"s\">Small</option></select>",
      "select size\n option \"Large\" =l selected\n option \"Small\" =s",
    ],
    [
      "<form><textarea name=\"note\" placeholder=\"Say\"></textarea><input name=\"q\"></form>",
      "form GET\n textarea note \"Say\"\n input text q",
    ],
    ["<select name=\"s\"><option>One<option>Two</select>", "select s\n option \"One\"\n option \"Two\""],
  ])
end

# A table of plain cells is rows of pipes; a cell with structure is nested; a layout table of one cell is transparent.
def test_tables() -> Result[Void]
  check([
    [
      "<table><thead><tr><th>Model</th><th>Price</th></tr></thead><tbody><tr><td>Symbioz</td><td>31,200</td></tr></tbody></table>",
      "table\n | Model | Price |\n | Symbioz | 31,200 |",
    ],
    [
      "<table><tr><td>Model</td></tr><tr><td><a href=\"/a\">Austral</a></td><td>35,900</td></tr></table>",
      "table\n | Model |\n tr\n  a \"Austral\" /a\n  \"35,900\"",
    ],
    ["<table><tr><td><a href=\"/a\">Austral</a></td></tr></table>", "a \"Austral\" /a"],
    ["<table><tr><td><table><tr><td>Inner</td></tr></table></td></tr></table>", "\"Inner\""],
    ["<table><tr><td>a<td>b<tr><td>c<td>d</table>", "table\n | a | b |\n | c | d |"],
  ])
end

# Preformatted text keeps its line breaks and its indentation.
def test_preformatted_text_keeps_its_lines() -> Result[Void]
  try Test.eq(HtmlCompact.compact("<pre><code>def f():\n    return 1</code></pre>"), "pre\n def f():\n     return 1")
  try Test.eq(HtmlCompact.compact("<pre>\n\n  a  \n\nb\n</pre><pre>   </pre>"), "pre\n   a\n \n b")
  ok()
end

# Entities are decoded in text and in attribute values, and the text of a `<` that opens no tag stays.
def test_entities_and_stray_markup() -> Result[Void]
  check([
    ["<p>fish &amp; chips &lt;3 &copy; &#65;&#x42; &nbsp;x</p>", "p \"fish & chips <3 © AB x\""],
    ["<a href=\"/?a=1&amp;b=2\" title=\"x\">&mdash;</a>", "a \"—\" /?a=1&b=2"],
    ["<p>1 < 2 and 3 > 2</p>", "p \"1 < 2 and 3 > 2\""],
    ["<a href='/q?x=\"1\"'>q</a>", "a \"q\" /q?x=\"1\""],
    ["<a href=/plain>plain</a>", "a \"plain\" /plain"],
    ["<p>a<br>b c</p>", "p \"a b c\""],
    ["<p>a<hr>c", "p \"a\"\n\"c\""],
    ["<p>one<p>two<div>three</div>", "p \"one\"\np \"two\"\n\"three\""],
    ["<title>A page</title><p>x</p>", "title \"A page\"\np \"x\""],
  ])
end

# Whatever the markup, the answer is text and no call stops: broken tags, nothing at all, and nesting 600 deep.
def test_broken_empty_and_deep_markup_give_text() -> Result[Void]
  for html in [
    "<div><p>x</div>", "<p>unclosed", "<a href=>x</a>", "<<>>", "<p>a<", "<html>", "</p></div>text", "<a href=\"x",
  ]
    try Test.assert(HtmlCompact.compact(html).length >= 0, html)
  end

  for html in ["", "   ", "\n\t"]
    try Test.eq(HtmlCompact.compact(html), "")
  end

  deep = "<div>" * 3000 + "x" + "</div>" * 3000
  try Test.eq(HtmlCompact.compact(deep), "\"x\"")
  ok()
end

# A page of markup comes out several times smaller, and keeps the links, the form and the table that text alone loses.
def test_a_markup_heavy_page_is_much_smaller_and_keeps_its_meaning() -> Result[Void]
  card = ->(n: Int) {
    (
      "<div class=\"flex flex-col gap-2 product-card\" data-testid=\"product-#{n}\">" +
      "<a class=\"font-bold\" href=\"/products/#{n}\">Item #{n}</a><span class=\"price\">#{n}99 EUR</span></div>"
    )
  }

  cards = (120..129).to_a.map { |n| card.call(n) }.join("")
  raw = (
    "<html><head><title>Example Shop</title><style>#{".a{color:red}" * 200}</style>" +
    "<script>#{"track();" * 200}</script></head><body class=\"antialiased\"><nav class=\"navbar\">" +
    "<a class=\"nav-link\" href=\"/products\">Products</a><a class=\"nav-link\" href=\"/pricing\">Pricing</a></nav>" +
    "<main><h1 class=\"display-4\">MacBook Air M4</h1><div class=\"container\"><div class=\"row\">#{cards}</div></div>" +
    "<form method=\"POST\" action=\"/cart\"><input type=\"hidden\" name=\"product\" value=\"123\">" +
    "<input id=\"u\" type=\"email\" name=\"username\" placeholder=\"Email address\">" +
    "<button type=\"submit\" class=\"btn\">Buy</button></form>" +
    "<table class=\"table\"><tr><th>Model</th><th>Price</th></tr><tr><td>Symbioz</td><td>31,200</td></tr></table>" +
    "<svg viewBox=\"0 0 24 24\"><path d=\"#{"M0 0 " * 100}\"/></svg></main></body></html>"
  )

  compact = HtmlCompact.compact(raw)
  try Test.assert(compact.length < raw.length / 3, "#{compact.length} of #{raw.length}")
  for kept in ["/products/123", "form POST /cart", "input email username \"Email address\"", "| Symbioz | 31,200 |"]
    try Test.assert(compact.include?(kept), kept)
  end

  ok()
end

# A long page keeps every row: the reader is made of lists that grow in place, not copied at each tag.
def test_a_long_page_keeps_every_row() -> Result[Void]
  row = "<tr class=\"r\"><td><a href=\"/item/1\" class=\"x\">An item of the list</a></td><td>99</td></tr>"
  compact = HtmlCompact.compact("<table>#{row * 200}</table>")
  rows = compact.split("\n").select { |line| line == "  a \"An item of the list\" /item/1" }
  try Test.eq(rows.size, 200)
  ok()
end
