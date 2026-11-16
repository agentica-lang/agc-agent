## Compaction of a session's history once its context passes a part of the model's window: the messages between the
## first task and the running turn become one summary, written by the compaction model. The system prompt and the
## tools are not part of the history, so the prefix a prompt cache keeps stays the same bytes.

import LLM from "pkg/llm/llm"

PERCENT = 80
MAX_TOOL_TEXT = 2000
SYSTEM = <<~TEXT
  You summarize part of a coding session for the agent that goes on with it. Write what was asked, what was decided,
  which files were read or changed and how, and what is left. Be brief and keep names, paths and commands exact.
TEXT

## The messages `from` up to (not with) `to` of the history became one assistant message with `summary`.
struct Compaction
  from: Int
  to: Int
  summary: String
end

struct Settings
  ## The model's window in tokens; 0 when it is not known (no compaction then).
  window: Int
  ## The model that writes the summary.
  model: String
  percent: Int = PERCENT
end

def due?(settings: Settings, context: Int) -> Bool
  settings.window > 0 and context * 100 >= settings.window * settings.percent
end

## The messages to fold: after the first task, before the running turn (whose user message is the last one with text).
## None when there is nothing between them.
def span(history: List[LLM.Message]) -> Optional[Compaction]
  last = 0
  for i in 0...history.size
    if (history[i].role == LLM.Role.User and history[i].content.any? { |b| text?(b) })
      last = i
    end
  end

  return none if last <= 1

  some(Compaction(from: 1, to: last, summary: ""))
end

## Asks the model for the summary of the span of `history`.
def summarize(
  provider: LLM.Provider,
  settings: Settings,
  history: List[LLM.Message],
  span: Compaction,
) -> Result[Compaction]
  text = transcript(history.drop(span.from).take(span.to - span.from))
  prompt = LLM.Message(role: LLM.Role.User, content: [LLM.Block.Text(LLM.TextPart(text: text))])
  stream = try LLM.stream(provider, LLM.Request(model: settings.model, system: SYSTEM, messages: [prompt]))
  response = try LLM.response(stream)
  summary = response.message.content.map { |b| text_of(b) }.join("").strip
  return error("the summary is empty") if summary.empty?

  ok(span.with(summary: summary))
end

def apply(history: List[LLM.Message], compaction: Compaction) -> List[LLM.Message]
  text = "Summary of the session so far:\n\n#{compaction.summary}"
  summary = LLM.Message(role: LLM.Role.Assistant, content: [LLM.Block.Text(LLM.TextPart(text: text))])
  history.take(compaction.from).push(summary) + history.drop(compaction.to)
end

private

def transcript(messages: List[LLM.Message]) -> String
  lines: List[String] = []
  for message in messages
    who = case message.role
      LLM.Role.User -> "User"
      LLM.Role.Assistant -> "Assistant"
    end

    for block in message.content
      case block
        LLM.Block.Text(part) -> lines = lines.push("#{who}: #{part.text}")
        LLM.Block.ToolUse(call) -> lines = lines.push("#{who} called #{call.name} with #{call.arguments}")
        LLM.Block.ToolResult(output) -> lines = lines.push("Tool result: #{cut(output.content)}")
        LLM.Block.Thinking(_) -> nil
      end
    end
  end

  lines.join("\n\n")
end

def cut(text: String) -> String
  return text if text.length <= MAX_TOOL_TEXT

  "#{text.slice(0, MAX_TOOL_TEXT)} [cut]"
end

def text?(block: LLM.Block) -> Bool
  case block
    LLM.Block.Text(_) -> true
    _ -> false
  end
end

def text_of(block: LLM.Block) -> String
  case block
    LLM.Block.Text(part) -> part.text
    _ -> ""
  end
end
