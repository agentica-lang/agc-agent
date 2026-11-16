## The system prompt of a new session: the agent's instructions, the project's `AGENTS.md` and the catalog of its
## skills.

import Sandbox from "../tools/sandbox"
import Skills from "../ext/skills"

MAX_INSTRUCTIONS_BYTES = 65_536
MAX_READ_BYTES = 1_048_576
SYSTEM_PROMPT = <<~TEXT
  You are a coding agent. You work in the session folder with the tools you have: read before you change a file, keep
  changes small, and say briefly what you did. To read, use read_file, glob and grep rather than bash.
TEXT

def with_catalog(system: String, skills: List[Skills.Skill]) -> String
  catalog = Skills.catalog(skills)
  return system if catalog == ""

  "#{system}\n#{catalog}"
end

def system_prompt(root: String) -> String
  case project_instructions(root)
    ok(text) -> "#{SYSTEM_PROMPT}\n# AGENTS.md of the session folder\n\n#{text}"
    error(_) -> SYSTEM_PROMPT
  end
end

def project_instructions(root: String) -> Result[String]
  path = try Sandbox.resolve(root, "AGENTS.md")
  info = try File.stat(path)
  return error("not a regular file") if info.kind != "file"
  return error("larger than #{MAX_READ_BYTES} bytes") if info.size_bytes > MAX_READ_BYTES

  text = try File.read_text(path)
  return ok(text) if text.bytesize <= MAX_INSTRUCTIONS_BYTES

  kept = text.slice(0, MAX_INSTRUCTIONS_BYTES)
  if kept.bytesize > MAX_INSTRUCTIONS_BYTES
    kept = text.slice(0, MAX_INSTRUCTIONS_BYTES / 4)
  end

  ok("#{kept}\n[AGENTS.md cut: it has #{info.size_bytes} bytes]")
end
