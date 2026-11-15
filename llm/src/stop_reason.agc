## Why a model stopped: the same for every provider.
enum StopReason
  EndTurn
  ToolUse
  MaxTokens
  StopSequence
  Refusal
  PauseTurn
  Other(String)
end

## The stop reason of an Anthropic Messages answer (`stop_reason`).
def from_anthropic(name: String) -> StopReason
  case name
    "end_turn" -> StopReason.EndTurn
    "tool_use" -> StopReason.ToolUse
    "max_tokens" -> StopReason.MaxTokens
    "stop_sequence" -> StopReason.StopSequence
    "refusal" -> StopReason.Refusal
    "pause_turn" -> StopReason.PauseTurn
    _ -> StopReason.Other(name)
  end
end
