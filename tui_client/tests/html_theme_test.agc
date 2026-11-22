import TUI from "pkg/tui/tui"
import HtmlTheme from "../src/html_theme"
import Theme from "../src/theme"

# The embedded grammars are the files: the runtime compiles them, never reading
# the package folder.
def test_the_embedded_grammars_match_the_files() -> Result[Void]
  try Test.eq(HtmlTheme.HTML_GRAMMAR, try File.read_text("grammars/theme_html.grammar"))
  Test.eq(HtmlTheme.CSS_GRAMMAR, try File.read_text("grammars/theme_css.grammar"))
end

# A theme file gives its style blocks in order, and the classes and ids of its elements.
def test_style_blocks_classes_and_ids_come_out_in_order() -> Result[Void]
  html = try File.read_text("tests/fixtures/theme.html")
  blocks = try HtmlTheme.style_texts(html)
  try Test.eq(blocks.size, 2)
  try Test.assert(blocks[0].include?(".transcript-user"), blocks[0])
  try Test.assert(blocks[1].include?(".banner-text"), blocks[1])
  try Test.eq(try HtmlTheme.classes(html), ["transcript-user", "panel-selected", "notice"])
  Test.eq(try HtmlTheme.ids(html), ["main"])
end

# An uppercase STYLE tag still counts; comments and scripts never leak into the CSS.
def test_style_tags_match_in_any_case() -> Result[Void]
  blocks = try HtmlTheme.style_texts("<STYLE>.a { color: red; }</STYLE><!-- .b { color: blue; } -->")
  try Test.eq(blocks.size, 1)
  Test.assert(blocks[0].include?(".a"), blocks[0])
end

# Each declaration sets one aspect; together they give the exact styles.
def test_mapping_gives_exact_styles() -> Result[Void]
  css = <<~C
    .transcript-user { color: red; font-weight: bold; }
    .panel-head, .panel-text { color: #00ff00; }
    .banner-text {
      color: black;
      background-color: ansi(221);
      font-style: italic;
      text-decoration: underline;
      dim: true;
    }
    .footer-status { color: red; }
    .editor-cursor { background-color: #f00; }
    .transcript-code { color: default; }
  C

  base = Theme.basic()
  theme = HtmlTheme.apply_rules(base, try HtmlTheme.parse_rules(css))
  try Test.eq(theme.transcript.user, TUI.Style(fg: TUI.Color.Red, bold: true))
  try Test.eq(theme.panel.head, TUI.Style(fg: TUI.Color.Rgb(0, 255, 0), bold: true))
  try Test.eq(theme.panel.text, TUI.Style(fg: TUI.Color.Rgb(0, 255, 0)))
  try Test.eq(
    theme.banner.text,
    TUI.Style(fg: TUI.Color.Black, bg: TUI.Color.Index(221), italic: true, underline: true, dim: true),
  )

  try Test.eq(theme.footer.status, TUI.Style(fg: TUI.Color.Red, dim: true))
  # The cursor keeps its reverse; `default` clears the 256-color code color.
  try Test.eq(theme.editor.cursor, TUI.Style(bg: TUI.Color.Rgb(255, 0, 0), reverse: true))
  full = HtmlTheme.apply_rules(Theme.default(), try HtmlTheme.parse_rules(css))
  try Test.eq(full.transcript.code, TUI.Style(fg: TUI.Color.Default))
  # What no rule names keeps the base theme.
  try Test.eq(theme.transcript.assistant, base.transcript.assistant)
  Test.eq(theme.rules.high, base.rules.high)
end

# Later rules win; declarations of one selector merge in CSS order.
def test_later_rules_win_and_declarations_merge() -> Result[Void]
  css = ".transcript-user { color: red; } .transcript-user { color: green; font-weight: bold; }"
  theme = HtmlTheme.apply_rules(Theme.basic(), try HtmlTheme.parse_rules(css))
  Test.eq(theme.transcript.user, TUI.Style(fg: TUI.Color.Green, bold: true))
end

# Unknown selectors, properties and values change nothing; one bad declaration
# never stops the good ones of its rule.
def test_unknown_selectors_properties_and_values_are_ignored() -> Result[Void]
  css = <<~C
    .nope { color: red; }
    div > p { color: red; }
    #missing { color: red; }
    .transcript-user { color: red; sparkle: lots; color: blurple; font-weight: heavy; opacity: 0.5; }
  C

  base = Theme.basic()
  theme = HtmlTheme.apply_rules(base, try HtmlTheme.parse_rules(css))
  try Test.eq(theme.transcript.user, TUI.Style(fg: TUI.Color.Red, bold: true))
  try Test.eq(theme.panel, base.panel)
  try Test.eq(theme.banner, base.banner)
  try Test.eq(theme.footer, base.footer)
  try Test.eq(theme.editor, base.editor)
  Test.eq(HtmlTheme.apply_rules(base, try HtmlTheme.parse_rules(".nope { color: red; }")), base)
end

# Broken CSS or HTML keeps the base theme with a warning, never an error.
def test_broken_css_and_html_fall_back_to_base() -> Result[Void]
  for bad in [
    "<style>.a { color: red</style>",
    "<style>.a color: red; }</style>",
    "<style>.a { color red }</style>",
    "<div><span>",
    "<div class=\"x\">",
  ]
    loaded = HtmlTheme.load(Theme.basic(), "theme.html", files_with(ok(bad)))
    try Test.eq(loaded.theme, Theme.basic())
    try Test.assert(loaded.warning.some?, bad)
    try Test.assert(loaded.warning.unwrap!.include?("theme.html"), loaded.warning.unwrap_or(""))
  end

  ok()
end

# A missing file keeps the base theme with no warning.
def test_a_missing_file_keeps_the_base_silently() -> Result[Void]
  files = HtmlTheme.Files(exists: ->(_path: String) { false }, read: ->(_path: String) { error("unread") })
  loaded = HtmlTheme.load(Theme.basic(), "theme.html", files)
  try Test.eq(loaded.theme, Theme.basic())
  Test.eq(loaded.warning, none)
end

# A theme file through `load` styles the regions its rules name.
def test_load_applies_a_theme_file() -> Result[Void]
  css = ".rules-high { color: magenta; } .panel-selected { background-color: ansi(24); }"
  html = "<html><head><style>#{css}</style></head></html>"
  loaded = HtmlTheme.load(Theme.basic(), "theme.html", files_with(ok(html)))
  try Test.eq(loaded.theme.rules.high, TUI.Style(fg: TUI.Color.Magenta))
  try Test.eq(loaded.theme.panel.selected, TUI.Style(bg: TUI.Color.Index(24), reverse: true))
  Test.eq(loaded.warning, none)
end

# One spelling per property: `dim: true` dims, `opacity` means nothing here.
def test_dim_has_one_spelling_and_component_names_style_regions() -> Result[Void]
  css = <<~C
    .rules-high { dim: true; opacity: 0.5; }
    .notice { color: yellow; }
    .sidebar { color: cyan; }
    .input { color: green; }
    .tooltip { color: white; }
    .modal { color: blue; }
    .popover { color: magenta; }
    .panel { font-weight: bold; }
  C

  theme = HtmlTheme.apply_rules(Theme.basic(), try HtmlTheme.parse_rules(css))
  try Test.eq(theme.rules.high, TUI.Style(fg: TUI.Color.Magenta, dim: true))
  try Test.eq(theme.transcript.notice, TUI.Style(fg: TUI.Color.Yellow, dim: true))
  # Later component names win over earlier ones; all of them style the panel text.
  try Test.eq(theme.panel.text, TUI.Style(fg: TUI.Color.Magenta, bold: true))
  try Test.eq(theme.editor.text, TUI.Style(fg: TUI.Color.Green))
  try Test.eq(theme.banner.text, TUI.Style(fg: TUI.Color.White, bg: TUI.Color.Yellow))
  try Test.eq(theme.panel.selected, Theme.basic().panel.selected)
  # `opacity` is ignored; `dim: false` is not the spelling, so it dims nothing.
  dimmed = HtmlTheme.apply_rules(Theme.basic(), try HtmlTheme.parse_rules(".footer-status { dim: false; }"))
  Test.eq(dimmed.footer.status, Theme.basic().footer.status)
end

# `FINN_THEME` wins; else `theme.html` sits next to the user's config file.
def test_the_theme_file_is_finn_theme_or_next_to_the_config() -> Result[Void]
  try Test.eq(HtmlTheme.theme_file(env_of({"FINN_THEME": "/t/theme.html"})), "/t/theme.html")
  try Test.eq(
    HtmlTheme.theme_file(env_of({"FINN_CONFIG": "/custom/config.json", "FINN_THEME": ""})),
    "/custom/theme.html",
  )

  try Test.eq(HtmlTheme.theme_file(env_of({"XDG_CONFIG_HOME": "/xdg"})), "/xdg/finn/theme.html")
  try Test.eq(HtmlTheme.theme_file(env_of({"HOME": "/h"})), "/h/.config/finn/theme.html")
  Test.eq(HtmlTheme.theme_file(env_of({"HOME": "/h", "XDG_CONFIG_HOME": "/xdg"})), "/xdg/finn/theme.html")
end

# Attributes come out in document order even when the tags are of different kinds.
def test_attributes_follow_document_order_across_tag_kinds() -> Result[Void]
  html = "<br class=\"a\"/><div class=\"b\">x</div><img class=\"c\">"
  Test.eq(try HtmlTheme.classes(html), ["a", "b", "c"])
end

# CSS holding `"</"` that does not close the style block no longer drops the theme.
def test_style_text_keeps_css_containing_a_close_bracket() -> Result[Void]
  html = "<style>.a { content: \"</3\"; color: red; }</style>"
  blocks = try HtmlTheme.style_texts(html)
  try Test.eq(blocks.size, 1)
  try Test.assert(blocks[0].include?("</3"), blocks[0])
  Test.assert(blocks[0].include?("color: red"), blocks[0])
end

# A class list splits on any ASCII whitespace, not just spaces.
def test_classes_split_on_ascii_whitespace() -> Result[Void]
  tab = String.from_code(9)
  lf = String.from_code(10)
  cr = String.from_code(13)
  ff = String.from_code(12)
  html = "<div class=\"a#{tab}b#{lf}c#{cr}d#{ff}e\">x</div>"
  Test.eq(try HtmlTheme.classes(html), ["a", "b", "c", "d", "e"])
end

# With no known config folder there is no theme file, and `load` stays silent.
def test_an_empty_home_gives_no_theme_file() -> Result[Void]
  try Test.eq(HtmlTheme.config_dir(env_of({"OTHER": "1"})), "")
  try Test.eq(HtmlTheme.theme_file(env_of({"OTHER": "1"})), "")
  try Test.eq(HtmlTheme.theme_file(env_of({"HOME": ""})), "")
  try Test.eq(HtmlTheme.theme_file(env_of({"FINN_CONFIG": "/c/config.json"})), "/c/theme.html")
  loaded = HtmlTheme.load(Theme.basic(), HtmlTheme.theme_file(env_of({"OTHER": "1"})), files_with(ok("<style>")))
  try Test.eq(loaded.theme, Theme.basic())
  Test.eq(loaded.warning, none)
end

# A theme file over 1 MiB is refused before parsing, keeping the base with a warning.
def test_an_oversized_theme_file_keeps_the_base() -> Result[Void]
  big = "<style>"
  for _ in 0...21
    big = "#{big}#{big}"
  end

  loaded = HtmlTheme.load(Theme.basic(), "theme.html", files_with(ok(big)))
  try Test.eq(loaded.theme, Theme.basic())
  try Test.assert(loaded.warning.some?, "expected a too-big warning")
  Test.assert(loaded.warning.unwrap_or("").include?("theme.html"), loaded.warning.unwrap_or(""))
end

private

def files_with(read: Result[String]) -> HtmlTheme.Files
  HtmlTheme.Files(exists: ->(_path: String) { true }, read: ->(_path: String) { read })
end

def env_of(values: Map[String, String]) -> Fn[String, Result[String]]
  ->(name: String) {
    case values.get(name)
      some(value) -> ok(value)
      none -> error("unset")
    end
  }
end
