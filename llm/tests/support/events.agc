## Helpers that read the events and blocks of a stream in the provider tests.

import LLM from "../../llm"

def user(text: String) -> LLM.Message = LLM.Message(role: LLM.Role.User, content: [text_block(text)])

def text_block(text: String) -> LLM.Block = LLM.Block.Text(LLM.TextPart(text: text))

def collect(call: LLM.Stream) -> List[LLM.Event]
  events: List[LLM.Event] = []
  while true
    case call.events.recv(5000)
      ok(event) -> events = events.push(event)
      error(_) -> break
    end
  end

  events
end

def texts(events: List[LLM.Event]) -> String = events.map { |e| text_of(e) }.join("")

def thinking_of(event: LLM.Event) -> String
  case event
    LLM.Event.ThinkingDelta(piece) -> piece.text
    _ -> ""
  end
end

def input_pieces(events: List[LLM.Event]) -> List[String]
  events.map { |e| input_of(e) }.select { |piece| not piece.empty? }
end

def starts(events: List[LLM.Event]) -> List[Int] = events.map { |e| start_index(e) }.select { |i| i >= 0 }

def path_of(block: LLM.Block) -> String
  case block
    LLM.Block.ToolUse(call) -> JSON.string(JSON.get(call.input, "path").unwrap_or(JSON.from(""))).unwrap_or("")
    _ -> ""
  end
end

def text_of_block(block: LLM.Block) -> String
  case block
    LLM.Block.Text(part) -> part.text
    _ -> ""
  end
end

def kind(result: Result[LLM.Response]) -> String
  case result
    ok(_) -> "ok"
    error(e) -> e.kind
  end
end

private

def text_of(event: LLM.Event) -> String
  case event
    LLM.Event.TextDelta(piece) -> piece.text
    _ -> ""
  end
end

def input_of(event: LLM.Event) -> String
  case event
    LLM.Event.ToolInputDelta(piece) -> piece.text
    _ -> ""
  end
end

def start_index(event: LLM.Event) -> Int
  case event
    LLM.Event.ToolUseStart(start) -> start.index
    _ -> -1
  end
end
