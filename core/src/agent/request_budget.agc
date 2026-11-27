## Fits the provider's wire limit without changing tool pairing or replaying tools.

import LLM from "pkg/llm/llm"
import Spill from "../tools/spill"

## `build` also covers compaction, which turns its input history into a transcript.
def stream(
  provider: LLM.Provider,
  messages: List[LLM.Message],
  build: Fn[List[LLM.Message], LLM.Request],
  storage: Optional[Spill.Port],
) -> Result[LLM.Stream]
  kept = messages
  tried = LLM.stream(provider, build.call(kept))
  for level in LEVELS
    case tried
      error(e) if e.kind == LLM.KIND_REQUEST_TOO_LARGE ->
        kept = kept.map { |m| m.with(content: m.content.map { |b| reduce(b, storage, level) }) }
        tried = LLM.stream(provider, build.call(kept))
      _ -> return tried
    end
  end

  case tried
    error(e) if e.kind == LLM.KIND_REQUEST_TOO_LARGE ->
      error("#{e.message} even after shortening tool results", kind: e.kind, details: e.details, cause: e)
    _ -> tried
  end
end

private

LEVELS = [Level(limit: 4096, preview: 256), Level(limit: 512, preview: 64), Level(limit: 128, preview: 0)]

struct Level
  limit: Int
  preview: Int
end

def reduce(block: LLM.Block, storage: Optional[Spill.Port], level: Level) -> LLM.Block
  case block
    LLM.Block.ToolResult(result) ->
      text = result.content
      size = encoded_size(text)
      return block if size <= level.limit

      shorter = Spill.shortened(text, storage, level.preview)
      return block if encoded_size(shorter) >= size

      LLM.Block.ToolResult(result.with(content: shorter))
    _ -> block
  end
end

def encoded_size(text: String) -> Int = JSON.encode(JSON.from(text)).bytesize
