## HTML/CSS theming for the full screen: `theme.html` next to the user's config
## file (or `FINN_THEME`) holds `<style>` blocks whose selectors name the theme
## regions (`.transcript-user`, `.panel-head`, ...). Pure, except the `Files`
## seam of `load`, which lets tests inject a fake reader.
##
## Selectors are `.class`, `#id` or element names, matched case-insensitively
## against one spelling per region (see `apply_patch`); specificity is order
## only, later rules winning over earlier ones, and declarations merge in CSS
## order. `.footer-status` is the base of the status row (its filler, separators
## and any segment no rule names); `.footer-status-<name>` names one segment
## (`state`, `usage`, `rate`, `hints`, `model`, `chatgpt.quota` or an extension's
## name, lowercased with its dots kept, so `chatgpt.quota` stays dotted). Unknown
## selectors, properties and values are ignored, never errors:
## a file that does not parse keeps the built-in theme with a warning.
## Properties, one spelling each: `color` and `background-color` (a named
## color, `#rgb`/`#rrggbb` or `ansi(n)`), `font-weight: bold`,
## `font-style: italic`, `text-decoration: underline` and `dim: true`.
## (Phase 2 will attach layout, not just Style, to these same parsed rules and
## elements: `parse_rules` stays the shared input for both passes. Component
## names such as `.sidebar`, `.modal`, `.notice`, `.panel`, `.input`,
## `.tooltip` and `.popover` style a region now and get their own layout then.)

import Grammy from "pkg/grammy/grammy"
import TUI from "pkg/tui/tui"
import Theme from "theme"

## The text of `grammars/theme_html.grammar` and `grammars/theme_css.grammar`:
## the runtime compiles them, never reading the files (the working folder at
## runtime is the user's shell folder, not the package). A test asserts each
## equals its file; keep the bodies in sync by doubling every backslash (a
## heredoc reads `\\n` as `\n`).
HTML_GRAMMAR = <<~G
  // Minimal HTML for Finn's theme files: elements with their attributes, text
  // and comments. Enough to find the `style` blocks (their text is the CSS the
  // theme reads) and the elements carrying `class` or `id`, which later passes
  // may use for layout. Matching is lenient: a close tag need not name its open
  // tag, `script` blocks are skipped as raw text like `style`, and unknown
  // `<!...>` declarations are skipped whole.
  // (Phase 2 will attach layout, not just Style, to these same parsed elements.)

  document = { SOI ~ node* ~ EOI }
  node = { comment | doctype | style_element | script_element | element | text }

  comment = @{ "<!--" ~ (!"-->" ~ ANY)* ~ "-->" }
  doctype = @{ "<!" ~ (!">" ~ ANY)* ~ ">" }

  style_element = { style_open ~ style_text ~ style_close }
  style_open = { "<" ~ ^"style" ~ attr* ~ ">" }
  style_close = { "</" ~ ^"style" ~ ">" }
  style_text = @{ (!("</" ~ ^"style") ~ ANY)* }

  script_element = { script_open ~ script_text ~ script_close }
  script_open = { "<" ~ ^"script" ~ attr* ~ ">" }
  script_close = { "</" ~ ^"script" ~ ">" }
  script_text = @{ (!"</" ~ ANY)* }

  element = { open_tag ~ node* ~ close_tag | self_tag | void_tag }
  // A void element never opens: without the guard `<br>` would match `open_tag`
  // and swallow the `</body>` after it as its own close tag (PEG keeps the first
  // alternative that succeeds, so `void_tag` would never run).
  open_tag = { "<" ~ !void_name ~ tag_name ~ attr* ~ ">" }
  close_tag = { "</" ~ tag_name ~ ">" }
  self_tag = { "<" ~ tag_name ~ attr* ~ "/>" }
  void_tag = { "<" ~ void_name ~ attr* ~ "/>" | "<" ~ void_name ~ attr* ~ ">" }
  void_name = {
    ^"area" | ^"base" | ^"br" | ^"col" | ^"embed" | ^"hr" | ^"img" | ^"input" | ^"link" | ^"meta" | ^"param" |
      ^"source" | ^"track" | ^"wbr"
  }

  tag_name = @{ ASCII_ALPHA ~ (ASCII_ALPHANUMERIC | "-" | "_")* }
  attr = { attr_name ~ ("=" ~ attr_value)? }
  attr_name = @{ (ASCII_ALPHANUMERIC | "-" | "_" | ":")+ }
  attr_value = { dquoted | squoted | bare }
  dquoted = @{ "\\"" ~ (!"\\"" ~ ANY)* ~ "\\"" }
  squoted = @{ "'" ~ (!"'" ~ ANY)* ~ "'" }
  bare = @{ (ASCII_ALPHANUMERIC | "-" | "_" | "." | ":" | "#" | "+" | "%")+ }

  text = @{ (!"<" ~ ANY)+ }

  WHITESPACE = _{ " " | "\\t" | "\\r" | "\\n" }
G

CSS_GRAMMAR = <<~G
  // Minimal CSS for Finn's theme files: a rule is a selector list with
  // declarations. Selectors are raw text up to `{` (`.class`, `#id` or an
  // element name; anything else is ignored when the theme is applied).
  // Declarations are `property: value` pairs; unknown properties or values are
  // ignored there too. At-rules (`@media` and the like) are skipped whole: their
  // inner rules do not apply. `/* */` comments are skipped anywhere.
  // (Phase 2 will attach layout, not just Style, to these same parsed rules.)

  stylesheet = { SOI ~ item* ~ EOI }
  item = { rule | at_skip }

  rule = { selectors ~ "{" ~ declaration* ~ "}" }
  selectors = { selector ~ ("," ~ selector)* }
  selector = @{ (!("," | "{" | "}") ~ ANY)+ }

  declaration = { property ~ ":" ~ value ~ ";"? }
  property = @{ "-"* ~ (ASCII_ALPHANUMERIC | "-" | "_")+ }
  value = @{ (!(";" | "}") ~ ANY)+ }

  at_skip = { "@" ~ (!(";" | "{") ~ ANY)* ~ (";" | block) }
  block = { "{" ~ (block | (!("{" | "}") ~ ANY))* ~ "}" }

  WHITESPACE = _{ " " | "\\t" | "\\r" | "\\n" }
  COMMENT = _{ "/*" ~ (!"*/" ~ ANY)* ~ "*/" }
G

## One CSS rule: its selectors in order, each with its declarations in order.
struct CssRule
  selectors: List[String]
  declarations: List[CssDeclaration]
end

struct CssDeclaration
  property: String
  value: String
end

## One property parsed: the colors it sets, and the attributes it adds. Every
## attribute is additive: CSS here never clears what the base theme sets.
struct Patch
  fg: Optional[TUI.Color] = none
  bg: Optional[TUI.Color] = none
  bold: Bool = false
  dim: Bool = false
  italic: Bool = false
  underline: Bool = false
end

## What `load` reads: `exists` first (a missing file keeps the base with no
## warning), then `read`. `disk` is the real one.
struct Files
  exists: Fn[String, Bool]
  read: Fn[String, Result[String]]
end

## What `load` gives: the theme, and why it is the base when the file did not apply.
struct Loaded
  theme: Theme.Theme
  warning: Optional[String] = none
end

def disk() -> Files
  Files(exists: ->(path: String) { File.stat(path).ok? }, read: ->(path: String) { File.read_text(path) })
end

## Where the theme file is: `FINN_THEME` when it names a file, else
## `theme.html` next to the user's config file (`FINN_CONFIG`, else
## `$XDG_CONFIG_HOME/finn/config.json`, else `~/.config/finn/config.json`;
## the folder logic mirrors `core`'s, without depending on it).
def theme_file(env: Fn[String, Result[String]]) -> String
  for path in option_list(setting(env, "FINN_THEME"))
    return path
  end

  dir = config_dir(env)
  return "" if dir.empty?

  "#{dir}/theme.html"
end

## `""` when no config folder is known (no `FINN_CONFIG`, no `XDG_CONFIG_HOME`
## and an unset or empty `HOME`): `theme_file` passes it through, and `load`
## keeps the base theme silently.
def config_dir(env: Fn[String, Result[String]]) -> String
  for path in option_list(setting(env, "FINN_CONFIG"))
    return parent_dir(path)
  end

  for base in option_list(setting(env, "XDG_CONFIG_HOME"))
    return "#{base}/finn"
  end

  for home in option_list(setting(env, "HOME"))
    return "#{home}/.config/finn"
  end

  ""
end

## The theme `base` with the file at `path` applied: a missing file keeps
## `base` with no warning; a file that reads or parses warns and keeps `base`.
def load(base: Theme.Theme, path: String, files: Files) -> Loaded
  return Loaded(theme: base) if path.empty?
  return Loaded(theme: base) if not files.exists.call(path)

  case files.read.call(path)
    ok(text) -> parsed(base, path, text)
    error(e) -> Loaded(theme: base, warning: some("cannot read theme file #{path}: #{e.message}"))
  end
end

def parsed(base: Theme.Theme, path: String, text: String) -> Loaded
  if text.length > 1048576
    return Loaded(theme: base, warning: some("theme file #{path} is over 1 MiB, keeping the built-in theme"))
  end

  case style_texts(text)
    ok(css) -> styled(base, path, css)
    error(e) -> Loaded(theme: base, warning: some("cannot parse theme file #{path}: #{e.message}"))
  end
end

def styled(base: Theme.Theme, path: String, css: List[String]) -> Loaded
  case parse_rules(css.join("\n"))
    ok(rules) -> Loaded(theme: apply_rules(base, rules))
    error(e) -> Loaded(theme: base, warning: some("cannot parse the styles of theme file #{path}: #{e.message}"))
  end
end

## The text of every `<style>` block of `html` in document order.
def style_texts(html: String) -> Result[List[String]]
  grammar = try Grammy.compile(HTML_GRAMMAR)
  root = try Grammy.run(grammar, "document", html)
  texts: List[String] = []
  for element in Grammy.find_all(root, "style_element")
    for text in option_list(Grammy.first_child(element, "style_text"))
      texts = texts.push(Grammy.text(text, html))
    end
  end

  ok(texts)
end

## Every `class` of `html` in document order, each value split on ASCII whitespace.
def classes(html: String) -> Result[List[String]] = attributes(html, "class")

## Every `id` of `html` in document order.
def ids(html: String) -> Result[List[String]] = attributes(html, "id")

## The rules of `css` in source order, with each selector and declaration kept.
def parse_rules(css: String) -> Result[List[CssRule]]
  grammar = try Grammy.compile(CSS_GRAMMAR)
  root = try Grammy.run(grammar, "stylesheet", css)
  rules: List[CssRule] = []
  for node in Grammy.find_all(root, "rule")
    selectors: List[String] = []
    for found in option_list(Grammy.first_child(node, "selectors"))
      for selector in Grammy.children_of(found, "selector")
        text = Grammy.text(selector, css).strip
        if not text.empty?
          selectors = selectors.push(text)
        end
      end
    end

    declarations: List[CssDeclaration] = []
    for found in Grammy.children_of(node, "declaration")
      for property in option_list(Grammy.first_child(found, "property"))
        for value in option_list(Grammy.first_child(found, "value"))
          declarations = declarations.push(
            CssDeclaration(property: Grammy.text(property, css).strip, value: Grammy.text(value, css).strip),
          )
        end
      end
    end

    rules = rules.push(CssRule(selectors: selectors, declarations: declarations))
  end

  ok(rules)
end

## `base` with `rules` applied in order: later rules win, declarations merge.
def apply_rules(base: Theme.Theme, rules: List[CssRule]) -> Theme.Theme
  theme = base
  for rule in rules
    for selector in rule.selectors
      for declaration in rule.declarations
        theme = apply_declaration(theme, selector, declaration)
      end
    end
  end

  theme
end

private

## The tags carry the attributes: gathered across every tag rule with their
## offsets, then sorted, so a self-closing tag before an open tag still comes
## out first.
def attributes(html: String, name: String) -> Result[List[String]]
  grammar = try Grammy.compile(HTML_GRAMMAR)
  root = try Grammy.run(grammar, "document", html)
  values: List[Grammy.Node] = []
  for rule in ["open_tag", "self_tag", "void_tag", "style_open", "script_open"]
    for tag in Grammy.find_all(root, rule)
      for attr in Grammy.children_of(tag, "attr")
        for aname in option_list(Grammy.first_child(attr, "attr_name"))
          if Grammy.text(aname, html).downcase == name
            for avalue in option_list(Grammy.first_child(attr, "attr_value"))
              values = values.push(avalue)
            end
          end
        end
      end
    end
  end

  found: List[String] = []
  for avalue in (values.sort_by { |node| node.start })
    for part in split_whitespace(unquoted(Grammy.text(avalue, html)))
      found = found.push(part)
    end
  end

  ok(found)
end

## A value split on ASCII whitespace (space, tab, LF, CR, FF).
def split_whitespace(value: String) -> List[String]
  words: List[String] = []
  current = ""
  for char in value.split("")
    code = char.code
    if code == 32 or code == 9 or code == 10 or code == 13 or code == 12
      if not current.empty?
        words = words.push(current)
        current = ""
      end
    else
      current = "#{current}#{char}"
    end
  end

  if not current.empty?
    words = words.push(current)
  end

  words
end

def unquoted(value: String) -> String
  return value.slice(1, value.length - 2) if value.length >= 2 and quoted?(value)

  value
end

def quoted?(value: String) -> Bool
  (value.start_with?("\"") and value.end_with?("\"")) or (value.start_with?("'") and value.end_with?("'"))
end

def apply_declaration(theme: Theme.Theme, selector: String, declaration: CssDeclaration) -> Theme.Theme
  for patch in option_list(patch_of(declaration.property, declaration.value))
    return apply_patch(theme, key_of(selector), patch)
  end

  theme
end

# A selector names a region: one leading `.` or `#` falls off, and the case is
# ignored, so `.transcript-user`, `#transcript-user` and `transcript-user` ask
# for the same region; anything else is ignored when applied.
def key_of(selector: String) -> String
  key = selector.strip.downcase
  if (key.start_with?(".") or key.start_with?("#")) and key.length > 1
    key = key.slice(1, key.length - 1)
  end

  key.strip
end

def patch_of(property: String, value: String) -> Optional[Patch]
  case property.strip.downcase
    "color" -> color_of(value).map { |color| Patch(fg: some(color)) }
    "background-color" -> color_of(value).map { |color| Patch(bg: some(color)) }
    "font-weight" if value.strip.downcase == "bold" -> some(Patch(bold: true))
    "font-style" if value.strip.downcase == "italic" -> some(Patch(italic: true))
    "text-decoration" if value.strip.downcase == "underline" -> some(Patch(underline: true))
    "dim" if value.strip.downcase == "true" -> some(Patch(dim: true))
    _ -> none
  end
end

def color_of(value: String) -> Optional[TUI.Color]
  text = value.strip.downcase
  case text
    "red" -> some(TUI.Color.Red)
    "green" -> some(TUI.Color.Green)
    "yellow" -> some(TUI.Color.Yellow)
    "blue" -> some(TUI.Color.Blue)
    "magenta" -> some(TUI.Color.Magenta)
    "cyan" -> some(TUI.Color.Cyan)
    "white" -> some(TUI.Color.White)
    "black" -> some(TUI.Color.Black)
    "default" -> some(TUI.Color.Default)
    _ if text.start_with?("#") -> hex_color(text)
    _ if text.start_with?("ansi(") and text.end_with?(")") -> ansi_color(text)
    _ -> none
  end
end

def ansi_color(text: String) -> Optional[TUI.Color]
  inner = text.slice(5, text.length - 6).strip
  case inner.to_i
    ok(index) if index >= 0 and index <= 255 -> some(TUI.Color.Index(index))
    _ -> none
  end
end

def hex_color(text: String) -> Optional[TUI.Color]
  digits = text.slice(1, text.length - 1)
  expanded = case digits.length
    3 -> some(digits.split("").map { |digit| "#{digit}#{digit}" }.join(""))
    6 -> some(digits)
    _ -> none
  end

  for hex in option_list(expanded)
    for rgb in option_list(hex_rgb(hex))
      return some(rgb)
    end
  end

  none
end

def hex_rgb(hex: String) -> Optional[TUI.Color]
  parts = hex.split("")
  return none if parts.size != 6

  channels: List[Int] = []
  for pair in [parts.take(2).join(""), parts.drop(2).take(2).join(""), parts.drop(4).take(2).join("")]
    for byte in option_list(hex_byte(pair))
      channels = channels.push(byte)
    end
  end

  return none if channels.size != 3

  some(TUI.Color.Rgb(channels[0], channels[1], channels[2]))
end

def hex_byte(pair: String) -> Optional[Int]
  digits = pair.split("")
  for high in option_list(hex_digit(digits[0]))
    for low in option_list(hex_digit(digits[1]))
      return some(high * 16 + low)
    end
  end

  none
end

def hex_digit(char: String) -> Optional[Int]
  code = char.code
  return some(code - 48) if code >= 48 and code <= 57
  return some(code - 87) if code >= 97 and code <= 102
  return some(code - 55) if code >= 65 and code <= 70

  none
end

# Every region of `Theme`, and the component names that style a region until
# phase 2 gives them their own layout: `.sidebar` and `.modal` are panels,
# `.notice` is a transcript notice, `.input` is the prompt, `.tooltip` is a
# banner and `.popover` is a panel.
def apply_patch(theme: Theme.Theme, key: String, patch: Patch) -> Theme.Theme
  case key
    "transcript-user" -> theme.with(transcript: theme.transcript.with(user: overlaid(theme.transcript.user, patch)))
    "transcript-assistant" ->
      theme.with(transcript: theme.transcript.with(assistant: overlaid(theme.transcript.assistant, patch)))

    "transcript-bold" -> theme.with(transcript: theme.transcript.with(bold: overlaid(theme.transcript.bold, patch)))
    "transcript-heading" ->
      theme.with(transcript: theme.transcript.with(heading: overlaid(theme.transcript.heading, patch)))

    "transcript-code" -> theme.with(transcript: theme.transcript.with(code: overlaid(theme.transcript.code, patch)))
    "transcript-thinking" ->
      theme.with(transcript: theme.transcript.with(thinking: overlaid(theme.transcript.thinking, patch)))

    "transcript-notice" ->
      theme.with(transcript: theme.transcript.with(notice: overlaid(theme.transcript.notice, patch)))

    "transcript-tool" -> theme.with(transcript: theme.transcript.with(tool: overlaid(theme.transcript.tool, patch)))
    "transcript-arg-running" ->
      theme.with(transcript: theme.transcript.with(arg_running: overlaid(theme.transcript.arg_running, patch)))

    "transcript-arg-done" ->
      theme.with(transcript: theme.transcript.with(arg_done: overlaid(theme.transcript.arg_done, patch)))

    "transcript-arg-failed" ->
      theme.with(transcript: theme.transcript.with(arg_failed: overlaid(theme.transcript.arg_failed, patch)))

    "transcript-output" ->
      theme.with(transcript: theme.transcript.with(output: overlaid(theme.transcript.output, patch)))

    "transcript-removed" ->
      theme.with(transcript: theme.transcript.with(removed: overlaid(theme.transcript.removed, patch)))

    "transcript-added" -> theme.with(transcript: theme.transcript.with(added: overlaid(theme.transcript.added, patch)))

    "panel-head" -> theme.with(panel: theme.panel.with(head: overlaid(theme.panel.head, patch)))
    "panel-text" -> theme.with(panel: theme.panel.with(text: overlaid(theme.panel.text, patch)))
    "panel-selected" -> theme.with(panel: theme.panel.with(selected: overlaid(theme.panel.selected, patch)))
    "panel-removed" -> theme.with(panel: theme.panel.with(removed: overlaid(theme.panel.removed, patch)))
    "panel-added" -> theme.with(panel: theme.panel.with(added: overlaid(theme.panel.added, patch)))
    "banner-text" -> theme.with(banner: theme.banner.with(text: overlaid(theme.banner.text, patch)))
    "footer-status" -> theme.with(footer: theme.footer.with(status: overlaid(theme.footer.status, patch)))
    _ if key.start_with?("footer-status-") -> segment_patched(theme, key.slice(14, key.length - 14), patch)
    "editor-text" -> theme.with(editor: theme.editor.with(text: overlaid(theme.editor.text, patch)))
    "editor-cursor" -> theme.with(editor: theme.editor.with(cursor: overlaid(theme.editor.cursor, patch)))
    "rules-default" -> theme.with(rules: theme.rules.with(default: overlaid(theme.rules.default, patch)))
    "rules-low" -> theme.with(rules: theme.rules.with(low: overlaid(theme.rules.low, patch)))
    "rules-medium" -> theme.with(rules: theme.rules.with(medium: overlaid(theme.rules.medium, patch)))
    "rules-high" -> theme.with(rules: theme.rules.with(high: overlaid(theme.rules.high, patch)))
    "notice" -> theme.with(transcript: theme.transcript.with(notice: overlaid(theme.transcript.notice, patch)))
    "sidebar", "modal", "panel", "popover" ->
      theme.with(panel: theme.panel.with(text: overlaid(theme.panel.text, patch)))

    "input" -> theme.with(editor: theme.editor.with(text: overlaid(theme.editor.text, patch)))
    "tooltip" -> theme.with(banner: theme.banner.with(text: overlaid(theme.banner.text, patch)))
    _ -> theme
  end
end

# One named status segment: `.footer-status-<name>` overlays the segment it names, starting from what that
# segment already has, or from `footer.status` when no rule named it yet. `<name>` is the lowercased segment
# name with its dots kept, so `chatgpt.quota` is `.footer-status-chatgpt.quota`; names that differ only in case
# share one entry, and an empty name changes nothing.
def segment_patched(theme: Theme.Theme, name: String, patch: Patch) -> Theme.Theme
  return theme if name.strip.empty?

  current = theme.footer.segments.get(name).unwrap_or(theme.footer.status)
  theme.with(footer: theme.footer.with(segments: theme.footer.segments.put(name, overlaid(current, patch))))
end

# The user's theme wins even on eight-color terminals: a patch overlays `basic()`, never replacing it.
def overlaid(base: TUI.Style, patch: Patch) -> TUI.Style
  TUI.Style(
    fg: patch.fg.unwrap_or(base.fg),
    bg: patch.bg.unwrap_or(base.bg),
    bold: base.bold or patch.bold,
    dim: base.dim or patch.dim,
    italic: base.italic or patch.italic,
    underline: base.underline or patch.underline,
    reverse: base.reverse,
    attrs: base.attrs,
  )
end

def setting(env: Fn[String, Result[String]], name: String) -> Optional[String]
  case env.call(name)
    ok(value) if not value.strip.empty? -> some(value.strip)
    _ -> none
  end
end

def parent_dir(path: String) -> String
  parts = path.split("/")
  return "." if parts.size <= 1

  head = parts.take(parts.size - 1)
  return "/" if head == [""]

  head.join("/")
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
