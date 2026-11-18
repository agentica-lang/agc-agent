## `finn docs`: the Markdown pages of Finn's own documentation, `docs/content` of the install that `bin/finn` names in
## `FINN_HOME`. They are read in place, so they are the pages of the version that runs.

import Regex from "std/regex"

PAGE = /\A[a-z0-9_-]+(\.md)?\z/

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
    ok(home) if home != "" -> ok("#{home}/docs/content")
    _ -> error("FINN_HOME is not set: run finn through bin/finn")
  end
end

def shown(folder: String, pages: List[Page], name: String) -> Result[Int]
  wanted = name
  if not name.end_with?(".md")
    wanted = "#{name}.md"
  end

  if (not Regex.match?(name, PAGE) or not pages.any? { |page| page.name == wanted })
    IO.warn("finn docs: no page #{name}\n#{table(pages)}")
    return ok(1)
  end

  puts(body(try File.read_text("#{folder}/#{wanted}")))
  ok(0)
end

def listed(folder: String) -> Result[List[Page]]
  names = (try Dir.list(folder)).select { |name| name.end_with?(".md") and not name.start_with?("_") }.sort
  ok(
    names.map { |name| Page(name: name, description: description(File.read_text("#{folder}/#{name}").unwrap_or(""))) },
  )
end

def table(pages: List[Page]) -> String
  width = pages.map { |page| page.name.length }.max.unwrap_or(0)
  pages.map { |page| "#{page.name}#{" " * (width - page.name.length)}  #{page.description}" }.join("\n")
end

# The text of `description:` in the front matter.
def description(text: String) -> String
  for line in front(text)
    return line.slice(12, line.length - 12).strip if line.start_with?("description: ")
  end

  ""
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
