## `finn docs`: the Markdown pages of Finn's own documentation, `docs/content` of the install that `bin/finn` names in
## `FINN_HOME`. They are read in place, so they are the pages of the version that runs. A page is a regular `.md` file
## of the folder itself, whose real path is inside the folder, and whose name does not start with `_` (the home page):
## the list is the only name that a page may have.

## A page of the list, with the one line that says what it is for.
struct Page
  name: String
  description: String
end

## Prints the page `page` (its name, with or without `.md`), or the list when none. An unknown name is an error that
## lists the pages (exit 1).
def run(page: Optional[String]) -> Result[Int]
  folder = try folder()
  pages = try listed(folder)
  case page
    none ->
      puts(table(pages))
      ok(0)
    some(name) -> shown(folder, pages, name)
  end
end

private

def folder() -> Result[String]
  case System.env("FINN_HOME")
    ok(home) if home != "" -> Path.real("#{home}/docs/content")
    _ -> error("FINN_HOME is not set: run finn through bin/finn")
  end
end

def shown(folder: String, pages: List[Page], name: String) -> Result[Int]
  wanted = name
  if not name.end_with?(".md")
    wanted = "#{name}.md"
  end

  if (not pages.any? { |page| page.name == wanted })
    IO.warn("finn docs: no page #{name}\n#{table(pages)}")
    return ok(1)
  end

  puts(body(try File.read_text("#{folder}/#{wanted}")))
  ok(0)
end

def listed(folder: String) -> Result[List[Page]]
  names = (try Dir.list(folder)).select { |name| name.end_with?(".md") and not name.start_with?("_") }.sort
  inside = names.select { |name| page?(folder, name) }
  ok(
    inside.map { |name|
      Page(name: name, description: description(File.read_text("#{folder}/#{name}").unwrap_or("")))
    },
  )
end

# A regular file (not a link) whose real path is under the real folder.
def page?(folder: String, name: String) -> Bool
  path = "#{folder}/#{name}"
  case File.lstat(path)
    ok(info) if info.kind == "file" -> Path.real(path).unwrap_or("").start_with?("#{folder}/")
    _ -> false
  end
end

def table(pages: List[Page]) -> String
  width = pages.map { |page| page.name.length }.max.unwrap_or(0)
  pages.map { |page| "#{page.name}#{" " * (width - page.name.length)}  #{page.description}" }.join("\n")
end

# The `description:` of the front matter, as the skills read a frontmatter: a value that may hold colons, be quoted, or
# be a `|` or `>` block.
def description(text: String) -> String
  lines = front(text)
  i = 0
  while i < lines.size
    line = lines[i]
    i = i + 1
    next if not line.start_with?("description:")

    value = line.slice(12, line.length - 12).strip
    return unquoted(value) if not (value.start_with?("|") or value.start_with?(">"))

    block: List[String] = []
    while i < lines.size and (lines[i].strip == "" or lines[i].start_with?(" ") or lines[i].start_with?("\t"))
      block = block.push(lines[i].strip)
      i = i + 1
    end

    return block.join(" ").strip if value.start_with?(">")

    return block.join("\n").strip
  end

  ""
end

def unquoted(value: String) -> String
  if value.length >= 2 and value.start_with?("\"") and value.end_with?("\"")
    return value.slice(1, value.length - 2).replace("\\\"", "\"").replace("\\n", "\n").replace("\\\\", "\\")
  end

  if value.length >= 2 and value.start_with?("'") and value.end_with?("'")
    return value.slice(1, value.length - 2).replace("''", "'")
  end

  value
end

# The index of the `---` line that closes the front matter; none when the lines do not start with one.
def closing(lines: List[String]) -> Optional[Int]
  return none if lines.empty? or lines[0].strip != "---"

  found = (1...lines.size).find { |i| lines[i].strip == "---" }
  case found
    ok(at) -> some(at)
    error(_) -> none
  end
end

# The lines of the front matter.
def front(text: String) -> List[String]
  lines = text.split("\n")
  case closing(lines)
    some(at) -> lines.take(at).drop(1)
    none -> []
  end
end

# The page without its front matter and the blank lines after it.
def body(text: String) -> String
  lines = text.split("\n")
  case closing(lines)
    some(at) -> lines.drop(at + 1).join("\n").strip
    none -> text
  end
end
